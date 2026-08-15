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
import { logError, logInfo, newCorrelationId } from "../logging";
import { extractRecipes, classifyPage, extractDocument } from "../gemini/extractor";
import { extractBookCover } from "../gemini/search";
import { polishMarkdown } from "../gemini/refiner";
import { detectIllustrationRegions, cropIllustrations } from "../gemini/detector";
import { GeminiQuotaExceededError } from "../gemini/client";
import { normalizeRecipeReferentialsCore } from "../nutrition/referentialNormalization";
import {
  extractTitle,
  extractPortions,
  extractPageNumber,
  extractIngredientsStructured,
  buildIngredientsIndex,
  extractTags,
  stripMeta,
  CookLangPageType,
} from "../cooklang/parser";
import { suggestRecipeTags } from "../gemini/tagger";
import sharp from "sharp";

interface ProcessorPayload {
  jobId: string;
  userId: string;
  correlationId?: string;
}

type PipelineStep =
  "queued" | "import" | "image_decode" | "gemini_call" | "parse" | "design" | "save" | "done";

const STEP_ORDER: PipelineStep[] = [
  "queued",
  "import",
  "image_decode",
  "gemini_call",
  "parse",
  "design",
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
    const correlationId = payload.correlationId ?? newCorrelationId("proc");
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

      // ── GEMINI APPEL 1 : classification de la page ────────────────────────
      await jobRef.update({ current_step: "gemini_call", updated_at: Timestamp.now() });
      const extraPages = additionalBytes.map((b) => ({ bytes: b, mimeType }));
      const classification = await classifyPage(
        apiKey,
        primaryBytes,
        mimeType,
        { ...ctx, feature: "classify_page", moduleType: "IMPORT" },
        extraPages,
      );

      logInfo({
        message: `Page classifiée: ${classification.pageType} — "${classification.titre}"`,
        moduleType: "IMPORT",
        ...ctx,
        extra: { pageType: classification.pageType, titre: classification.titre },
      });

      // Si page vide / inutile : on termine le job sans créer de brouillon.
      if (classification.pageType === "no_recipe") {
        const elapsed = Date.now() - start;
        await jobRef.update({
          status: "done",
          current_step: "done",
          created_recipe_ids: [],
          updated_at: Timestamp.now(),
          execution_time_ms: elapsed,
        });
        logInfo({
          message: "Page classifiée NO_RECIPE — job terminé sans brouillon",
          moduleType: "IMPORT",
          ...ctx,
        });
        return;
      }

      // ── GEMINI APPEL 2 : extraction selon le type ─────────────────────────
      let cooklangs: string[];
      if (classification.pageType === "recipe") {
        // Appel 2a : extraction CookLang (prompt dédié aux recettes)
        cooklangs = await extractRecipes(
          apiKey,
          primaryBytes,
          mimeType,
          // Le même poste que celui qu'`extractRecipes` impose de son côté.
          // On lisait ici « scan », écrasé aussitôt : sans effet, mais le
          // lecteur y voyait un poste qui n'existe nulle part — ni dans la
          // liste des postes routables, ni dans le reporting de coûts.
          // `moduleType` suit ses voisins : c'est de l'import, pas de la
          // recherche.
          { ...ctx, feature: "scan_extraction", moduleType: "IMPORT" },
          extraPages,
        );
        if (cooklangs.length === 0) {
          // Classification "recipe" mais aucune étape extraite → log et on termine.
          logError({
            message: "Classifié recipe mais aucun CookLang extrait",
            moduleType: "IMPORT",
            ...ctx,
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
      } else {
        // Appel 2b : extraction verbatim du document (ingredient_note, technique, etc.)
        const docContent = await extractDocument(
          apiKey,
          primaryBytes,
          mimeType,
          { ...ctx, feature: "document_extraction", moduleType: "IMPORT" },
          classification,
          extraPages,
        );
        cooklangs = [docContent];
      }
      const isRecipePage = classification.pageType === "recipe";
      logInfo({
        message: `${cooklangs.length} ${isRecipePage ? "recette(s)" : "document(s) non-recette"} extrait(s)`,
        moduleType: "IMPORT",
        ...ctx,
        extra: { count: cooklangs.length, pageType: classification.pageType },
      });

      // ── PARSE + DESIGN + SAVE ─────────────────────────────────────────────
      await jobRef.update({ current_step: "parse", updated_at: Timestamp.now() });

      const bookId = job.book_id as string | undefined;
      const bookTitre = job.book_titre as string | undefined;
      const createdIds: string[] = [];

      // Pour la détection d'illustrations on travaille sur la 1re image principale
      await jobRef.update({ current_step: "design", updated_at: Timestamp.now() });
      let illustrationUrls: string[] = [];
      let thumbnailUrls: string[] = [];
      try {
        const boxes = await detectIllustrationRegions(apiKey, primaryBytes, mimeType, {
          ...ctx,
          feature: "detect_illustrations",
          moduleType: "DESIGN",
        });
        if (boxes.length > 0) {
          const crops = await cropIllustrations(primaryBytes, boxes);
          const results = await Promise.all(
            crops.map((b, idx) => uploadIllustration(userId, jobId, idx, b)),
          );
          illustrationUrls = results.map((r) => r.url);
          thumbnailUrls = results.map((r) => r.thumbUrl);
        }
      } catch (err) {
        // Les illustrations sont best-effort — on log et on continue.
        logError({
          message: "Détection illustrations échouée (continue sans)",
          errorDescription: err instanceof Error ? err.message : String(err),
          moduleType: "DESIGN",
          ...ctx,
        });
      }

      await jobRef.update({ current_step: "save", updated_at: Timestamp.now() });
      const fileName = (job.file_name as string | undefined) ?? null;
      // On passe pageType explicitement pour éviter de le ré-analyser depuis le texte.
      const pageTypeSaved = classification.pageType;
      for (const cooklang of cooklangs) {
        const id = await saveRecipeDraft({
          cooklang,
          pageType: pageTypeSaved,
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
        });
        createdIds.push(id);

        // Le brouillon est publié dès sa création, pas à la fin du job.
        //
        // Ce qui suit — normalisation des référentiels — dure jusqu'à sept
        // minutes, job toujours en « traitement ». Pendant tout ce temps, la
        // file de travail affichait deux lignes pour un seul import : le
        // traitement et le brouillon qu'il venait de produire. Publier
        // l'identifiant ici permet à l'écran de n'en montrer qu'une, la seule
        // sur laquelle l'utilisateur puisse agir.
        await jobRef.update({ created_recipe_ids: createdIds, updated_at: Timestamp.now() });

        // Passe IA de normalisation référentiels (best-effort, ne bloque pas la pipeline).
        // Garantit que le brouillon a déjà les unités/ingrédients canoniques + complétion
        // des quantités manquantes dès sa création.
        if (pageTypeSaved === "recipe") {
          try {
            // Étape à part entière, et nommée. Elle se déroulait sous le libellé
            // « Enregistrement de la recette… » alors que le brouillon était
            // déjà créé : l'utilisateur voyait un traitement en cours pour une
            // recette qu'il pouvait ouvrir, sans savoir ce qui tournait encore.
            await jobRef.update({ current_step: "normalize", updated_at: Timestamp.now() });

            // Échéance. Cette passe enchaîne plusieurs appels Gemini dont le
            // nombre dépend de la recette ; sans borne, une recette riche en
            // ingrédients neufs pouvait épuiser les 540 s de la function, et le
            // job restait éternellement « en traitement » alors que son
            // brouillon existait. Ce qui n'est pas fait ici sera repris par
            // `onRecipeWritten`, qui enrichit et recalcule de son côté.
            const normalizationDeadlineMs = start + 420_000;
            const normalized = await normalizeRecipeReferentialsCore({
              aiEnabled: true,
              recipeId: id,
              cooklang,
              userId,
              deadlineMs: normalizationDeadlineMs,
            });
            const hasChanges =
              normalized.stats.aiCompletedIngredients > 0 ||
              normalized.stats.renamedIngredients > 0 ||
              normalized.stats.renamedUnits > 0;
            if (hasChanges) {
              await getFirestore()
                .collection(COLL_RECIPES)
                .doc(id)
                .update({
                  ingredients: normalized.resolvedIngredients,
                  ...(normalized.rewrittenCooklang
                    ? { raw_cooklang: normalized.rewrittenCooklang }
                    : {}),
                  updated_at: FieldValue.serverTimestamp(),
                });
              logInfo({
                message: `Normalisation draft: ${normalized.stats.aiCompletedIngredients} qty IA, ${normalized.stats.renamedIngredients} noms, ${normalized.stats.renamedUnits} unités`,
                moduleType: "IMPORT",
                ...ctx,
                extra: { recipeId: id },
              });
            }
          } catch (normErr) {
            logError({
              message: "Normalisation référentiels post-création échouée (best-effort)",
              errorDescription: normErr instanceof Error ? normErr.message : String(normErr),
              moduleType: "IMPORT",
              ...ctx,
              extra: { recipeId: id },
            });
          }
        }
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
        extra: { attempt, isQuota },
      });

      // Si c'est la dernière tentative, on bascule en DLQ.
      if (attempt + 1 >= MAX_RETRY_ATTEMPTS) {
        await moveToDeadLetter({
          jobId,
          userId,
          correlationId,
          failureReason: isQuota ? "quota_exceeded" : "pipeline_error",
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

interface IllustrationUploadResult {
  url: string;
  thumbUrl: string;
}

async function uploadIllustration(
  userId: string,
  jobId: string,
  index: number,
  bytes: Buffer,
): Promise<IllustrationUploadResult> {
  const bucket = getStorage().bucket();
  const ts = Date.now();

  // ── Image originale ──────────────────────────────────────────────────────
  const path = `users/${userId}/illustrations/${jobId}_${index}_${ts}.jpg`;
  const file = bucket.file(path);
  const downloadToken = randomUUID();
  await file.save(bytes, {
    contentType: "image/jpeg",
    metadata: {
      cacheControl: "public, max-age=31536000",
      metadata: { firebaseStorageDownloadTokens: downloadToken },
    },
  });
  const url =
    `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/` +
    `${encodeURIComponent(path)}?alt=media&token=${downloadToken}`;

  // ── Thumbnail WebP 400px ─────────────────────────────────────────────────
  // Généré côté serveur pour l'affichage grille côté client (évite de télécharger
  // la pleine résolution pour chaque vignette).
  let thumbUrl = url; // fallback : URL originale si Sharp échoue
  try {
    const thumbBytes = await sharp(bytes)
      .resize(400, 400, { fit: "inside", withoutEnlargement: true })
      .webp({ quality: 80 })
      .toBuffer();

    const thumbPath = `users/${userId}/thumbnails/${jobId}_${index}_${ts}_thumb.webp`;
    const thumbFile = bucket.file(thumbPath);
    const thumbToken = randomUUID();
    await thumbFile.save(thumbBytes, {
      contentType: "image/webp",
      metadata: {
        cacheControl: "public, max-age=31536000",
        metadata: { firebaseStorageDownloadTokens: thumbToken },
      },
    });
    thumbUrl =
      `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/` +
      `${encodeURIComponent(thumbPath)}?alt=media&token=${thumbToken}`;
  } catch (err) {
    // Thumbnail best-effort : on retombe sur l'URL originale, mais l'échec doit
    // rester visible (règle projet : aucun catch silencieux).
    await logError({
      message: "[uploadIllustration] Génération du thumbnail échouée",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "IMAGE_DECODE",
      jobId,
      userId,
      extra: { index, fallback: "url originale" },
    });
  }

  return { url, thumbUrl };
}

async function saveRecipeDraft(args: {
  cooklang: string;
  /** Type de page déterminé par la classification — passé explicitement pour éviter une ré-analyse du texte. */
  pageType: CookLangPageType;
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
  const cooklangFull = cooklang; // on garde la version avec >> pour le client
  const titre = extractTitle(cooklang);
  const portions = extractPortions(cooklang);
  const pageNumber = extractPageNumber(cooklang);
  // pageType est passé directement depuis la classification — pas de re-parsing.
  logInfo({
    message: `saveRecipeDraft: pageType=${pageType} titre="${titre}"`,
    moduleType: "IMPORT",
    ...ctx,
  });
  // Stockés tels que la recette les dit : la résolution d'unité n'est plus
  // persistée, elle se recalcule là où elle sert.
  const ingredients = extractIngredientsStructured(cooklang);
  const ingredientsIndex = buildIngredientsIndex(ingredients);
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
  const recipeCooklangWithIllustrations = injectIllustrations(cooklangFull);

  // Auto-polish Markdown pour les pages non-recette — best-effort
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

  // Catégorisation automatique (cuisines + types de plat) via Gemini — best-effort.
  let aiCuisines: string[] = [];
  let aiDishTypes: string[] = tags.dishTypes; // valeurs extraites des métadonnées CookLang
  if (pageType === "recipe") {
    try {
      const tagResult = await suggestRecipeTags(apiKey, { titre, cooklang }, {
        ...ctx,
        feature: "suggest_tags",
        moduleType: "IMPORT",
      } as Parameters<typeof suggestRecipeTags>[2]);
      aiCuisines = tagResult.cuisines;
      if (tagResult.dishTypes.length > 0) aiDishTypes = tagResult.dishTypes;
    } catch (tagErr) {
      // La suggestion de tags est best-effort — on continue sans.
      logError({
        message: `suggestRecipeTags failed (best-effort, recipe saved without cuisines)`,
        moduleType: "IMPORT",
        ...ctx,
        extra: { error: String(tagErr) },
      });
    }
  }

  // Champs alignés avec `Recipe.fromFirestore` (kass_dalle/lib/.../recipe.dart) :
  // - `raw_cooklang` / `draft_cooklang` (pas `cooklang` / `content`)
  // - `image_urls` (pas `illustration_urls`)
  // - `langue`, `source_file_*`, `ai_processed_at`
  const now = FieldValue.serverTimestamp();
  const doc = await getFirestore()
    .collection(COLL_RECIPES)
    .add({
      titre,
      langue: "fr",
      raw_cooklang: cooklangFull,
      draft_cooklang:
        pageType !== "recipe"
          ? bodyContent
          : illustrationUrls.length > 0
            ? recipeCooklangWithIllustrations
            : cleaned || cooklangFull,
      page_type: pageType,
      page_number: pageNumber,
      portions,
      ingredients_index: ingredientsIndex,
      ingredients,
      tags: {
        difficulty: tags.difficulty,
        prep_time: tags.prepTime,
        cook_time: tags.cookTime,
        cuisines: aiCuisines,
        dish_types: aiDishTypes,
      },
      book_id: bookId ?? null,
      book_titre: bookTitre ?? null,
      image_urls: illustrationUrls,
      thumbnail_urls: thumbnailUrls,
      source_file_url: sourceFileUrl ?? null,
      source_file_name: sourceFileName ?? null,
      additional_source_file_urls: additionalSourceFileUrls ?? [],
      review_status: "draft",
      created_by: userId,
      created_at: now,
      updated_at: now,
      ai_processed_at: now,
      pipeline_correlation_id: correlationId,
    });
  return doc.id;
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
