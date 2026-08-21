/**
 * recipeProcessor — Cloud Function Cloud Tasks worker (Phase 1.4).
 *
 * Reçoit un payload {jobId, userId, correlationId} et déroule le pipeline :
 *   IMPORT → IMAGE_DECODE → GEMINI_CALL → PARSE → DESIGN → SAVE
 *
 * Idempotence : utilise processing_jobs/{id}.current_step pour reprendre
 * au bon endroit en cas de retry par Cloud Tasks.
 *
 * Configuration :
 *  - secret GEMINI_API_KEY (Secret Manager)
 *  - retryConfig: max 3 tentatives, backoff exponentiel
 *  - rateLimits: 5 dispatches concurrents, 2/sec
 *  - timeout 540s, mémoire 1GiB (pour Sharp + Gemini)
 */

import { onTaskDispatched } from "firebase-functions/v2/tasks";
import { getDownloadURL, getStorage } from "firebase-admin/storage";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
import { randomUUID } from "node:crypto";
import {
  ANTHROPIC_API_KEY,
  GEMINI_API_KEY,
  REGION,
  QUEUE_RECIPE_PROCESSING,
  MAX_CONCURRENT_DISPATCHES,
  MAX_DISPATCHES_PER_SECOND,
  MAX_RETRY_ATTEMPTS,
  COLL_PROCESSING_JOBS,
  COLL_RECIPES,
  COLL_BOOKS,
  COLL_DEAD_LETTERS,
} from "../config";
import { logAiText, logError, logInfo, newCorrelationId } from "../logging";
import { transcribePage, type PageTranscription } from "../gemini/transcription";
import { tagAndNormalize, type NormalizedIngredientLine } from "../gemini/tagging";
import { checkFidelity, verbatimCooklang, type FidelityReport } from "../gemini/fidelity";
import { extractBookCover } from "../gemini/search";
import { polishMarkdown } from "../gemini/refiner";
import { detectIllustrationRegions, uprightImage } from "../gemini/detector";
import { GeminiQuotaExceededError } from "../gemini/client";
import { BudgetExceededError } from "../ai/budget";
import {
  normalizeRecipeReferentialsCore,
  type StoredRecipeIngredient,
} from "../nutrition/referentialNormalization";
import {
  extractTitle,
  extractPortions,
  extractPageNumber,
  buildIngredientsIndex,
  extractTags,
  stripMeta,
  CookLangPageType,
} from "../cooklang/parser";

interface ProcessorPayload {
  jobId: string;
  userId: string;
  correlationId?: string;
}

/**
 * Étapes affichées à l'utilisateur pendant un import.
 *
 * Elles doivent décrire ce qui SE PASSE, pas ce qui vient de se terminer.
 * « Enregistrement » couvrait autrefois le balisage, le contrôle de fidélité,
 * la normalisation des référentiels et l'écriture — jusqu'à sept minutes sous
 * un mot qui en promet une seconde. L'utilisateur voyait un enregistrement
 * interminable et n'avait aucun moyen de savoir ce qui tournait.
 *
 * L'enregistrement est désormais ce qu'il dit : la dernière étape, et la plus
 * brève.
 */
type PipelineStep =
  | "queued"
  | "import"
  | "image_decode"
  | "gemini_call"
  | "parse"
  | "design"
  | "tagging"
  | "normalize"
  | "save"
  | "done";

const STEP_ORDER: PipelineStep[] = [
  "queued",
  "import",
  "image_decode",
  "gemini_call",
  "parse",
  "design",
  "tagging",
  "normalize",
  "save",
  "done",
];

function stepIndex(step: PipelineStep): number {
  return STEP_ORDER.indexOf(step);
}

export const recipeProcessor = onTaskDispatched(
  {
    region: REGION,
    secrets: [GEMINI_API_KEY, ANTHROPIC_API_KEY],
    memory: "1GiB",
    timeoutSeconds: 540,
    retryConfig: {
      maxAttempts: MAX_RETRY_ATTEMPTS,
      minBackoffSeconds: 10,
      maxBackoffSeconds: 300,
      maxDoublings: 4,
    },
    rateLimits: {
      maxConcurrentDispatches: MAX_CONCURRENT_DISPATCHES,
      maxDispatchesPerSecond: MAX_DISPATCHES_PER_SECOND,
    },
  },
  async (req) => {
    const payload = req.data as ProcessorPayload;
    const { jobId, userId } = payload;
    const correlationId = payload.correlationId ?? newCorrelationId("import_recette");
    const ctx = { jobId, userId, correlationId };

    if (!jobId || !userId) {
      logError({
        message: "Payload invalide (jobId/userId manquant)",
        moduleType: "IMPORT",
        ...ctx,
      });
      return; // no retry — payload broken
    }

    const db = getFirestore();
    const jobRef = db.collection(COLL_PROCESSING_JOBS).doc(jobId);
    const snap = await jobRef.get();
    if (!snap.exists) {
      logError({ message: `Job ${jobId} introuvable`, moduleType: "IMPORT", ...ctx });
      return;
    }
    const job = snap.data() as Record<string, unknown>;
    const jobType = (job.type as string | undefined) ?? "recipeScan";
    const attempt = Number(req.retryCount ?? 0);
    let createdBookId: string | null = (job.created_book_id as string | undefined) ?? null;
    let bookTouchedInRun = false;

    // Si le job est déjà terminé, on ne retraite pas.
    if (job.status === "done") {
      logInfo({ message: "Job déjà terminé, retry ignoré", moduleType: "IMPORT", ...ctx });
      return;
    }

    // L'utilisateur a demandé l'arrêt. Le drapeau n'était honoré que par le
    // pipeline d'import côté client ; depuis sa suppression, « annuler » ne
    // faisait plus qu'écrire un statut que ce traitement écrasait ensuite.
    if (job.cancel_requested === true) {
      logInfo({
        message: "Job annulé par l'utilisateur, traitement abandonné",
        moduleType: "IMPORT",
        ...ctx,
      });
      await jobRef.update({
        status: "error",
        error_message: "Job annulé manuellement.",
        current_step: null,
        updated_at: Timestamp.now(),
      });
      return;
    }

    const currentStep = (job.current_step as PipelineStep | undefined) ?? "queued";
    const apiKey = GEMINI_API_KEY.value();
    const start = Date.now();

    try {
      await jobRef.update({
        status: "processing",
        updated_at: Timestamp.now(),
        attempt_count: attempt + 1,
        correlation_id: correlationId,
      });

      // ── IMPORT ────────────────────────────────────────────────────────────
      const fileUrl = job.file_url as string;
      const additionalFileUrls = (job.additional_file_urls as string[] | undefined) ?? [];
      const mimeType = (job.mime_type as string | undefined) ?? "image/jpeg";

      if (stepIndex(currentStep) <= stepIndex("import")) {
        await jobRef.update({ current_step: "import", updated_at: Timestamp.now() });
      }
      const primaryBytes = await downloadFromStorage(fileUrl);
      const additionalBytes = await Promise.all(
        additionalFileUrls.map((u) => downloadFromStorage(u)),
      );

      logInfo({
        message: "Fichiers téléchargés",
        moduleType: "IMPORT",
        ...ctx,
        extra: { primaryBytes: primaryBytes.length, additional: additionalBytes.length },
      });

      // ── Branchement selon le type de job ──────────────────────────────────

      if (jobType === "bookCoverScan") {
        // ── Pipeline couverture de livre ────────────────────────────────────
        await jobRef.update({ current_step: "gemini_call", updated_at: Timestamp.now() });
        const extracted = await extractBookCover(apiKey, primaryBytes, mimeType, {
          ...ctx,
          feature: "book_cover",
          moduleType: "IMPORT",
        });

        await jobRef.update({ current_step: "save", updated_at: Timestamp.now() });
        const now = Timestamp.now();
        // ID déterministe pour éviter les doublons en cas de retry partiel.
        const bookRef = getFirestore().collection(COLL_BOOKS).doc(`book_cover_${jobId}`);
        await bookRef.set({
          titre: extracted.titre,
          sous_titre: extracted.sous_titre ?? null,
          editeur: extracted.editeur ?? null,
          serie: extracted.serie ?? null,
          auteur: extracted.auteur,
          annee: extracted.annee ?? null,
          langue: extracted.langue,
          isbn: extracted.isbn ?? null,
          description: extracted.description ?? null,
          url_couverture: fileUrl,
          tags: extracted.tags ?? [],
          review_status: "validated",
          created_by: userId,
          created_at: now,
          updated_at: now,
          shared_with: [],
          source_file_url: fileUrl,
          source_file_name: (job.file_name as string | undefined) ?? null,
          ai_processed_at: now,
          is_private: false,
        });
        createdBookId = bookRef.id;
        bookTouchedInRun = true;

        const elapsed = Date.now() - start;
        await jobRef.update({
          status: "done",
          current_step: "done",
          created_book_id: bookRef.id,
          updated_at: Timestamp.now(),
          execution_time_ms: elapsed,
        });

        logInfo({
          message: "Pipeline couverture de livre terminé",
          moduleType: "IMPORT",
          executionTimeMs: elapsed,
          ...ctx,
          extra: { bookId: bookRef.id },
        });
        return;
      }

      // ── PASSE 1 : transcription de la page ────────────────────────────────
      //
      // Un seul appel là où trois se succédaient : classifier, extraire une
      // recette, extraire un document. Le premier posait une question à
      // laquelle les deux autres répondaient déjà, et l'extraction faisait deux
      // travaux à la fois — transcrire et restructurer — en perdant le premier.
      await jobRef.update({ current_step: "gemini_call", updated_at: Timestamp.now() });
      const extraPages = additionalBytes.map((b) => ({ bytes: b, mimeType }));
      const transcription = await transcribePage(
        primaryBytes,
        mimeType,
        { ...ctx, feature: "transcription_page", moduleType: "IMPORT" },
        extraPages,
      );

      logInfo({
        message: `Page transcrite: ${transcription.pageType} — "${transcription.titre}"`,
        moduleType: "IMPORT",
        ...ctx,
        extra: {
          pageType: transcription.pageType,
          titre: transcription.titre,
          recettes: transcription.recettes.length,
          raison: transcription.raison,
        },
      });

      // Page vide, de garde, index : rien à créer.
      if (transcription.pageType === "no_recipe") {
        const elapsed = Date.now() - start;
        await jobRef.update({
          status: "done",
          current_step: "done",
          created_recipe_ids: [],
          updated_at: Timestamp.now(),
          execution_time_ms: elapsed,
        });
        logInfo({
          message: "Page sans contenu exploitable — job terminé sans brouillon",
          moduleType: "IMPORT",
          ...ctx,
        });
        return;
      }

      const isRecipePage = transcription.pageType === "recipe";

      if (!isRecipePage && transcription.document.trim().length === 0) {
        logError({
          message: "Page non-recette sans texte transcrit",
          moduleType: "IMPORT",
          ...ctx,
          extra: { pageType: transcription.pageType },
        });
        const elapsed = Date.now() - start;
        await jobRef.update({
          status: "done",
          current_step: "done",
          created_recipe_ids: [],
          updated_at: Timestamp.now(),
          execution_time_ms: elapsed,
        });
        return;
      }

      // ── PARSE + DESIGN + SAVE ─────────────────────────────────────────────
      await jobRef.update({ current_step: "parse", updated_at: Timestamp.now() });
      const bookId = job.book_id as string | undefined;
      const bookTitre = job.book_titre as string | undefined;
      const createdIds: string[] = [];

      // ── DÉTECTION SEULE : on repère, on n'extrait plus ────────────────────
      //
      // L'extraction automatique a été retirée. Elle enchaînait détection,
      // découpage, trois filtres de qualité, correction de perspective,
      // modération Cloud Vision et publication — et rendait des images que
      // personne ne gardait. Chaque maillon a été corrigé tour à tour :
      // l'orientation EXIF, le seuil de subdivision, le cadrage, le repère de
      // coordonnées, l'homographie. Le résultat restait en deçà de ce qu'un
      // recadrage à la main donne en dix secondes.
      //
      // Ce qui reste vaut, lui, son appel : SAVOIR qu'il y a une photo. Sans
      // cette ligne, une recette part sans image et rien ne dit s'il y en avait
      // une à prendre. L'écran de relecture le dit maintenant, et l'atelier
      // manuel — qui n'a jamais démérité — fait le reste.
      await jobRef.update({ current_step: "design", updated_at: Timestamp.now() });
      const illustrationUrls: string[] = [];
      const thumbnailUrls: string[] = [];
      let illustrationReport: IllustrationReport | undefined;
      try {
        // Toutes les pages, pas seulement la première : une recette étalée sur
        // trois pages a ses photographies sur les trois.
        const pages = [primaryBytes, ...additionalBytes];
        let boxesTotal = 0;
        let detectionFailures = 0;

        for (const [pageIndex, rawPageBytes] of pages.entries()) {
          // Redressée selon son EXIF : le modèle reçoit l'image telle qu'elle
          // s'affiche, et une photo de téléphone prise en portrait est stockée
          // couchée. Compter des photos sur une image couchée marche moins bien.
          const pageBytes = await uprightImage(rawPageBytes);

          try {
            const boxes = await detectIllustrationRegions(apiKey, pageBytes, mimeType, {
              ...ctx,
              feature: "detect_illustrations",
              moduleType: "DESIGN",
            });
            boxesTotal += boxes.length;
            if (boxes.length === 0) {
              await logInfo({
                message: `Page ${pageIndex + 1} : aucune photographie détectée`,
                moduleType: "DESIGN",
                jobId,
                userId,
                correlationId,
              });
            }
          } catch (detectErr) {
            // Une page qui échoue n'emporte plus les autres — et l'échec ne se
            // lit plus comme « pas de photo », qui appellerait la réaction
            // inverse.
            detectionFailures += 1;
            await logError({
              message: `Page ${pageIndex + 1} : détection d'illustrations impossible`,
              errorDescription: detectErr instanceof Error ? detectErr.message : String(detectErr),
              moduleType: "DESIGN",
              jobId,
              userId,
              correlationId,
            });
          }
        }

        await logInfo({
          message: `Illustrations : ${boxesTotal} repérée(s) sur ${pages.length} page(s), à extraire à la main`,
          moduleType: "DESIGN",
          jobId,
          userId,
          correlationId,
          extra: { pages: pages.length, detectees: boxesTotal, pagesEnEchec: detectionFailures },
        });

        illustrationReport = {
          detectees: boxesTotal,
          // L'import ne retient ni ne publie plus rien : ces deux compteurs
          // restent pour les recettes importées avant ce changement, dont le
          // bilan porte encore des valeurs non nulles.
          retenues: 0,
          publiees: 0,
          pagesEnEchec: detectionFailures,
        };
      } catch (err) {
        // Best-effort : une recette sans photo vaut mieux qu'un import échoué.
        logError({
          message: "Détection illustrations échouée (continue sans)",
          errorDescription: err instanceof Error ? err.message : String(err),
          moduleType: "DESIGN",
          ...ctx,
        });
      }

      const fileName = (job.file_name as string | undefined) ?? null;
      const pageTypeSaved = transcription.pageType as CookLangPageType;

      // Une page non-recette n'a rien à baliser : son texte part tel quel.
      if (!isRecipePage) {
        await jobRef.update({ current_step: "save", updated_at: Timestamp.now() });
        const id = await saveDraft({
          cooklang: documentCooklang(transcription),
          pageType: pageTypeSaved,
          ingredients: [],
          cuisines: [],
          dishTypes: [],
          userId,
          bookId,
          bookTitre,
          illustrationUrls,
          thumbnailUrls,
          correlationId,
          sourceFileUrl: fileUrl,
          sourceFileName: fileName,
          additionalSourceFileUrls: additionalFileUrls,
          apiKey,
          ctx,
          illustrationReport,
        });
        createdIds.push(id);
        await jobRef.update({ created_recipe_ids: createdIds, updated_at: Timestamp.now() });
      }

      for (const [recipeIndex, recette] of transcription.recettes.entries()) {
        // ── PASSE 2 : balisage et normalisation ─────────────────────────────
        //
        // Cette passe ne voit pas l'image : elle travaille sur ce que la passe 1
        // a recopié. C'est ce qui rend la fidélité vérifiable — et vérifiée,
        // juste en dessous, sans un appel de plus.
        await jobRef.update({ current_step: "tagging", updated_at: Timestamp.now() });
        const tagged = await tagAndNormalize(recette, {
          ...ctx,
          feature: "recipe_tagging",
          moduleType: "IMPORT",
        });

        const fidelity = checkFidelity(recette, tagged);
        if (fidelity.findings.length > 0) {
          const resume = fidelity.findings.map((f) => f.message).join(" ");
          const entree = {
            message: `Contrôle de fidélité (${fidelity.level}) : ${resume}`,
            moduleType: "IMPORT" as const,
            ...ctx,
            extra: {
              titre: recette.titre,
              niveau: fidelity.level,
              codes: fidelity.findings.map((f) => f.code),
            },
          };
          // Une rupture est une erreur : la recette balisée est écartée, et
          // l'utilisateur doit pouvoir le savoir depuis l'écran des journaux
          // sans avoir à comparer avec le livre.
          if (fidelity.rejette) logError(entree);
          else logInfo(entree);
        }

        // Repli : mieux vaut une recette exacte et non balisée qu'une recette
        // balisée et fausse. Les ingrédients, eux, restent ceux de la passe 2 —
        // ils viennent de la liste du livre, que le balisage n'a pas touchée.
        const cooklang = fidelity.rejette ? verbatimCooklang(recette) : tagged.cooklang;

        // Une page qui porte deux recettes leur donnait le MÊME objet Storage.
        // Rien ne cassait tant que supprimer une illustration se contentait de
        // retirer l'URL du document — mais le jour où l'on supprimera vraiment
        // le fichier, la première suppression viderait l'image de l'autre
        // recette, silencieusement, et l'ordre déciderait qui perd sa photo.
        //
        // Chaque recette au-delà de la première reçoit donc sa copie. Un seul
        // verdict de modération pour toutes : c'est la même image, déjà jugée,
        // et la copie conserve les métadonnées de sa décision.
        const ownIllustrations =
          recipeIndex === 0
            ? illustrationUrls
            : await copyPublishedImages(illustrationUrls, { ...ctx });
        const ownThumbnails =
          recipeIndex === 0 ? thumbnailUrls : await copyPublishedImages(thumbnailUrls, { ...ctx });

        const id = await saveDraft({
          cooklang,
          pageType: "recipe",
          ingredients: tagged.ingredients,
          cuisines: tagged.cuisines,
          dishTypes: tagged.dishTypes,
          userId,
          bookId,
          bookTitre,
          illustrationUrls: ownIllustrations,
          thumbnailUrls: ownThumbnails,
          correlationId,
          sourceFileUrl: fileUrl,
          sourceFileName: fileName,
          additionalSourceFileUrls: additionalFileUrls,
          apiKey,
          ctx,
          fidelity,
          illustrationReport,
          onStep: async (step) => {
            await jobRef.update({ current_step: step, updated_at: Timestamp.now() });
          },
          // La normalisation contre les référentiels a lieu AVANT l'écriture :
          // la recette est écrite une fois, avec sa liste définitive. Elle
          // était faite après, ce qui obligeait à réécrire le document et
          // réveillait deux fois le déclencheur — qui calculait courses et
          // nutrition d'abord sur la liste brute, puis sur la normalisée, en
          // jetant le premier travail.
          normalizationDeadlineMs: start + 420_000,
        });
        createdIds.push(id);
        await jobRef.update({ created_recipe_ids: createdIds, updated_at: Timestamp.now() });
      }

      const elapsed = Date.now() - start;
      await jobRef.update({
        status: "done",
        current_step: "done",
        created_recipe_ids: createdIds,
        updated_at: Timestamp.now(),
        execution_time_ms: elapsed,
      });

      logInfo({
        message: "Pipeline terminé avec succès",
        moduleType: "IMPORT",
        executionTimeMs: elapsed,
        ...ctx,
        extra: { createdIds, illustrationCount: illustrationUrls.length },
      });
    } catch (err) {
      const isQuota = err instanceof GeminiQuotaExceededError;
      // Un plafond de dépense ne se réessaie pas : il ne se rouvrira pas dans
      // les minutes qui viennent, et chaque tentative refait tout le travail
      // qui précède l'appel d'IA. Le job part directement en dead letter, d'où
      // un administrateur le relancera demain — ou après avoir relevé le
      // plafond.
      const isBudget = err instanceof BudgetExceededError;
      const message = err instanceof Error ? err.message : String(err);

      if (jobType === "bookCoverScan" && bookTouchedInRun && createdBookId) {
        try {
          await getFirestore().collection(COLL_BOOKS).doc(createdBookId).delete();
          createdBookId = null;
        } catch (cleanupErr) {
          logError({
            message: "Rollback livre échoué après erreur pipeline couverture",
            errorDescription: cleanupErr instanceof Error ? cleanupErr.message : String(cleanupErr),
            moduleType: "IMPORT",
            ...ctx,
            extra: { createdBookId },
          });
        }
      }

      logError({
        message: "Échec pipeline",
        errorDescription: message,
        moduleType: "IMPORT",
        executionTimeMs: Date.now() - start,
        ...ctx,
        extra: { attempt, isQuota, isBudget },
      });

      // Dernière tentative — ou plafond atteint, qu'il est inutile de réessayer.
      if (attempt + 1 >= MAX_RETRY_ATTEMPTS || isBudget) {
        await moveToDeadLetter({
          jobId,
          userId,
          correlationId,
          failureReason: isBudget
            ? "budget_exceeded"
            : isQuota
              ? "quota_exceeded"
              : "pipeline_error",
          lastError: message,
          retryCount: attempt + 1,
          filePath: (job.file_url as string | undefined) ?? "",
        });
        await jobRef.update({
          status: "error",
          error_message: message,
          created_book_id: createdBookId,
          updated_at: Timestamp.now(),
        });
        return; // success-return (no retry) — DLQ handler takes over
      }

      // Sinon on rethrow pour que Cloud Tasks retry.
      throw new HttpsError("internal", message);
    }
  },
);

// ── Helpers ──────────────────────────────────────────────────────────────────

/**
 * Télécharge un fichier depuis Firebase Storage à partir d'une URL gs:// ou https://.
 * Pour les URLs https firebasestorage on extrait le path et on utilise l'Admin SDK.
 */
async function downloadFromStorage(url: string): Promise<Buffer> {
  const path = extractStoragePath(url);
  const [bytes] = await getStorage().bucket().file(path).download();
  return bytes;
}

function extractStoragePath(url: string): string {
  if (url.startsWith("gs://")) {
    // gs://bucket/path/to/file
    const withoutScheme = url.substring(5);
    const slash = withoutScheme.indexOf("/");
    return withoutScheme.substring(slash + 1);
  }
  // https://firebasestorage.googleapis.com/v0/b/<bucket>/o/<encodedPath>?alt=media&token=...
  const match = url.match(/\/o\/([^?]+)/);
  if (match) return decodeURIComponent(match[1]);
  // Fallback : on suppose que c'est déjà un path.
  return url;
}

/**
 * Dépose une découpe dans la quarantaine et rend son chemin.
 *
 * Le pipeline écrivait jusqu'ici en direct dans le dossier publié : avec les
 * droits de l'Admin SDK, il passait à côté des règles Storage **et** de la
 * modération. Ce sont pourtant des photographies choisies par une personne —
 * exactement ce que la modération existe pour regarder. Il emprunte désormais
 * la même porte que le client : quarantaine, verdict, promotion.
 */
/**
 * Duplique des images déjà publiées, pour qu'une seconde recette en soit
 * réellement propriétaire.
 *
 * Deux recettes extraites d'une même page se partageaient le même objet
 * Storage. Le partage ne se voit pas — jusqu'au jour où l'une supprime le
 * fichier et où l'autre affiche un cadre vide, sans erreur et sans coupable.
 *
 * La copie est faite côté serveur : aucun octet ne transite, et les métadonnées
 * de modération suivent l'objet. C'est légitime — c'est la même image, jugée
 * une fois ; la remodérer doublerait la facture pour la même réponse.
 *
 * Best-effort, et jamais silencieux : si la copie échoue, la recette garde
 * l'URL partagée plutôt que de perdre sa photo. Un partage est un risque
 * futur ; une illustration manquante est une perte immédiate.
 */
async function copyPublishedImages(
  urls: string[],
  ctx: { jobId: string; userId: string; correlationId: string },
): Promise<string[]> {
  if (urls.length === 0) return [];
  const bucket = getStorage().bucket();
  const copies: string[] = [];

  for (const url of urls) {
    try {
      const sourcePath = extractStoragePath(url);
      const dot = sourcePath.lastIndexOf(".");
      const suffix = `_${randomUUID().slice(0, 8)}`;
      const targetPath =
        dot > 0
          ? `${sourcePath.slice(0, dot)}${suffix}${sourcePath.slice(dot)}`
          : `${sourcePath}${suffix}`;

      const [copy] = await bucket.file(sourcePath).copy(bucket.file(targetPath));
      copies.push(await getDownloadURL(copy));
    } catch (err) {
      await logError({
        message: "Copie d'illustration impossible — la recette garde l'URL partagée",
        errorDescription: err instanceof Error ? err.message : String(err),
        moduleType: "DESIGN",
        ...ctx,
        extra: { url },
      });
      copies.push(url);
    }
  }

  return copies;
}

/**
 * CookLang d'une page non-recette : les métadonnées, puis le texte recopié.
 */
function documentCooklang(transcription: PageTranscription): string {
  const lines: string[] = [
    `>> page_type: ${transcription.pageType}`,
    `>> titre: ${transcription.titre}`,
  ];
  if (transcription.page != null) lines.push(`>> page: ${transcription.page}`);
  lines.push("");
  lines.push(transcription.document);
  return lines.join("\n");
}

/**
 * Écrit le brouillon — une fois, et une seule.
 *
 * La version précédente écrivait la recette, la normalisait, puis la réécrivait.
 * Deux écritures réveillaient deux fois `onRecipeWritten`, qui consolidait les
 * courses et calculait la nutrition sur la liste brute avant de tout
 * recommencer sur la liste normalisée. La normalisation a lieu ici, avant
 * l'écriture, sur un identifiant réservé — Firestore donne un identifiant sans
 * rien écrire, et c'est tout ce dont les référentiels ont besoin pour se
 * rattacher à la recette.
 */
async function saveDraft(args: {
  cooklang: string;
  pageType: CookLangPageType;
  /** Liste normalisée rendue par la passe 2 ; vide pour une page non-recette. */
  ingredients: NormalizedIngredientLine[];
  cuisines: string[];
  dishTypes: string[];
  userId: string;
  bookId?: string;
  bookTitre?: string;
  illustrationUrls: string[];
  thumbnailUrls: string[];
  correlationId: string;
  sourceFileUrl?: string | null;
  sourceFileName?: string | null;
  additionalSourceFileUrls?: string[];
  apiKey: string;
  ctx: Record<string, unknown>;
  /** Verdict du contrôle de fidélité — absent pour une page non-recette. */
  fidelity?: FidelityReport;
  /** Annonce l'étape en cours à l'écran de suivi. */
  onStep?: (step: string) => Promise<void>;
  /** Ce que la recherche d'illustrations a donné, pour l'écran de relecture. */
  illustrationReport?: IllustrationReport;
  /** Instant limite de la normalisation ; absent = pas de normalisation. */
  normalizationDeadlineMs?: number;
}): Promise<string> {
  const {
    cooklang,
    pageType,
    userId,
    bookId,
    bookTitre,
    illustrationUrls,
    thumbnailUrls,
    correlationId,
    sourceFileUrl,
    sourceFileName,
    additionalSourceFileUrls,
    apiKey,
    ctx,
  } = args;

  const cleaned = stripMeta(cooklang);
  const titre = extractTitle(cooklang);
  const portions = extractPortions(cooklang);
  const pageNumber = extractPageNumber(cooklang);
  const tags = extractTags(cooklang);

  // Remplace les marqueurs [schéma : ...] par des liens image Markdown
  // ![description](url) en suivant l'ordre des illustrations.
  const injectIllustrations = (text: string) => {
    if (illustrationUrls.length === 0) return text;
    let imgIdx = 0;
    return text.replace(/\[sch[eé]ma\s*:\s*([^\]]+)\]/gi, (_match, desc: string) => {
      if (imgIdx < illustrationUrls.length) {
        return `\n\n![${desc.trim()}](${illustrationUrls[imgIdx++]})\n`;
      }
      return `[schéma : ${desc}]`;
    });
  };

  let bodyContent = injectIllustrations(cleaned);
  const recipeCooklangWithIllustrations = injectIllustrations(cooklang);

  // Auto-polish Markdown pour les pages non-recette — best-effort.
  // Une recette n'y passe JAMAIS : son texte est celui du livre, et le polissage
  // reformule.
  if (pageType !== "recipe" && bodyContent.trim().length > 20) {
    try {
      const polished = await polishMarkdown(apiKey, bodyContent, null, {
        ...ctx,
        feature: "polish_markdown",
        moduleType: "IMPORT",
      } as Parameters<typeof polishMarkdown>[3]);
      if (polished) bodyContent = polished;
    } catch (polishErr) {
      logError({
        message: "Auto-polish non-recette échoué (best-effort, contenu sauvegardé sans polish)",
        errorDescription: polishErr instanceof Error ? polishErr.message : String(polishErr),
        moduleType: "IMPORT",
        ...ctx,
      });
    }
  }

  // Les cuisines et types de plat viennent de la passe 2 : ils coûtaient un
  // appel de modèle à eux seuls, pour une question à laquelle le texte balisé
  // répond déjà.
  const cuisines = args.cuisines;
  const dishTypes = args.dishTypes.length > 0 ? args.dishTypes : tags.dishTypes;

  // La liste stockée : ce que la recette DIT, plus la note explicative que le
  // balisage inline ne pouvait pas porter. « 1 filet de saumon de 1,8 kg avec
  // la peau mais écaillée » devient un ingrédient de 1,8 kg et une note — la
  // phrase du livre, elle, n'est pas touchée.
  // `category` porte la section depuis l'origine du projet : deux occurrences
  // d'un même ingrédient dans deux sections sont deux ingrédients, et c'est ce
  // champ qui les distingue. On ne crée pas un second nom pour la même chose.
  let ingredients: StoredRecipeIngredient[] = args.ingredients.map((i) => ({
    name: i.nom,
    qty: i.qte,
    unit: i.unite,
    ...(i.note ? { note: i.note } : {}),
    ...(i.section ? { category: i.section } : {}),
  }));

  // Identifiant réservé sans écriture : la normalisation peut rattacher les
  // référentiels à cette recette avant qu'elle n'existe.
  const docRef = getFirestore().collection(COLL_RECIPES).doc();

  if (pageType === "recipe" && args.normalizationDeadlineMs != null) {
    // La normalisation dure jusqu'à sept minutes. Elle se déroulait sous le
    // libellé « Enregistrement de la recette », qui en promet une seconde.
    await args.onStep?.("normalize");
    try {
      const normalized = await normalizeRecipeReferentialsCore({
        aiEnabled: true,
        recipeId: docRef.id,
        cooklang,
        ingredients: ingredients as unknown as Array<Record<string, unknown>>,
        userId,
        correlationId,
        deadlineMs: args.normalizationDeadlineMs,
      });
      ingredients = normalized.resolvedIngredients;
      logInfo({
        message: `Normalisation: ${normalized.stats.renamedIngredients} noms, ${normalized.stats.renamedUnits} unités`,
        moduleType: "IMPORT",
        ...ctx,
        extra: { recipeId: docRef.id },
      });
    } catch (normErr) {
      // Best-effort : la recette est écrite avec la liste de la passe 2, qui
      // est déjà exploitable. Le déclencheur d'écriture enrichira ce qu'il peut.
      logError({
        message: "Normalisation référentiels échouée (recette écrite sans)",
        errorDescription: normErr instanceof Error ? normErr.message : String(normErr),
        moduleType: "IMPORT",
        ...ctx,
        extra: { recipeId: docRef.id },
      });
    }
  }

  const ingredientsIndex = buildIngredientsIndex(
    ingredients.map((i) => ({ name: i.name, qty: i.qty, unit: i.unit })),
  );

  // Le texte réellement écrit en base, à comparer avec celui de la transcription.
  await logAiText({
    stage: "enregistrement",
    text: cooklang,
    message: "Texte enregistré en base pour cette recette",
    feature: "recipe_tagging",
    moduleType: "IMPORT",
    correlationId,
    userId,
    extra: {
      titre,
      pageType,
      ingredients: ingredients.length,
      // Combien portent une précision du livre. Deux fois de suite, la note a
      // été cherchée au mauvais endroit — dans l'affichage, puis dans le
      // modèle — faute de savoir si elle existait. Ce compteur tranche.
      avecNote: ingredients.filter((i) => typeof i.note === "string" && i.note.length > 0).length,
    },
  });

  await args.onStep?.("save");
  const now = FieldValue.serverTimestamp();
  await docRef.set({
    titre,
    langue: "fr",
    raw_cooklang: cooklang,
    draft_cooklang:
      pageType !== "recipe"
        ? bodyContent
        : illustrationUrls.length > 0
          ? recipeCooklangWithIllustrations
          : cleaned || cooklang,
    page_type: pageType,
    page_number: pageNumber,
    portions,
    ingredients_index: ingredientsIndex,
    ingredients,
    tags: {
      difficulty: tags.difficulty,
      prep_time: tags.prepTime,
      cook_time: tags.cookTime,
      cuisines,
      dish_types: dishTypes,
    },
    book_id: bookId ?? null,
    book_titre: bookTitre ?? null,
    image_urls: illustrationUrls,
    thumbnail_urls: thumbnailUrls,
    source_file_url: sourceFileUrl ?? null,
    source_file_name: sourceFileName ?? null,
    additional_source_file_urls: additionalSourceFileUrls ?? [],
    review_status: "draft",
    // Ce que le contrôle de fidélité a constaté, sur la recette elle-même :
    // un écart doit se voir depuis l'écran de relecture, pas seulement dans
    // les journaux d'un import déjà oublié.
    ...(args.illustrationReport ? { illustration_report: args.illustrationReport } : {}),
    ...(args.fidelity && args.fidelity.level !== "ok"
      ? {
          fidelity_level: args.fidelity.level,
          // Le message et ses éléments partent séparés : l’écran les rend en
          // liste à puces. Concaténés, sept mots mal lus formaient un pavé
          // qu’on ne relisait pas — et une alerte qu’on ne relit pas ne sert à
          // rien.
          fidelity_findings: args.fidelity.findings.map((f) => ({
            message: f.message,
            items: f.items ?? [],
          })),
        }
      : {}),
    created_by: userId,
    created_at: now,
    updated_at: now,
    ai_processed_at: now,
    pipeline_correlation_id: correlationId,
  });
  return docRef.id;
}

async function moveToDeadLetter(args: {
  jobId: string;
  userId: string;
  correlationId: string;
  failureReason: string;
  lastError: string;
  retryCount: number;
  filePath: string;
}): Promise<void> {
  await getFirestore().collection(COLL_DEAD_LETTERS).add({
    original_job_id: args.jobId,
    user_id: args.userId,
    correlation_id: args.correlationId,
    failure_reason: args.failureReason,
    last_error: args.lastError,
    retry_count: args.retryCount,
    file_path: args.filePath,
    failed_at: FieldValue.serverTimestamp(),
    relaunched_at: null,
    queue_name: QUEUE_RECIPE_PROCESSING,
  });
}

/**
 * Ce que la recherche d'illustrations a donné, étape par étape.
 *
 * « Aucune photo » posait trois questions sans réponse : la page n'en
 * portait-elle pas ? les filtres ont-ils tout écarté ? la détection a-t-elle
 * échoué ? Trois causes, trois réactions — rescanner, ajouter la photo à la
 * main, ou signaler une panne — et aucun moyen de choisir.
 */
export interface IllustrationReport {
  detectees: number;
  retenues: number;
  publiees: number;
  pagesEnEchec: number;
}
