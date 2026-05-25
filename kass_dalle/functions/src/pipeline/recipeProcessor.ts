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
  GEMINI_API_KEY, REGION,
  QUEUE_RECIPE_PROCESSING,
  MAX_CONCURRENT_DISPATCHES, MAX_DISPATCHES_PER_SECOND, MAX_RETRY_ATTEMPTS,
  COLL_PROCESSING_JOBS, COLL_RECIPES, COLL_BOOKS, COLL_DEAD_LETTERS,
} from "../config";
import { logError, logInfo, newCorrelationId } from "../logging";
import { extractRecipes } from "../gemini/extractor";
import { extractBookCover } from "../gemini/search";
import { detectIllustrationRegions, cropIllustrations } from "../gemini/detector";
import { GeminiQuotaExceededError } from "../gemini/client";
import {
  extractTitle, extractPortions, extractPageNumber, extractPageType,
  extractIngredientsStructured, extractIngredientNames, extractTags, stripMeta,
} from "../cooklang/parser";import { suggestRecipeTags } from "../gemini/tagger";
interface ProcessorPayload {
  jobId: string;
  userId: string;
  correlationId?: string;
}

type PipelineStep =
  | "queued"
  | "import"
  | "image_decode"
  | "gemini_call"
  | "parse"
  | "design"
  | "save"
  | "done";

const STEP_ORDER: PipelineStep[] = [
  "queued", "import", "image_decode", "gemini_call", "parse", "design", "save", "done",
];

function stepIndex(step: PipelineStep): number {
  return STEP_ORDER.indexOf(step);
}

export const recipeProcessor = onTaskDispatched(
  {
    region: REGION,
    secrets: [GEMINI_API_KEY],
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
    const attempt = Number(req.retryCount ?? 0);

    // Si le job est déjà terminé, on ne retraite pas.
    if (job.status === "done") {
      logInfo({ message: "Job déjà terminé, retry ignoré", moduleType: "IMPORT", ...ctx });
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
      const additionalBytes = await Promise.all(additionalFileUrls.map((u) => downloadFromStorage(u)));

      logInfo({
        message: "Fichiers téléchargés",
        moduleType: "IMPORT",
        ...ctx,
        extra: { primaryBytes: primaryBytes.length, additional: additionalBytes.length },
      });

      // ── Branchement selon le type de job ──────────────────────────────────
      const jobType = (job.type as string | undefined) ?? "recipeScan";

      if (jobType === "bookCoverScan") {
        // ── Pipeline couverture de livre ────────────────────────────────────
        await jobRef.update({ current_step: "gemini_call", updated_at: Timestamp.now() });
        const extracted = await extractBookCover(
          apiKey, primaryBytes, mimeType,
          { ...ctx, feature: "book_cover", moduleType: "IMPORT" },
        );

        await jobRef.update({ current_step: "save", updated_at: Timestamp.now() });
        const now = Timestamp.now();
        const bookRef = await getFirestore().collection(COLL_BOOKS).add({
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
          review_status: "draft",
          created_by: userId,
          created_at: now,
          updated_at: now,
          shared_with: [],
          source_file_url: fileUrl,
          source_file_name: (job.file_name as string | undefined) ?? null,
          ai_processed_at: now,
          is_private: false,
        });

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

      // ── GEMINI_CALL : extraction recettes ─────────────────────────────────
      await jobRef.update({ current_step: "gemini_call", updated_at: Timestamp.now() });
      const cooklangs = await extractRecipes(
        apiKey, primaryBytes, mimeType,
        { ...ctx, feature: "scan", moduleType: "SEARCH" },
        additionalBytes.map((b) => ({ bytes: b, mimeType })),
      );

      if (cooklangs.length === 0) {
        throw new Error("Aucune recette extraite");
      }
      logInfo({
        message: `${cooklangs.length} recette(s) extraite(s)`,
        moduleType: "SEARCH",
        ...ctx,
        extra: { count: cooklangs.length },
      });

      // ── PARSE + DESIGN + SAVE ─────────────────────────────────────────────
      await jobRef.update({ current_step: "parse", updated_at: Timestamp.now() });

      const bookId = job.book_id as string | undefined;
      const bookTitre = job.book_titre as string | undefined;
      const createdIds: string[] = [];

      // Pour la détection d'illustrations on travaille sur la 1re image principale
      await jobRef.update({ current_step: "design", updated_at: Timestamp.now() });
      let illustrationUrls: string[] = [];
      try {
        const boxes = await detectIllustrationRegions(
          apiKey, primaryBytes, mimeType,
          { ...ctx, feature: "detect_illustrations", moduleType: "DESIGN" },
        );
        if (boxes.length > 0) {
          const crops = await cropIllustrations(primaryBytes, boxes);
          illustrationUrls = await Promise.all(
            crops.map((b, idx) => uploadIllustration(userId, jobId, idx, b)),
          );
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
      for (const cooklang of cooklangs) {
        const id = await saveRecipeDraft({
          cooklang,
          userId,
          bookId,
          bookTitre,
          illustrationUrls,
          correlationId,
          sourceFileUrl: fileUrl,
          sourceFileName: fileName,
          additionalSourceFileUrls: additionalFileUrls,
          apiKey,
          ctx,
        });
        createdIds.push(id);
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
          jobId, userId, correlationId,
          failureReason: isQuota ? "quota_exceeded" : "pipeline_error",
          lastError: message,
          retryCount: attempt + 1,
          filePath: (job.file_url as string | undefined) ?? "",
        });
        await jobRef.update({
          status: "error",
          error_message: message,
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

async function uploadIllustration(
  userId: string, jobId: string, index: number, bytes: Buffer,
): Promise<string> {
  const path = `users/${userId}/illustrations/${jobId}_${index}_${Date.now()}.jpg`;
  const bucket = getStorage().bucket();
  const file = bucket.file(path);
  // Token de téléchargement Firebase Storage : permet d'obtenir une URL HTTPS
  // utilisable directement par `Image.network` / `CachedNetworkImage` côté client.
  const downloadToken = randomUUID();
  await file.save(bytes, {
    contentType: "image/jpeg",
    metadata: {
      cacheControl: "public, max-age=31536000",
      metadata: { firebaseStorageDownloadTokens: downloadToken },
    },
  });
  return (
    `https://firebasestorage.googleapis.com/v0/b/${bucket.name}/o/` +
    `${encodeURIComponent(path)}?alt=media&token=${downloadToken}`
  );
}

async function saveRecipeDraft(args: {
  cooklang: string;
  userId: string;
  bookId?: string;
  bookTitre?: string;
  illustrationUrls: string[];
  correlationId: string;
  sourceFileUrl?: string | null;
  sourceFileName?: string | null;
  additionalSourceFileUrls?: string[];
  apiKey: string;
  ctx: Record<string, unknown>;
}): Promise<string> {
  const {
    cooklang, userId, bookId, bookTitre, illustrationUrls, correlationId,
    sourceFileUrl, sourceFileName, additionalSourceFileUrls, apiKey, ctx,
  } = args;

  const cleaned = stripMeta(cooklang);
  const cooklangFull = cooklang; // on garde la version avec >> pour le client
  const titre = extractTitle(cooklang);
  const portions = extractPortions(cooklang);
  const pageNumber = extractPageNumber(cooklang);
  const pageType = extractPageType(cooklang);
  const ingredients = extractIngredientsStructured(cooklang);
  const ingredientsIndex = extractIngredientNames(cooklang);
  const tags = extractTags(cooklang);

  // Pour les pages non-recette : remplace les marqueurs [schéma : ...] par des
  // liens image Markdown ![description](url) en suivant l'ordre des illustrations.
  let bodyContent = cleaned;
  if (pageType !== "recipe" && illustrationUrls.length > 0) {
    let imgIdx = 0;
    bodyContent = bodyContent.replace(/\[sch[eé]ma\s*:\s*([^\]]+)\]/gi, (_match, desc: string) => {
      if (imgIdx < illustrationUrls.length) {
        return `\n\n![${desc.trim()}](${illustrationUrls[imgIdx++]})\n`;
      }
      return `[schéma : ${desc}]`;
    });
  }

  // Catégorisation automatique (cuisines + types de plat) via Gemini — best-effort.
  let aiCuisines: string[] = [];
  let aiDishTypes: string[] = tags.dishTypes; // valeurs extraites des métadonnées CookLang
  if (pageType === "recipe") {
    try {
      const tagResult = await suggestRecipeTags(
        apiKey,
        { titre, cooklang },
        { ...ctx, feature: "suggest_tags", moduleType: "IMPORT" } as Parameters<typeof suggestRecipeTags>[2],
      );
      aiCuisines = tagResult.cuisines;
      if (tagResult.dishTypes.length > 0) aiDishTypes = tagResult.dishTypes;
    } catch (_err) {
      // La suggestion de tags est best-effort — on continue sans.
    }
  }

  // Champs alignés avec `Recipe.fromFirestore` (kass_dalle/lib/.../recipe.dart) :
  // - `raw_cooklang` / `draft_cooklang` (pas `cooklang` / `content`)
  // - `image_urls` (pas `illustration_urls`)
  // - `langue`, `source_file_*`, `ai_processed_at`
  const now = FieldValue.serverTimestamp();
  const doc = await getFirestore().collection(COLL_RECIPES).add({
    titre,
    langue: "fr",
    raw_cooklang: cooklangFull,
    draft_cooklang: pageType !== "recipe" ? bodyContent : (cleaned || cooklangFull),
    page_type: pageType,
    page_number: pageNumber,
    portions,
    ingredients_index: ingredientsIndex,
    ingredients: ingredients.map((i) => ({
      name: i.name, qty: i.qty, unit: i.unit, category: i.category ?? null,
    })),
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
