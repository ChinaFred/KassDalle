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
import { getStorage } from "firebase-admin/storage";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";
import { HttpsError } from "firebase-functions/v2/https";
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
import { logAiText, logError, logInfo, logWarn, newCorrelationId } from "../logging";
import {
  needsTranslation,
  transcribePage,
  type PageTranscription,
  type RecipeTranslationOrigin,
  type TranscribedRecipe,
} from "../gemini/transcription";
import { translateRecipe } from "../gemini/translation";
import { ORIGINAL_TEXT_DOC_ID, originalTextDocument, SUBCOLL_ORIGINAL_TEXT } from "./originalText";
import {
  tagAndNormalize,
  TaggingTruncatedError,
  type NormalizedIngredientLine,
} from "../gemini/tagging";
import { checkFidelity, verbatimCooklang, type FidelityReport } from "../gemini/fidelity";
import { extractBookCover } from "../gemini/search";
import { polishMarkdown } from "../gemini/refiner";
import { precheckPageImages } from "../illustrations/extract";
import { extractAndStorePageIllustrations } from "../illustrations/store";
import { GeminiQuotaExceededError } from "../gemini/client";
import { BudgetExceededError } from "../ai/budget";
import { assertWithinImportBudget } from "../ai/importBudget";
import { expectedPrivacy } from "../triggers/recipePrivacy";
import {
  normalizeRecipeReferentialsCore,
  type StoredRecipeIngredient,
} from "../nutrition/referentialNormalization";
import { ingredientsFromCooklang } from "./ingredientsFromCooklang";
import { BookFileError } from "../books/bookFile";
import { TargetBookNotOwned, assertJobTargetBook } from "./targetBook";
import {
  StoragePathRefusedError,
  promotedScanPrefix,
  resolveAllowedStoragePath,
  storageEmulatorActive,
} from "../utils/storagePath";
import { ZipLimitError } from "../utils/boundedZip";
import { parseBookWindow, runBookImport } from "./bookImport";
import { parseCheckpoint, serializeCheckpoint } from "./transcriptionCheckpoint";
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
  /** Scan de l'utilisateur — posé par le client, transmis par le dispatcher. */
  scanId?: string;
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
  | "translate"
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
  "translate",
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

/**
 * Le nom qu'une ligne de suivi porte une fois la page lue, à la place du
 * fichier.
 *
 * Écrit sur le job dès la transcription : entre elle et l'enregistrement du
 * brouillon, le balisage et la normalisation durent jusqu'à sept minutes, et
 * la file n'affichait que `page_<horodatage>_01.jpg`. Une page à plusieurs
 * recettes les nomme toutes. `null` quand le modèle n'a rien lu, pour que la
 * ligne garde le nom de fichier.
 */
function titreDeSuivi(transcription: PageTranscription): string | null {
  const titres = transcription.recettes.map((r) => r.titre.trim()).filter((t) => t.length > 0);
  if (titres.length > 1) return titres.join(", ");
  const titre = (titres[0] ?? transcription.titre).trim();
  return titre.length > 0 ? titre : null;
}

export const recipeProcessor = onTaskDispatched(
  {
    region: REGION,
    secrets: [GEMINI_API_KEY, ANTHROPIC_API_KEY],
    // Deux gigaoctets pour le job « livre entier » : un PDF de plusieurs
    // centaines de mégaoctets se charge en mémoire, une fois en octets bruts et
    // une fois dans l'arbre de `pdf-lib`. La mémoire allouée se facture pendant
    // tout le traitement, y compris pour une page de recette qui n'en utilise
    // qu'une fraction : quelques millièmes de dollar par import.
    memory: "2GiB",
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
    const ctx = { jobId, userId, correlationId, scanId: payload.scanId };

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
    // Le payload de la tâche est écrit une fois, à la mise en file ; le job,
    // lui, est relu à chaque tentative. Une tâche partie avant l'existence du
    // champ retrouve ainsi son scan, écrit depuis par le dispatcher.
    if (!ctx.scanId && typeof job.scan_id === "string" && job.scan_id) {
      ctx.scanId = job.scan_id;
    }
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

      // Le livre cible doit appartenir à l'importateur (ou l'importateur être
      // administrateur) : l'écriture qui suit se fait hors règles.
      await assertJobTargetBook(job.book_id, (job.created_by as string | undefined) ?? userId);

      // ── IMPORT ────────────────────────────────────────────────────────────
      const fileUrl = job.file_url as string;
      const rawAdditional: unknown = job.additional_file_urls ?? [];
      const additionalFileUrls = Array.isArray(rawAdditional) ? (rawAdditional as string[]) : [];
      const mimeType = (job.mime_type as string | undefined) ?? "image/jpeg";

      // Le fichier source vient du client : seul le dossier promu du
      // propriétaire du job est lisible. Vérifié avant tout téléchargement et
      // tout appel de modèle — un refus part en dead letter sans retry.
      const sourceOwner = (job.created_by as string | undefined) ?? userId;
      const primaryPath = resolveJobSourcePath(fileUrl, sourceOwner);
      const additionalPaths = additionalFileUrls.map((u) => resolveJobSourcePath(u, sourceOwner));

      if (stepIndex(currentStep) <= stepIndex("import")) {
        await jobRef.update({ current_step: "import", updated_at: Timestamp.now() });
      }
      const primaryBytes = await downloadFromStorage(primaryPath);
      const additionalBytes = await Promise.all(
        additionalPaths.map((path) => downloadFromStorage(path)),
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

        // Le titre du livre remplace le nom de fichier sur la ligne de suivi.
        await jobRef.update({
          current_step: "save",
          titre: extracted.titre.trim() || null,
          updated_at: Timestamp.now(),
        });
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

      if (jobType === "bookDocumentScan") {
        // ── Pipeline livre entier ───────────────────────────────────────────
        //
        // Ce job ne transcrit rien : il crée le livre puis un job d'import par
        // tranche, qui suivent le pipeline ci-dessous comme une page scannée.
        const imported = await runBookImport({
          job,
          bytes: primaryBytes,
          apiKey,
          ctx,
          onProgress: async (fields) => {
            await jobRef.update({ ...fields, updated_at: Timestamp.now() });
          },
        });
        const elapsed = Date.now() - start;
        await jobRef.update({
          status: "done",
          current_step: "done",
          titre: imported.bookTitre,
          created_book_id: imported.createdBook ? imported.bookId : null,
          windows_total: imported.windows,
          updated_at: Timestamp.now(),
          execution_time_ms: elapsed,
        });
        logInfo({
          message: "Pipeline livre entier terminé",
          moduleType: "IMPORT",
          executionTimeMs: elapsed,
          ...ctx,
          extra: { bookId: imported.bookId, windows: imported.windows },
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
      // Présent quand ce job lit une tranche d'un livre entier : le modèle sait
      // alors quelles pages lui appartiennent et lesquelles ne servent que de
      // contexte. Absent pour une page scannée ordinaire.
      const bookWindow = parseBookWindow(job.book_window);

      // Une tentative qui suit un échec relit la transcription déjà obtenue au
      // lieu de la refaire : c'est l'appel le plus cher du job, et le balisage
      // qui a échoué ne le remet pas en cause.
      let transcription = await readTranscriptionCheckpoint(job, ctx);
      if (transcription) {
        logInfo({
          message:
            "Transcription reprise du point de reprise du job : l'appel de modèle n'est pas refait",
          moduleType: "IMPORT",
          ...ctx,
        });
      } else {
        // Le plafond de l'import se vérifie avant le premier appel de la tranche.
        // Une page scannée ordinaire n'a pas de plafond propre : elle relève du
        // plafond du jour, que le routeur contrôle.
        if (bookWindow) await assertWithinImportBudget(ctx.scanId, "transcription_page");
        transcription = await transcribePage(
          primaryBytes,
          mimeType,
          { ...ctx, feature: "transcription_page", moduleType: "IMPORT" },
          extraPages,
          bookWindow,
        );
        await saveTranscriptionCheckpoint(jobRef, transcription, ctx);
      }

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

      await jobRef.update({ titre: titreDeSuivi(transcription), updated_at: Timestamp.now() });

      // Page vide, de garde, index : rien à créer.
      if (transcription.pageType === "no_recipe") {
        const elapsed = Date.now() - start;
        await jobRef.update({
          status: "done",
          current_step: "done",
          created_recipe_ids: [],
          transcription_checkpoint: FieldValue.delete(),
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
          transcription_checkpoint: FieldValue.delete(),
          updated_at: Timestamp.now(),
          execution_time_ms: elapsed,
        });
        return;
      }

      // ── TRADUCTION d'une recette écrite dans une autre langue ─────────────
      //
      // La langue est lue par la transcription, sans appel de plus : une page
      // française ne passe jamais ici. Une recette étrangère est traduite avant
      // le balisage, et toute la suite travaille sur la traduction. Le point de
      // reprise est réécrit avec elle : une relance après un balisage en échec
      // ne la refait pas.
      if (transcription.recettes.some(needsTranslation)) {
        await jobRef.update({ current_step: "translate", updated_at: Timestamp.now() });
        const recettes: TranscribedRecipe[] = [...transcription.recettes];
        for (let i = 0; i < recettes.length; i++) {
          if (!needsTranslation(recettes[i])) continue;
          if (bookWindow) await assertWithinImportBudget(ctx.scanId, "recipe_translation");
          recettes[i] = await translateRecipe(recettes[i], {
            ...ctx,
            feature: "recipe_translation",
            moduleType: "IMPORT",
          });
          // Point de reprise après chaque recette : si la suivante échoue, la
          // relance ne retraduit pas celle-ci.
          transcription = { ...transcription, recettes: [...recettes] };
          await saveTranscriptionCheckpoint(jobRef, transcription, ctx);
        }
        logInfo({
          message: "Recette(s) traduite(s) en français avant balisage",
          moduleType: "IMPORT",
          ...ctx,
          extra: {
            langues: recettes
              .map((r) => r.traduction?.langue)
              .filter((l): l is string => l != null),
          },
        });
        await jobRef.update({ titre: titreDeSuivi(transcription), updated_at: Timestamp.now() });
      }

      // ── PARSE + DESIGN + SAVE ─────────────────────────────────────────────
      await jobRef.update({ current_step: "parse", updated_at: Timestamp.now() });
      const bookId = job.book_id as string | undefined;
      const bookTitre = job.book_titre as string | undefined;
      const createdIds: string[] = [];

      // ── ILLUSTRATIONS ─────────────────────────────────────────────────────
      //
      // Deux chemins, selon ce que l'utilisateur a coché à l'import.
      //
      // **Coché** : la chaîne complète, mise au point dans le bac à sable —
      // pré-contrôle, cadrage, mise à plat, remise à l'endroit, zones, découpe.
      // Elle rend des images attachées à la recette, et coûte jusqu'à cinq
      // appels de modèle par page.
      //
      // **Décoché** : ce qui existait avant, et rien de plus — un appel par
      // page qui COMPTE les photographies sans les extraire. Le bilan de
      // relecture continue de dire s'il y avait quelque chose à prendre, et
      // l'atelier manuel fait le reste.
      //
      // Les deux ne se cumulent jamais : le pré-contrôle de la chaîne complète
      // pose exactement la même question que la détection seule, et les facturer
      // toutes les deux ne rendrait rien.
      //
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
      const wantsIllustrations = job.import_illustrations === true;
      try {
        // Toutes les pages, pas seulement la première : une recette étalée sur
        // trois pages a ses photographies sur les trois.
        const pages = [primaryBytes, ...additionalBytes];

        if (wantsIllustrations) {
          const stored = await extractAndStorePageIllustrations({
            pages,
            mimeType,
            userId,
            jobId,
            correlationId,
            scanId: ctx.scanId,
            fileName: (job.file_name as string | undefined) ?? undefined,
          });
          illustrationUrls.push(...stored.urls);
          illustrationReport = {
            detectees: stored.detectees,
            retenues: stored.retenues,
            publiees: stored.publiees,
            pagesEnEchec: stored.pagesEnEchec,
          };
        } else if (!bookWindow) {
          // Une tranche de livre n'a pas de comptage de photographies : c'est un
          // appel d'IA de plus par tranche, sur un livre qui en compte des
          // centaines, pour une information que l'atelier manuel n'attend pas.
          illustrationReport = await countPageImages({
            pages,
            mimeType,
            jobId,
            userId,
            correlationId,
            scanId: ctx.scanId,
            fileName: (job.file_name as string | undefined) ?? undefined,
          });
        }
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
          mealRole: null,
          contains: [],
          suggestedSides: [],
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

      for (const recette of transcription.recettes) {
        // ── PASSE 2 : balisage et normalisation ─────────────────────────────
        //
        // Cette passe ne voit pas l'image : elle travaille sur ce que la passe 1
        // a recopié. C'est ce qui rend la fidélité vérifiable — et vérifiée,
        // juste en dessous, sans un appel de plus.
        await jobRef.update({ current_step: "tagging", updated_at: Timestamp.now() });
        if (bookWindow) await assertWithinImportBudget(ctx.scanId, "recipe_tagging");
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

        // Plus aucune image n'est attachée à l'import.
        //
        // Il y avait ici la copie des illustrations pour la seconde recette
        // d'une même page — deux recettes ne pouvaient pas partager un objet
        // Storage sans que la suppression de l'une vide l'autre. Ce soin n'a
        // plus d'objet : l'import ne publie rien. Le garder aurait laissé
        // croire, au prochain lecteur, qu'une extraction se produit encore.
        const id = await saveDraft({
          cooklang,
          pageType: "recipe",
          ingredients: tagged.ingredients,
          cuisines: tagged.cuisines,
          dishTypes: tagged.dishTypes,
          mealRole: tagged.mealRole,
          contains: tagged.contains,
          suggestedSides: tagged.suggestedSides,
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
          fidelity,
          illustrationReport,
          traduction: recette.traduction,
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
        transcription_checkpoint: FieldValue.delete(),
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
      // Seule exception : trop d'appels simultanés (`concurrency`) se libère
      // en quelques secondes, et se réessaie comme une panne passagère.
      const isBudget = err instanceof BudgetExceededError && err.reason !== "concurrency";
      // Un livre illisible — PDF chiffré, EPUB sans texte — le reste à chaque
      // tentative, et chacune retélécharge le fichier en entier.
      const isUnreadableBook = err instanceof BookFileError;
      // Un balisage coupé au plafond à tous les efforts essayés se rejouerait à
      // l'identique : les deux appels ont déjà eu lieu.
      const isTruncatedTagging = err instanceof TaggingTruncatedError;
      // Le livre d'un autre le restera à chaque tentative.
      const isForeignBook = err instanceof TargetBookNotOwned;
      // Un fichier source hors du dossier du propriétaire le restera.
      const isForbiddenSource = err instanceof StoragePathRefusedError;
      // Une archive (DOCX, EPUB) au-delà des bornes de lecture le restera :
      // chaque tentative la retéléchargerait pour la refuser au même endroit.
      const isZipLimit = err instanceof ZipLimitError;
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
        extra: {
          attempt,
          isQuota,
          isBudget,
          isUnreadableBook,
          isTruncatedTagging,
          isForeignBook,
          isForbiddenSource,
          isZipLimit,
        },
      });

      // Dernière tentative — ou plafond atteint, fichier illisible, balisage
      // coupé, livre cible d'un autre (`foreign_book`), fichier source hors du
      // dossier du propriétaire (`forbidden_source_path`), archive au-delà des
      // bornes de lecture (`archive_limit_exceeded`) : ces six cas se rejouent
      // à l'identique, il est inutile de les réessayer.
      if (
        attempt + 1 >= MAX_RETRY_ATTEMPTS ||
        isBudget ||
        isUnreadableBook ||
        isTruncatedTagging ||
        isForeignBook ||
        isForbiddenSource ||
        isZipLimit
      ) {
        await moveToDeadLetter({
          jobId,
          userId,
          correlationId,
          failureReason: isBudget
            ? "budget_exceeded"
            : isUnreadableBook
              ? "book_file_unreadable"
              : isTruncatedTagging
                ? "tagging_truncated"
                : isForeignBook
                  ? "foreign_book"
                  : isForbiddenSource
                    ? "forbidden_source_path"
                    : isZipLimit
                      ? "archive_limit_exceeded"
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
 * Chemin d'objet d'un fichier source de job, ou `StoragePathRefusedError`.
 *
 * Seul `scans/{propriétaire}/…` est admis : c'est là que
 * `scanAndPromoteUploadFn` promeut une page ou un livre contrôlé, et là que
 * l'import d'un livre découpe ses tranches. Un chemin vers `rejected/`, vers la
 * quarantaine ou vers les scans d'un autre compte est refusé.
 */
function resolveJobSourcePath(reference: unknown, ownerUid: string): string {
  if (typeof reference !== "string" || !ownerUid) {
    throw new StoragePathRefusedError("", "Fichier source absent ou propriétaire du job inconnu.");
  }
  return resolveAllowedStoragePath(reference, [promotedScanPrefix(ownerUid)], {
    bucketName: getStorage().bucket().name,
    allowEmulator: storageEmulatorActive(),
  });
}

/** Télécharge un objet du bucket par défaut — chemin déjà vérifié. */
async function downloadFromStorage(path: string): Promise<Buffer> {
  const [bytes] = await getStorage().bucket().file(path).download();
  return bytes;
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
  /** Rôle dans un repas rendu par la passe 2 ; `null` quand elle n'a pas su. */
  mealRole: string | null;
  contains: string[];
  suggestedSides: string[];
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
  /** La recette d'origine, quand celle-ci a été traduite. */
  traduction?: RecipeTranslationOrigin;
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
    // La ligne du livre suit l'ingrédient jusqu'en base.
    //
    // La note s'en déduit, et quand elle manque on ne savait pas trancher :
    // le livre ne disait-il rien de plus, ou la déduction a-t-elle échoué ?
    // Trois tours de recherche pour cette seule question. La pièce à
    // conviction voyage désormais avec la pièce à conviction.
    ...(i.brut ? { source: i.brut } : {}),
  }));

  // Repli : une recette en prose n'a pas de liste à normaliser.
  //
  // Le balisage part des lignes recopiées par la transcription. Un livre qui
  // écrit « faites revenir un oignon avec deux gousses d'ail » n'en donne
  // aucune : la liste arrivait vide ici, et la recette s'enregistrait sans
  // ingrédients — donc sans liste de courses, sans planification et sans
  // nutrition — pendant que son CookLang portait bien ses `@aliment{…}`.
  //
  // La dérivation a lieu AVANT la normalisation, pour que ces noms passent par
  // le référentiel comme les autres.
  if (pageType === "recipe" && ingredients.length === 0) {
    ingredients = ingredientsFromCooklang(cooklang);
    if (ingredients.length > 0) {
      logInfo({
        message: `Liste d'ingrédients dérivée du texte balisé : ${ingredients.length} ingrédient(s)`,
        moduleType: "IMPORT",
        ...ctx,
        extra: { titre, ingredients: ingredients.length },
      });
    }
  }

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
    scanId: ctx.scanId as string | undefined,
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
  const recipeData = {
    titre,
    langue: "fr",
    // Posé seulement sur une recette traduite : son absence veut dire « écrite
    // en français », et les recettes existantes n'ont rien à reprendre.
    ...(args.traduction ? { langue_origine: args.traduction.langue } : {}),
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
      // Écrit inconditionnellement, comme les deux autres : une clé absente ne
      // pourrait plus effacer une valeur saisie par erreur.
      rest_time: tags.restTime ?? null,
      cuisines,
      dish_types: dishTypes,
      // Le rôle dans un repas, reconnu par la passe 2. `null` quand le modèle
      // n'a pas su : le backfill « Rôle des recettes » repasse sur ceux-là.
      meal_role: args.mealRole,
      contains: args.contains,
      suggested_sides: args.suggestedSides,
    },
    book_id: bookId ?? null,
    book_titre: bookTitre ?? null,
    // La confidentialité du livre porteur, écrite dès la création. Le
    // déclencheur `onRecipeWritten` la poserait de toute façon, mais après coup
    // — donc au prix d'une écriture de plus et d'un réveil supplémentaire par
    // page importée. Une lecture de livre coûte moins que les deux.
    is_private: await expectedPrivacy(bookId ?? null),
    image_urls: illustrationUrls,
    thumbnail_urls: thumbnailUrls,
    source_file_url: sourceFileUrl ?? null,
    source_file_name: sourceFileName ?? null,
    additional_source_file_urls: additionalSourceFileUrls ?? [],
    review_status: "draft",
    // Ce qui a écrit ce document : l'écran de relecture le dit au lecteur,
    // sans le déduire du livre porteur ni du fichier source.
    origin: "scan",
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
    // Le déclencheur d'écriture n'a pas d'autre moyen de savoir d'où vient la
    // recette : il part sur une écriture Firestore, sans lien avec la tâche
    // qui l'a produite. Sans ce champ, la nutrition et les courses d'un import
    // formaient un groupe de journaux à part, et leur coût sortait du total
    // du scan.
    scan_id: (args.ctx.scanId as string | undefined) ?? null,
  };

  // Le texte d'origine vit dans un sous-document, lu seulement quand on
  // l'ouvre : la recette est lue dans toutes les listes, et n'a pas à porter
  // une seconde copie de son contenu. Les deux écritures partent ensemble :
  // une recette marquée traduite sans son original afficherait un lien vide.
  if (args.traduction) {
    const batch = getFirestore().batch();
    batch.set(docRef, recipeData);
    batch.set(
      docRef.collection(SUBCOLL_ORIGINAL_TEXT).doc(ORIGINAL_TEXT_DOC_ID),
      originalTextDocument(args.traduction, now),
    );
    await batch.commit();
  } else {
    await docRef.set(recipeData);
  }
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

type JobLogContext = { jobId: string; userId: string; correlationId: string; scanId?: string };

/**
 * Relit le point de reprise de la transcription écrit sur le job, s'il y en a un.
 *
 * Un point de reprise illisible n'arrête pas le job : la page est transcrite de
 * nouveau, et l'incident est journalisé.
 */
async function readTranscriptionCheckpoint(
  job: Record<string, unknown>,
  ctx: JobLogContext,
): Promise<PageTranscription | null> {
  try {
    return parseCheckpoint(job.transcription_checkpoint);
  } catch (err) {
    await logError({
      message: "Point de reprise de la transcription illisible : la page est transcrite de nouveau",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "IMPORT",
      ...ctx,
    });
    return null;
  }
}

/**
 * Écrit la transcription sur le job, pour qu'une nouvelle tentative ne la refasse pas.
 *
 * Best-effort : un point de reprise qui n'a pas pu s'écrire coûte une
 * transcription de plus à la tentative suivante, il ne fait pas échouer celle-ci.
 */
async function saveTranscriptionCheckpoint(
  jobRef: FirebaseFirestore.DocumentReference,
  transcription: PageTranscription,
  ctx: JobLogContext,
): Promise<void> {
  const json = serializeCheckpoint(transcription);
  if (json == null) {
    await logWarn({
      message: "Transcription trop volumineuse pour un point de reprise : non enregistrée",
      moduleType: "IMPORT",
      ...ctx,
    });
    return;
  }
  try {
    await jobRef.update({ transcription_checkpoint: json, updated_at: Timestamp.now() });
  } catch (err) {
    await logError({
      message: "Point de reprise de la transcription non écrit : une nouvelle tentative la refera",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "IMPORT",
      ...ctx,
    });
  }
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

/**
 * Compter les images d'une page, sans rien en extraire.
 *
 * C'est ce qui s'applique quand l'utilisateur n'a pas coché l'extraction. Sans
 * ce chiffre, une recette part sans image et rien ne dit s'il y en avait une à
 * prendre : l'écran de relecture le dit, et l'atelier manuel fait le reste.
 *
 * ## Pourquoi le pré-contrôle, et non `detectIllustrationRegions`
 *
 * Ce chemin appelait le détecteur complet et n'en gardait que `boxes.length`.
 * Deux prompts posaient donc la même question — « cette page porte-t-elle des
 * images, et combien » —, et celui-là était le plus lourd des deux : il décrit
 * un repère de coordonnées, des règles de cadrage et un format de boîte dont
 * l'appelant ne faisait rien.
 *
 * `detectIllustrationRegions` garde son vrai rôle : rendre des boîtes à
 * découper pour l'atelier manuel (`detectAndCropIllustrationsFn`), qui, lui, en
 * a besoin.
 *
 * Une page qui échoue n'emporte pas les autres, et son échec ne se lit pas
 * comme « pas de photo » — les deux appellent des réactions opposées.
 */
async function countPageImages(args: {
  pages: Buffer[];
  mimeType: string;
  jobId: string;
  userId: string;
  correlationId: string;
  scanId?: string;
  fileName?: string;
}): Promise<IllustrationReport> {
  const { pages, mimeType, jobId, userId, correlationId, scanId, fileName } = args;

  let total = 0;
  let failures = 0;

  for (const [index, bytes] of pages.entries()) {
    const precheck = await precheckPageImages({
      bytes,
      mimeType,
      correlationId: `${correlationId}_p${index + 1}`,
      scanId,
      userId,
      jobId,
      fileName: fileName ? `${fileName} (page ${index + 1})` : undefined,
    });
    if (precheck.failed) {
      failures += 1;
      continue;
    }
    total += precheck.count;
  }

  await logInfo({
    message: `Illustrations : ${total} repérée(s) sur ${pages.length} page(s), à extraire à la main`,
    moduleType: "DESIGN",
    jobId,
    userId,
    correlationId,
    scanId,
    extra: { pages: pages.length, detectees: total, pagesEnEchec: failures },
  });

  return {
    detectees: total,
    // Ce chemin ne retient ni ne publie rien : ces deux compteurs restent pour
    // les recettes importées avant ce changement, dont le bilan porte encore
    // des valeurs non nulles.
    retenues: 0,
    publiees: 0,
    pagesEnEchec: failures,
  };
}
