/**
 * De la page importée aux illustrations attachées à la recette.
 *
 * `extract.ts` sait extraire des pixels ; ce fichier sait quoi en faire. La
 * séparation n'est pas cosmétique : l'extraction ne connaît ni Storage, ni les
 * jobs, ni le bilan affiché à la relecture, et c'est ce qui la rend rejouable
 * ailleurs — un écran d'administration, un test, un futur ré-essai à la demande.
 *
 * Toutes les pages du job y passent, pas seulement la première : une recette
 * étalée sur trois pages a ses photographies sur les trois. Chaque page ouvre
 * son propre bloc de journal, avec son propre total en euros — c'est la page
 * qui coûte, pas le job, et un job de trois pages qui coûte trois fois plus
 * n'est pas une anomalie.
 *
 * ## Le serveur n'a pas de porte à lui
 *
 * Les découpes ne sont pas déposées directement sous `illustrations/{uid}/`.
 * Elles passent par la **quarantaine**, puis par `moderateAndPromote`, comme
 * n'importe quelle image envoyée par une personne — et c'en est une : ce sont
 * les pixels d'une photo prise par l'utilisateur, redécoupés. Écrire en direct
 * avec les droits de l'Admin SDK ferait de ce chemin le seul qui échappe au
 * verdict.
 *
 * Toutes les découpes d'une page partent en **un seul appel** de modération.
 * Le lot est un poste de coût distinct (`image_moderation_batch`), et c'est ce
 * qui permet de vérifier que le groupage fait son office.
 *
 * Une découpe refusée n'entre pas dans la recette, et il n'y a pas de repli :
 * une image que la modération écarte ne se publie pas parce qu'elle vient du
 * serveur.
 */

import { randomUUID } from "node:crypto";
import { getStorage } from "firebase-admin/storage";

import { logError, logInfo } from "../logging";
import {
  ImageFormatRejected,
  QuarantineFileMissing,
  moderateAndPromote,
} from "../moderation/moderateAndPromote";
import { extractPageIllustrations } from "./extract";

/** Ce que la relecture affiche à propos des illustrations d'une recette. */
export interface StoredIllustrations {
  /** Les URL publiques, dans l'ordre des pages puis des zones. */
  urls: string[];
  /** Zones repérées, toutes pages confondues. */
  detectees: number;
  /** Découpes soumises à la modération. */
  retenues: number;
  /** Découpes approuvées et publiées. */
  publiees: number;
  /** Pages dont l'extraction s'est interrompue. */
  pagesEnEchec: number;
  /** Pages où le pré-contrôle a dit « aucune image » — la chaîne s'est arrêtée. */
  pagesSansImage: number;
}

/**
 * Extrait puis publie les illustrations de toutes les pages d'un import.
 *
 * Ne lève jamais. Une illustration perdue ne vaut pas un import perdu : la
 * recette, elle, est déjà transcrite quand cette fonction s'exécute.
 */
export async function extractAndStorePageIllustrations(args: {
  pages: Buffer[];
  mimeType: string;
  userId: string;
  jobId: string;
  correlationId: string;
  fileName?: string;
}): Promise<StoredIllustrations> {
  const { pages, mimeType, userId, jobId, correlationId, fileName } = args;

  const urls: string[] = [];
  let detectees = 0;
  let retenues = 0;
  let pagesEnEchec = 0;
  let pagesSansImage = 0;

  for (const [index, bytes] of pages.entries()) {
    const extraction = await extractPageIllustrations({
      bytes,
      mimeType,
      // Une page, un bloc de journal. Le suffixe garde les blocs distincts tout
      // en laissant le préfixe commun : un filtre sur l'identifiant du job les
      // rassemble, un filtre exact isole une page.
      correlationId: `${correlationId}_p${index + 1}`,
      userId,
      jobId,
      fileName: fileName ? `${fileName} (page ${index + 1})` : undefined,
    });

    if (extraction.skipped) pagesSansImage += 1;
    if (extraction.outcome === "interrompue") pagesEnEchec += 1;
    detectees += extraction.illustrations.length;
    if (extraction.illustrations.length === 0) continue;

    const quarantinePaths = await depositInQuarantine({
      crops: extraction.illustrations.map((i) => i.bytes),
      userId,
      jobId,
      pageNumber: index + 1,
      correlationId,
    });
    retenues += quarantinePaths.length;
    if (quarantinePaths.length === 0) continue;

    const published = await moderateBatch({ quarantinePaths, userId, correlationId, jobId });
    urls.push(...published);
  }

  await logInfo({
    message:
      `Illustrations : ${urls.length} publiée(s) sur ${detectees} extraite(s), ` +
      `${pages.length} page(s), ${pagesSansImage} sans image, ${pagesEnEchec} en échec`,
    moduleType: "DESIGN",
    correlationId,
    userId,
    jobId,
    feature: "page_illustrations",
    extra: {
      pages: pages.length,
      extraites: detectees,
      soumises: retenues,
      publiees: urls.length,
      pagesSansImage,
      pagesEnEchec,
    },
  });

  return {
    urls,
    detectees,
    retenues,
    publiees: urls.length,
    pagesEnEchec,
    pagesSansImage,
  };
}

/** Dépose les découpes en quarantaine et rend leurs chemins. */
async function depositInQuarantine(args: {
  crops: Buffer[];
  userId: string;
  jobId: string;
  pageNumber: number;
  correlationId: string;
}): Promise<string[]> {
  const { crops, userId, jobId, pageNumber, correlationId } = args;
  const bucket = getStorage().bucket();
  const paths: string[] = [];

  for (const [index, bytes] of crops.entries()) {
    // Le nom porte le job, la page et le rang : deux imports simultanés du même
    // compte ne peuvent pas écrire le même fichier, et un chemin retrouvé dans
    // les journaux dit d'où il vient.
    const path = `quarantine/${userId}/${jobId}_p${pageNumber}_illus${index + 1}.jpg`;
    try {
      await bucket.file(path).save(bytes, {
        contentType: "image/jpeg",
        metadata: {
          metadata: { firebaseStorageDownloadTokens: randomUUID() },
        },
      });
      paths.push(path);
    } catch (err) {
      await logError({
        message: `Illustrations : dépôt en quarantaine impossible (page ${pageNumber}, zone ${index + 1})`,
        errorDescription: err instanceof Error ? err.message : String(err),
        moduleType: "DESIGN",
        correlationId,
        userId,
        jobId,
        feature: "page_illustrations",
      });
    }
  }
  return paths;
}

/**
 * Soumet le lot d'une page à la modération et rend les URL approuvées.
 *
 * Les deux erreurs typées de la modération sont attrapées séparément : un
 * format refusé et un fichier absent de la quarantaine ne disent pas la même
 * chose, et les confondre priverait l'un des deux de sa piste.
 */
async function moderateBatch(args: {
  quarantinePaths: string[];
  userId: string;
  jobId: string;
  correlationId: string;
}): Promise<string[]> {
  const { quarantinePaths, userId, jobId, correlationId } = args;

  try {
    const { results } = await moderateAndPromote({
      items: quarantinePaths.map((quarantinePath) => ({
        quarantinePath,
        targetKind: "draft_illustration" as const,
        ownerId: null,
        contentType: "image/jpeg",
        // « user » et non « ai » : ces pixels viennent de la photo prise par
        // l'utilisateur. Aucun moteur ne les a produits, et aucun garde-fou
        // amont ne les a vus.
        origin: "user" as const,
      })),
      userId,
      correlationId,
    });

    const approved = results.filter((r) => r.url != null).map((r) => r.url as string);
    const refused = results.length - approved.length;
    if (refused > 0) {
      await logInfo({
        message: `Illustrations : ${refused} découpe(s) écartée(s) par la modération`,
        moduleType: "MODERATION",
        correlationId,
        userId,
        jobId,
        feature: "page_illustrations",
        extra: { refusees: refused, soumises: results.length },
      });
    }
    return approved;
  } catch (err) {
    const message =
      err instanceof ImageFormatRejected
        ? "Illustrations : découpe refusée par le scan de format avant modération"
        : err instanceof QuarantineFileMissing
          ? "Illustrations : découpe absente de la quarantaine au moment de la modération"
          : "Illustrations : modération du lot impossible, aucune découpe publiée";
    await logError({
      message,
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "MODERATION",
      correlationId,
      userId,
      jobId,
      feature: "page_illustrations",
      extra: { soumises: quarantinePaths.length },
    });
    return [];
  }
}
