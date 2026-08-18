/**
 * Promotion d'une image : quarantaine → destination publiée.
 *
 * Reprend le schéma déjà en place pour les scans (`scanAndPromoteUploadFn`) :
 * copie, métadonnées, URL de téléchargement, suppression de la source. Il n'y a
 * rien à inventer ici — seulement à le généraliser aux quatre portes qui
 * écrivaient jusque-là en direct.
 */

import { getDownloadURL, getStorage } from "firebase-admin/storage";

import { logError } from "../logging";

/** Destination possible d'une image modérée. */
export type ModerationTargetKind =
  "book_cover" | "recipe_illustration" | "draft_illustration" | "free_recipe_cover";

export const MODERATION_TARGET_KINDS: readonly ModerationTargetKind[] = [
  "book_cover",
  "recipe_illustration",
  "draft_illustration",
  "free_recipe_cover",
];

export function isTargetKind(value: unknown): value is ModerationTargetKind {
  return (
    typeof value === "string" && MODERATION_TARGET_KINDS.includes(value as ModerationTargetKind)
  );
}

/** Extension du fichier de quarantaine, minuscule, sans point. */
export function extensionOf(path: string, fallback = "jpg"): string {
  const name = path.split("/").pop() ?? "";
  const dot = name.lastIndexOf(".");
  if (dot < 0 || dot === name.length - 1) return fallback;
  const ext = name.slice(dot + 1).toLowerCase();
  return /^[a-z0-9]{1,5}$/.test(ext) ? ext : fallback;
}

/**
 * Chemin publié d'une image, selon sa destination.
 *
 * Pure et exportée : c'est la correspondance qui décide où atterrit une image,
 * et une erreur y publierait au mauvais endroit sans lever d'erreur.
 *
 * `ownerId` est le livre ou la recette selon le cas ; les deux destinations
 * personnelles n'en ont pas besoin et se rangent sous l'utilisateur.
 */
export function targetPathFor(args: {
  kind: ModerationTargetKind;
  uid: string;
  ownerId?: string | null;
  quarantinePath: string;
  timestampMs: number;
}): string {
  const { kind, uid, ownerId, quarantinePath, timestampMs } = args;
  const ext = extensionOf(quarantinePath);
  switch (kind) {
    case "book_cover":
      if (!ownerId) throw new Error("book_cover exige l'identifiant du livre.");
      return `covers/${ownerId}/cover.jpg`;
    case "recipe_illustration":
      if (!ownerId) throw new Error("recipe_illustration exige l'identifiant de la recette.");
      return `recipes/${ownerId}/illus_${timestampMs}.${ext}`;
    case "draft_illustration":
      return `illustrations/${uid}/${timestampMs}_moderated.${ext}`;
    case "free_recipe_cover":
      return `users/${uid}/free_recipe_cover_${timestampMs}.${ext}`;
  }
}

export interface PromotedImage {
  storagePath: string;
  downloadUrl: string;
}

/**
 * Copie le fichier vers sa destination et rend son URL.
 *
 * La suppression de la source est best-effort — mais jamais silencieuse : un
 * fichier de quarantaine qui s'accumule est un coût de stockage qui ne se voit
 * nulle part ailleurs.
 */
export async function promoteImage(args: {
  quarantinePath: string;
  targetPath: string;
  contentType: string;
  moderationId: string;
  correlationId: string;
}): Promise<PromotedImage> {
  const { quarantinePath, targetPath, contentType, moderationId, correlationId } = args;
  const bucket = getStorage().bucket();
  const source = bucket.file(quarantinePath);

  const [promoted] = await source.copy(bucket.file(targetPath));
  await promoted.setMetadata({
    contentType,
    metadata: {
      moderation_status: "approved",
      moderation_id: moderationId,
      moderated_at: new Date().toISOString(),
    },
  });
  const downloadUrl = await getDownloadURL(promoted);

  try {
    await source.delete();
  } catch (err) {
    await logError({
      message: "Suppression du fichier de quarantaine impossible après promotion",
      moduleType: "MODERATION",
      correlationId,
      errorDescription: err instanceof Error ? err.message : String(err),
      extra: { quarantinePath, targetPath, moderationId },
    });
  }

  return { storagePath: targetPath, downloadUrl };
}

/**
 * Chemin de conservation d'une image refusée.
 *
 * Même arborescence que la quarantaine, autre racine : le fichier reste
 * rattaché à son envoyeur, et la règle Storage n'ouvre `rejected/` qu'aux
 * administrateurs.
 */
export function rejectedPathFor(quarantinePath: string): string {
  return quarantinePath.replace(/^quarantine\//, "rejected/");
}

/**
 * Écarte de la quarantaine une image refusée — sans la détruire.
 *
 * Elle est déplacée vers `rejected/`, lisible des seuls administrateurs. La
 * supprimer était le premier réflexe, et c'était une erreur : sans l'image, on
 * ne peut pas juger si le refus était fondé. Une modération qu'on ne peut pas
 * évaluer ne se corrige jamais — et ce sont les faux refus, une photo de rôti
 * prise pour une scène violente, qu'on a le plus besoin de voir.
 *
 * Rend le chemin de conservation, ou `null` si le déplacement a échoué : le
 * document doit dire la vérité sur ce qui est réellement consultable.
 */
export async function quarantineToRejected(args: {
  quarantinePath: string;
  moderationId: string;
  correlationId: string;
}): Promise<string | null> {
  const bucket = getStorage().bucket();
  const source = bucket.file(args.quarantinePath);
  const rejectedPath = rejectedPathFor(args.quarantinePath);

  try {
    await source.copy(bucket.file(rejectedPath));
  } catch (err) {
    await logError({
      message: "Conservation de l'image refusée impossible",
      moduleType: "MODERATION",
      correlationId: args.correlationId,
      errorDescription: err instanceof Error ? err.message : String(err),
      extra: { quarantinePath: args.quarantinePath, moderationId: args.moderationId },
    });
    return null;
  }

  try {
    await source.delete();
  } catch (err) {
    // La copie a réussi : l'image est consultable. Le reliquat en quarantaine
    // est un coût de stockage, pas une perte de donnée — mais il ne doit pas
    // s'accumuler en silence.
    await logError({
      message: "Suppression du reliquat de quarantaine impossible après refus",
      moduleType: "MODERATION",
      correlationId: args.correlationId,
      errorDescription: err instanceof Error ? err.message : String(err),
      extra: { quarantinePath: args.quarantinePath, moderationId: args.moderationId },
    });
  }

  return rejectedPath;
}
