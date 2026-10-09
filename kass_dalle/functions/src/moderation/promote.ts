/**
 * Promotion d'une image : quarantaine → destination publiée.
 *
 * Reprend le schéma déjà en place pour les scans (`scanAndPromoteUploadFn`) :
 * copie, métadonnées, URL de téléchargement, suppression de la source. Il n'y a
 * rien à inventer ici — seulement à le généraliser aux quatre portes qui
 * écrivaient jusque-là en direct.
 */

import { getFirestore } from "firebase-admin/firestore";
import { getDownloadURL, getStorage } from "firebase-admin/storage";

import { COLL_BOOKS, COLL_RECIPES } from "../config";
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

/**
 * Identifiant de document Firestore utilisable comme `ownerId`.
 *
 * `ownerId` part dans un chemin Firestore (`books/{ownerId}`) et dans un
 * chemin Storage (`covers/{ownerId}/cover.jpg`). Un « / » y ouvrirait un
 * autre chemin que celui du document vérifié ; `.` et `..` ne sont pas des
 * identifiants Firestore, ni `__…__`, réservé.
 */
export function isValidDocumentId(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.length <= 1500 &&
    !value.includes("/") &&
    value !== "." &&
    value !== ".." &&
    !/^__.*__$/.test(value)
  );
}

/**
 * Le fichier de quarantaine tel qu'il a été analysé, et pas un autre.
 *
 * Entre l'analyse et la promotion, l'envoyeur peut réécrire son fichier de
 * quarantaine : `copy()` relirait alors la nouvelle version, publiée sans
 * avoir été regardée. Épingler la génération lue avant le téléchargement fait
 * copier exactement les octets analysés — et échouer la copie si cette
 * version a été remplacée. Pure et exportée pour être testée.
 */
export function pinnedGeneration(value: unknown): string | number | undefined {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) return value;
  if (typeof value === "string" && /^[0-9]+$/.test(value)) return value;
  return undefined;
}

/**
 * Document antérieur à l'épinglage (sans `quarantine_generation`) : le fichier
 * a-t-il pu changer depuis l'analyse ?
 *
 * Vrai si sa date de mise à jour Storage est postérieure à la création du
 * document de modération, ou si l'une des deux est illisible — sans preuve, on
 * ne publie pas. Pure et exportée pour être testée.
 */
export function legacyFileMayHaveChanged(
  fileUpdated: unknown,
  docCreatedAtMs: number | null,
): boolean {
  if (docCreatedAtMs == null || !Number.isFinite(docCreatedAtMs)) return true;
  const updatedMs = typeof fileUpdated === "string" ? Date.parse(fileUpdated) : Number.NaN;
  if (!Number.isFinite(updatedMs)) return true;
  return updatedMs > docCreatedAtMs;
}

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

/**
 * Collection du document qu'une destination illustre, ou `null` pour les deux
 * destinations personnelles (rangées sous l'uid de l'appelant).
 */
export function ownedTargetCollection(kind: ModerationTargetKind): string | null {
  switch (kind) {
    case "book_cover":
      return COLL_BOOKS;
    case "recipe_illustration":
      return COLL_RECIPES;
    case "draft_illustration":
    case "free_recipe_cover":
      return null;
  }
}

/**
 * Refus de publier vers le livre ou la recette d'autrui, ou `null` si permis.
 *
 * Pure et exportée pour être testée. `docCreatedBy` vaut `undefined` quand le
 * document n'existe pas. La règle est celle de Firestore : on ne modifie que
 * ses propres livres et recettes — éditeur compris —, l'administrateur agit
 * comme le créateur. Sans ce contrôle, n'importe quel compte remplaçait la
 * couverture d'un livre d'autrui en passant son identifiant.
 */
export function targetOwnershipDenial(args: {
  kind: ModerationTargetKind;
  ownerId: string | null;
  callerUid: string;
  docExists: boolean;
  docCreatedBy: unknown;
  callerIsAdmin: boolean;
}): string | null {
  if (ownedTargetCollection(args.kind) == null) return null;
  if (!args.ownerId) return `${args.kind} exige l'identifiant du document illustré.`;
  if (!args.docExists) return "Document illustré introuvable.";
  if (args.callerIsAdmin) return null;
  const createdBy = typeof args.docCreatedBy === "string" ? args.docCreatedBy : "";
  if (createdBy.length > 0 && createdBy === args.callerUid) return null;
  return "Seuls le créateur et un administrateur changent l'image de ce document.";
}

/** Publication refusée : le livre ou la recette visés appartiennent à un autre. */
export class TargetNotOwned extends Error {
  constructor(
    readonly kind: ModerationTargetKind,
    readonly ownerId: string | null,
    readonly detail: string,
  ) {
    super(detail);
    this.name = "TargetNotOwned";
  }
}

/**
 * Vérifie, avant toute analyse facturée, que l'appelant peut illustrer le
 * document visé. Lève [TargetNotOwned] sinon.
 *
 * `isAdmin` n'est consulté que si l'appelant n'est pas le créateur : le chemin
 * normal coûte une lecture, celle du document illustré.
 */
export async function assertTargetOwnership(args: {
  kind: ModerationTargetKind;
  ownerId: string | null;
  callerUid: string;
  isAdmin: (uid: string) => Promise<boolean>;
}): Promise<void> {
  const collection = ownedTargetCollection(args.kind);
  if (collection == null) return;
  const snap = args.ownerId
    ? await getFirestore().collection(collection).doc(args.ownerId).get()
    : null;
  const docExists = snap?.exists === true;
  const docCreatedBy = snap?.data()?.created_by;
  const isOwner = typeof docCreatedBy === "string" && docCreatedBy === args.callerUid;
  const callerIsAdmin = docExists && !isOwner ? await args.isAdmin(args.callerUid) : false;
  const denial = targetOwnershipDenial({
    kind: args.kind,
    ownerId: args.ownerId,
    callerUid: args.callerUid,
    docExists,
    docCreatedBy,
    callerIsAdmin,
  });
  if (denial) throw new TargetNotOwned(args.kind, args.ownerId, denial);
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
  /** Génération analysée (voir [pinnedGeneration]). Absente : documents antérieurs. */
  sourceGeneration?: unknown;
}): Promise<PromotedImage> {
  const { quarantinePath, targetPath, contentType, moderationId, correlationId } = args;
  const bucket = getStorage().bucket();
  const generation = pinnedGeneration(args.sourceGeneration);
  const source = bucket.file(quarantinePath, generation != null ? { generation } : undefined);

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
  /** Génération jugée : c'est elle qu'on conserve, pas une version réécrite depuis. */
  sourceGeneration?: unknown;
}): Promise<string | null> {
  const bucket = getStorage().bucket();
  const generation = pinnedGeneration(args.sourceGeneration);
  const source = bucket.file(args.quarantinePath, generation != null ? { generation } : undefined);
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
