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
 * son propre bloc de journal, avec son propre total en euros : c'est la page
 * qui coûte, pas le job, et un job de trois pages coûte trois fois plus sans
 * que ce soit une anomalie.
 *
 * ## Écriture directe, sans quarantaine ni modération
 *
 * Une découpe part telle quelle sous `illustrations/{uid}/`.
 *
 * Elle passait auparavant par la quarantaine, puis par `moderateAndPromote`.
 * Cinq opérations pour une image qu'on a déjà en mémoire : écrire le fichier,
 * le relire, vérifier son format, l'analyser chez Cloud Vision, le recopier
 * ailleurs et supprimer l'original.
 *
 * Deux de ces contrôles ne servaient à rien ici :
 *
 * - **le contrôle de format** avait déjà eu lieu. Le fichier source est passé
 *   par `scanAndPromoteUploadFn` au moment de l'envoi. La découpe, elle, est un
 *   JPEG que Sharp vient d'encoder trois lignes plus haut : en vérifier la
 *   signature revient à vérifier notre propre encodeur.
 * - **l'analyse Cloud Vision** portait sur un morceau de la photo que
 *   l'utilisateur a lui-même prise et envoyée. Elle est facturée à l'unité, par
 *   découpe. Les images produites par l'IA (`generateRecipeIllustrationFn`,
 *   `generatePlatingImageFn`) s'en passent déjà et écrivent au même endroit.
 *
 * Ce que fait encore la modération, et qui reste vrai : elle garde son rôle sur
 * les images qu'une personne envoie depuis l'application. Ce fichier-ci ne
 * traite que des découpes d'un scan déjà accepté.
 */

import { getStorage } from "firebase-admin/storage";
import { randomUUID } from "node:crypto";

import { logError, logInfo } from "../logging";
import { extractPageIllustrations } from "./extract";

/** Ce que la relecture affiche à propos des illustrations d'une recette. */
export interface StoredIllustrations {
  /** Les URL publiques, dans l'ordre des pages puis des zones. */
  urls: string[];
  /**
   * Images repérées sur les pages, toutes pages confondues.
   *
   * Ce que la page PORTE, et non ce qu'on en a tiré. C'est ce chiffre qui
   * nourrit le bandeau de relecture, et il doit rester vrai quand l'extraction
   * a échoué — c'est même le seul moment où il compte vraiment.
   */
  detectees: number;
  /** Découpes réellement produites, avant écriture. */
  retenues: number;
  /** Découpes écrites dans Storage. Diffère de `retenues` si une écriture rate. */
  publiees: number;
  /** Pages dont l'extraction s'est interrompue. */
  pagesEnEchec: number;
  /** Pages où le pré-contrôle a dit « aucune image » : la chaîne s'est arrêtée. */
  pagesSansImage: number;
}

/**
 * Extrait puis enregistre les illustrations de toutes les pages d'un import.
 *
 * Ne lève jamais. Une illustration perdue ne vaut pas un import perdu : la
 * recette est déjà transcrite quand cette fonction s'exécute.
 */
export async function extractAndStorePageIllustrations(args: {
  pages: Buffer[];
  mimeType: string;
  userId: string;
  jobId: string;
  correlationId: string;
  /** Scan de l'utilisateur d'où viennent les pages, quand il en vient un. */
  scanId?: string;
  fileName?: string;
}): Promise<StoredIllustrations> {
  const { pages, mimeType, userId, jobId, correlationId, scanId, fileName } = args;

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
      scanId,
      userId,
      jobId,
      fileName: fileName ? `${fileName} (page ${index + 1})` : undefined,
    });

    if (extraction.skipped) pagesSansImage += 1;
    if (extraction.outcome === "interrompue") pagesEnEchec += 1;
    detectees += extraction.onPage;
    retenues += extraction.illustrations.length;

    for (const [rank, illustration] of extraction.illustrations.entries()) {
      try {
        const url = await uploadPageIllustration({
          bytes: illustration.bytes,
          userId,
          jobId,
          pageNumber: index + 1,
          rank: rank + 1,
        });
        urls.push(url);
      } catch (err) {
        // Une découpe perdue n'emporte pas les autres : elles n'ont rien à voir
        // avec elle. L'échec part quand même dans les journaux.
        await logError({
          message: `Illustrations : enregistrement impossible pour « ${illustration.label} »`,
          errorDescription: err instanceof Error ? err.message : String(err),
          moduleType: "DESIGN",
          correlationId,
          scanId,
          userId,
          jobId,
          feature: "page_illustrations",
        });
      }
    }
  }

  await logInfo({
    message:
      `Illustrations : ${urls.length} enregistrée(s) sur ${detectees} repérée(s), ` +
      `${pages.length} page(s), ${pagesSansImage} sans image, ${pagesEnEchec} en échec`,
    moduleType: "DESIGN",
    correlationId,
    scanId,
    userId,
    jobId,
    feature: "page_illustrations",
    extra: {
      pages: pages.length,
      reperees: detectees,
      decoupees: retenues,
      enregistrees: urls.length,
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

/**
 * Écrit une découpe sous `illustrations/{uid}/` et rend son URL publique.
 *
 * Le nom porte le job, la page et le rang. Deux imports simultanés du même
 * compte ne peuvent donc pas écrire le même fichier, et un chemin retrouvé dans
 * les journaux dit d'où il vient.
 *
 * Le jeton de téléchargement est celui qu'attend l'URL `firebasestorage` :
 * sans lui, l'image existe et ne s'affiche pas.
 */
async function uploadPageIllustration(args: {
  bytes: Buffer;
  userId: string;
  jobId: string;
  pageNumber: number;
  rank: number;
}): Promise<string> {
  const { bytes, userId, jobId, pageNumber, rank } = args;

  const path = `illustrations/${userId}/${jobId}_p${pageNumber}_illus${rank}.jpg`;
  const bucket = getStorage().bucket();
  const token = randomUUID();

  await bucket.file(path).save(bytes, {
    contentType: "image/jpeg",
    metadata: {
      cacheControl: "public, max-age=31536000",
      metadata: { firebaseStorageDownloadTokens: token },
    },
  });

  return (
    `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/` +
    `${encodeURIComponent(path)}?alt=media&token=${token}`
  );
}
