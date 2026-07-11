/**
 * Cloud Functions HTTPS Callable — wrappers Gemini synchrones.
 *
 * Le client Flutter appelle ces fonctions via httpsCallable au lieu d'instancier
 * GeminiService localement. La clé API ne quitte jamais Secret Manager.
 *
 * Toutes les fonctions partagent :
 *  - region europe-west1
 *  - secret GEMINI_API_KEY
 *  - auth obligatoire (sauf usage explicite anonyme)
 *  - logs structurés Cloud Logging
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore, FieldValue } from "firebase-admin/firestore";
import { getStorage, getDownloadURL } from "firebase-admin/storage";
import { COLL_AI_USAGE, COLL_RECIPES, GEMINI_API_KEY, REGION } from "../config";
import { requireAdmin, requireAuth } from "./_auth";
import { extractRecipeFromText } from "../gemini/extractor";
import { polishCooklang, polishMarkdown, refineRecipe, generateRecipe, type RefineInput } from "../gemini/refiner";
import { suggestRecipeTags, type SuggestTagsInput } from "../gemini/tagger";
import { searchRecipes, extractBookCover, generateWebSearchQuery, type SearchRecipesInput } from "../gemini/search";
import { suggestMealPlan, generateRecipeConcept, type PlanningInput, type RecipeConceptInput } from "../gemini/planning";
import { consolidateShoppingList, type ShoppingIngredientInput } from "../gemini/shopping";
import { detectIllustrationRegions, detectMainCulinaryPhoto, cropIllustrations } from "../gemini/detector";
import {
  downloadStorageBytes,
  enhanceCulinaryImage,
  uploadEnhancedIllustration,
} from "../gemini/enhancer";
import {
  generateCulinaryImage,
  uploadGeneratedIllustration,
} from "../gemini/imageGenerator";
import { enrichIngredientsWithUnitResolution } from "../nutrition/ingredientUnitResolution";
import { scoreImageQuality } from "../utils/imageQuality";
import { scanUpload } from "../utils/uploadSecurity";
import { GeminiError, GeminiQuotaExceededError } from "../gemini/client";
import { logError, logInfo } from "../logging";

// ── Helpers ──────────────────────────────────────────────────────────────────

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const callableOpts = {
  region: REGION,
  secrets: [GEMINI_API_KEY],
  memory: "512MiB" as const,
  timeoutSeconds: 300,
  cors: ALLOWED_ORIGINS,
};

const SECURITY_SCAN_UNIT_COST_USD = Number(process.env.SECURITY_SCAN_UNIT_COST_USD ?? "0");

function toHttpsError(err: unknown): HttpsError {
  if (err instanceof HttpsError) return err;
  if (err instanceof GeminiQuotaExceededError) {
    return new HttpsError("resource-exhausted", err.message);
  }
  if (err instanceof GeminiError) {
    return new HttpsError("internal", err.message);
  }
  return new HttpsError("internal", err instanceof Error ? err.message : String(err));
}

function bytesFromBase64(b64: string): Buffer {
  return Buffer.from(b64, "base64");
}

function withResolvedIngredients(data: Record<string, unknown>): Record<string, unknown> {
  const ingredientsRaw = Array.isArray(data.ingredients) ? data.ingredients : null;
  if (!ingredientsRaw) return data;
  return {
    ...data,
    ingredients: enrichIngredientsWithUnitResolution(ingredientsRaw),
  };
}

async function logUploadScanUsage(args: {
  uid: string;
  correlationId: string;
  sizeBytes: number;
  mimeType: string;
  scanStatus: "clean" | "blocked";
  reason?: string;
}): Promise<void> {
  const { uid, correlationId, sizeBytes, mimeType, scanStatus, reason } = args;
  const estimatedCostUsd = Number.isFinite(SECURITY_SCAN_UNIT_COST_USD) && SECURITY_SCAN_UNIT_COST_USD > 0
    ? SECURITY_SCAN_UNIT_COST_USD
    : 0;

  await getFirestore().collection(COLL_AI_USAGE).add({
    uid,
    feature: "upload_security_scan",
    input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    image_output_count: 0,
    model: "security-scan-v1",
    timestamp: FieldValue.serverTimestamp(),
    estimated_cost_usd: estimatedCostUsd,
    billed_units: 1,
    correlation_id: correlationId,
    scan_status: scanStatus,
    file_size_bytes: sizeBytes,
    mime_type: mimeType,
    blocked_reason: reason ?? null,
  });
}

// ── Functions ────────────────────────────────────────────────────────────────

export const extractRecipeFromTextFn = onCall(callableOpts, async (req) => {
  const ctx = requireAuth(req);
  const { text } = (req.data ?? {}) as { text?: string };
  if (!text || typeof text !== "string") {
    throw new HttpsError("invalid-argument", "Le champ 'text' est requis.");
  }
  try {
    const cooklang = await extractRecipeFromText(GEMINI_API_KEY.value(), text, {
      ...ctx, feature: "text_extraction", moduleType: "IMPORT",
    });
    return { cooklang };
  } catch (e) { throw toHttpsError(e); }
});

export const polishCooklangFn = onCall(callableOpts, async (req) => {
  const ctx = requireAuth(req);
  const { cooklang } = (req.data ?? {}) as { cooklang?: string };
  if (!cooklang) throw new HttpsError("invalid-argument", "Le champ 'cooklang' est requis.");
  try {
    const polished = await polishCooklang(GEMINI_API_KEY.value(), cooklang, {
      ...ctx, feature: "polish_cooklang", moduleType: "DESIGN",
    });
    return { cooklang: polished };
  } catch (e) { throw toHttpsError(e); }
});

export const polishMarkdownFn = onCall(callableOpts, async (req) => {
  const ctx = requireAuth(req);
  const { markdown, instruction } = (req.data ?? {}) as { markdown?: string; instruction?: string };
  if (!markdown) throw new HttpsError("invalid-argument", "Le champ 'markdown' est requis.");
  try {
    const polished = await polishMarkdown(GEMINI_API_KEY.value(), markdown, instruction ?? null, {
      ...ctx, feature: "polish_markdown", moduleType: "DESIGN",
    });
    return { markdown: polished };
  } catch (e) { throw toHttpsError(e); }
});

export const refineRecipeFn = onCall(callableOpts, async (req) => {
  const ctx = requireAuth(req);
  const input = req.data as RefineInput | undefined;
  if (!input?.instruction || !input?.currentCooklang) {
    throw new HttpsError("invalid-argument", "instruction et currentCooklang sont requis.");
  }
  try {
    const data = await refineRecipe(GEMINI_API_KEY.value(), input, {
      ...ctx, feature: "refine", moduleType: "DESIGN",
    });
    return withResolvedIngredients(data);
  } catch (e) { throw toHttpsError(e); }
});

export const generateRecipeFn = onCall(callableOpts, async (req) => {
  const ctx = requireAuth(req);
  const {
    query,
    preferenceInsight,
    libraryContext,
    variantLabel,
    variantInstruction,
    siblingVariantLabels,
    avoidTitles,
  } = (req.data ?? {}) as {
    query?: string;
    preferenceInsight?: string | null;
    libraryContext?: Array<Record<string, string>>;
    variantLabel?: string;
    variantInstruction?: string;
    siblingVariantLabels?: string[];
    avoidTitles?: string[];
  };
  if (!query) throw new HttpsError("invalid-argument", "query est requis.");
  try {
    const data = await generateRecipe(
      GEMINI_API_KEY.value(),
      {
        query,
        preferenceInsight: preferenceInsight ?? null,
        libraryContext: libraryContext ?? [],
        variantLabel: variantLabel ?? null,
        variantInstruction: variantInstruction ?? null,
        siblingVariantLabels: siblingVariantLabels ?? [],
        avoidTitles: avoidTitles ?? [],
      },
      { ...ctx, feature: "generate", moduleType: "DESIGN" },
    );
    return withResolvedIngredients(data);
  } catch (e) { throw toHttpsError(e); }
});

export const searchRecipesFn = onCall(callableOpts, async (req) => {
  const ctx = requireAuth(req);
  const input = req.data as SearchRecipesInput | undefined;
  if (!input?.query) throw new HttpsError("invalid-argument", "query est requis.");
  try {
    const data = await searchRecipes(GEMINI_API_KEY.value(), input, {
      ...ctx, feature: "search", moduleType: "SEARCH",
    });
    return data;
  } catch (e) { throw toHttpsError(e); }
});

export const extractBookCoverFn = onCall(callableOpts, async (req) => {
  const ctx = requireAuth(req);
  const { bytesBase64, mimeType } = (req.data ?? {}) as {
    bytesBase64?: string; mimeType?: string;
  };
  if (!bytesBase64 || !mimeType) {
    throw new HttpsError("invalid-argument", "bytesBase64 et mimeType requis.");
  }
  try {
    const data = await extractBookCover(GEMINI_API_KEY.value(), bytesFromBase64(bytesBase64), mimeType, {
      ...ctx, feature: "book_cover", moduleType: "IMPORT",
    });
    return data;
  } catch (e) { throw toHttpsError(e); }
});

export const suggestMealPlanFn = onCall(callableOpts, async (req) => {
  const ctx = requireAuth(req);
  const input = req.data as PlanningInput | undefined;
  if (!input?.slotDates) throw new HttpsError("invalid-argument", "slotDates est requis.");
  try {
    const data = await suggestMealPlan(GEMINI_API_KEY.value(), input, {
      ...ctx, feature: "planning", moduleType: "DESIGN",
    });
    return { suggestions: data };
  } catch (e) { throw toHttpsError(e); }
});

export const consolidateShoppingListFn = onCall(callableOpts, async (req) => {
  const ctx = requireAuth(req);
  const { ingredients } = (req.data ?? {}) as { ingredients?: ShoppingIngredientInput[] };
  if (!Array.isArray(ingredients) || ingredients.length === 0) {
    throw new HttpsError("invalid-argument", "ingredients est requis.");
  }
  try {
    const items = await consolidateShoppingList(GEMINI_API_KEY.value(), ingredients, {
      ...ctx,
      feature: "shopping_list",
      moduleType: "DESIGN",
    });
    return { items };
  } catch (e) { throw toHttpsError(e); }
});

/**
 * Génère une recette de toutes pièces pour un slot (conception IA).
 * Utilisé quand aucune recette existante ne satisfait les contraintes.
 */
export const generateRecipeConceptFn = onCall(callableOpts, async (req) => {
  const ctx = requireAuth(req);
  const input = req.data as RecipeConceptInput | undefined;
  if (!input?.slotDate) throw new HttpsError("invalid-argument", "slotDate est requis.");
  try {
    const data = await generateRecipeConcept(GEMINI_API_KEY.value(), input, {
      ...ctx, feature: "planning_concept", moduleType: "DESIGN",
    });
    return data;
  } catch (e) { throw toHttpsError(e); }
});

/**
 * Génère une requête Google optimisée pour la recherche web.
 */
export const suggestRecipeTagsFn = onCall(callableOpts, async (req) => {
  const ctx = requireAuth(req);
  const { titre, cooklang } = (req.data ?? {}) as Partial<SuggestTagsInput>;
  if (!titre) throw new HttpsError("invalid-argument", "titre est requis.");
  try {
    const data = await suggestRecipeTags(
      GEMINI_API_KEY.value(),
      { titre, cooklang: cooklang ?? "" },
      { ...ctx, feature: "suggest_tags", moduleType: "DESIGN" },
    );
    return data;
  } catch (e) { throw toHttpsError(e); }
});

export const generateWebSearchQueryFn = onCall(callableOpts, async (req) => {
  const ctx = requireAuth(req);
  const { userQuery } = (req.data ?? {}) as { userQuery?: string };
  if (!userQuery) throw new HttpsError("invalid-argument", "userQuery est requis.");
  try {
    const query = await generateWebSearchQuery(GEMINI_API_KEY.value(), userQuery, {
      ...ctx, feature: "web_search_query", moduleType: "SEARCH",
    });
    return { query };
  } catch (e) { throw toHttpsError(e); }
});

/**
 * Vérifie un upload en quarantaine puis le promeut vers scans/ si propre.
 *
 * Entrée: { storagePath: "quarantine/<uid>/<filename>" }
 * Sortie: { status: "clean", downloadUrl, storagePath, mimeType, sizeBytes }
 */
export const scanAndPromoteUploadFn = onCall(callableOpts, async (req) => {
  const ctx = requireAuth(req);
  const { storagePath } = (req.data ?? {}) as { storagePath?: string };

  if (!storagePath || typeof storagePath !== "string") {
    throw new HttpsError("invalid-argument", "storagePath est requis.");
  }

  const expectedPrefix = `quarantine/${ctx.userId}/`;
  if (!storagePath.startsWith(expectedPrefix)) {
    throw new HttpsError("permission-denied", "Chemin de quarantaine invalide.");
  }

  const bucket = getStorage().bucket();
  const sourceFile = bucket.file(storagePath);

  try {
    const [exists] = await sourceFile.exists();
    if (!exists) {
      throw new HttpsError("not-found", "Fichier en quarantaine introuvable.");
    }

    const [meta] = await sourceFile.getMetadata();
    const fileName = storagePath.split("/").pop() ?? "upload";
    const [bytes] = await sourceFile.download();
    const scan = scanUpload({
      fileName,
      mimeType: meta.contentType,
      bytes,
    });
    const detectedMime = scan.normalizedMimeType ?? meta.contentType ?? "application/octet-stream";
    await logUploadScanUsage({
      uid: ctx.userId,
      correlationId: ctx.correlationId,
      sizeBytes: bytes.length,
      mimeType: detectedMime,
      scanStatus: scan.clean ? "clean" : "blocked",
      reason: scan.reason,
    });

    if (!scan.clean) {
      await sourceFile.setMetadata({
        metadata: {
          quarantine_status: "infected",
          quarantine_reason: scan.reason ?? "scan_failed",
        },
      });
      await logError({
        message: "Upload bloque par le scan de securite",
        moduleType: "IMPORT",
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        extra: { storagePath, reason: scan.reason },
      });
      throw new HttpsError(
        "failed-precondition",
        scan.reason ?? "Le fichier a ete bloque par le scan de securite.",
      );
    }

    const promotedPath = storagePath.replace("quarantine/", "scans/");
    const [promotedFile] = await sourceFile.copy(bucket.file(promotedPath));
    await promotedFile.setMetadata({
      contentType: detectedMime,
      metadata: {
        ...(meta.metadata ?? {}),
        quarantine_status: "clean",
        quarantine_scanned_at: new Date().toISOString(),
      },
    });

    const downloadUrl = await getDownloadURL(promotedFile);
    await sourceFile.delete().catch(() => undefined);

    await logInfo({
      message: "Upload scanne puis promu hors quarantaine",
      moduleType: "IMPORT",
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      extra: {
        quarantinePath: storagePath,
        promotedPath,
        mimeType: detectedMime,
        sizeBytes: bytes.length,
      },
    });

    return {
      status: "clean",
      downloadUrl,
      storagePath: promotedPath,
      mimeType: detectedMime,
      sizeBytes: bytes.length,
    };
  } catch (e) {
    throw toHttpsError(e);
  }
});

export const detectMainCulinaryPhotoFn = onCall(callableOpts, async (req) => {
  const ctx = requireAuth(req);
  const { bytesBase64, mimeType } = (req.data ?? {}) as {
    bytesBase64?: string; mimeType?: string;
  };
  if (!bytesBase64 || !mimeType) {
    throw new HttpsError("invalid-argument", "bytesBase64 et mimeType requis.");
  }
  try {
    const box = await detectMainCulinaryPhoto(GEMINI_API_KEY.value(), bytesFromBase64(bytesBase64), mimeType, {
      ...ctx, feature: "detect_main_photo", moduleType: "DESIGN",
    });
    return { box };
  } catch (e) { throw toHttpsError(e); }
});

/**
 * Détecte les illustrations et retourne les bytes croppés (base64) prêts à
 * être uploadés. Évite que le client refasse le crop côté Dart.
 */
export const detectAndCropIllustrationsFn = onCall(
  { ...callableOpts, memory: "1GiB" as const },
  async (req) => {
    const ctx = requireAuth(req);
    const { bytesBase64, mimeType } = (req.data ?? {}) as {
      bytesBase64?: string; mimeType?: string;
    };
    if (!bytesBase64 || !mimeType) {
      throw new HttpsError("invalid-argument", "bytesBase64 et mimeType requis.");
    }
    try {
      const bytes = bytesFromBase64(bytesBase64);
      const boxes = await detectIllustrationRegions(GEMINI_API_KEY.value(), bytes, mimeType, {
        ...ctx, feature: "detect_illustrations", moduleType: "DESIGN",
      });
      const crops = await cropIllustrations(bytes, boxes);
      return {
        boxes,
        cropsBase64: crops.map((b) => b.toString("base64")),
      };
    } catch (e) { throw toHttpsError(e); }
  },
);

/**
 * Améliore une illustration existante via Gemini Image (redressement perspective
 * + équilibrage couleurs/contraste). Réservé aux administrateurs.
 *
 * - Télécharge l'image depuis Storage à partir de l'URL fournie.
 * - Appelle gemini-2.5-flash-image avec un prompt unique.
 * - Upload le résultat sous `illustrations/{uid}/{ts}_enhanced.jpg`.
 * - Remplace l'URL dans `recipes/{recipeId}.image_urls`.
 * - Retourne `{ enhancedUrl }`.
 */
export const enhanceIllustrationFn = onCall(
  { ...callableOpts, memory: "1GiB" as const },
  async (req) => {
    const ctx = await requireAdmin(req);
    const { recipeId, illustrationUrl } = (req.data ?? {}) as {
      recipeId?: string; illustrationUrl?: string;
    };
    if (!recipeId || !illustrationUrl) {
      throw new HttpsError(
        "invalid-argument",
        "recipeId et illustrationUrl sont requis.",
      );
    }
    try {
      const originalBytes = await downloadStorageBytes(illustrationUrl);

      // ── Gate qualité : Sharp seul si l'image est déjà correcte ────────────
      // Évite un appel Gemini (~0.1$ par image) quand la photo ne nécessite que
      // des corrections basiques (normalisation + légère netteté).
      const quality = await scoreImageQuality(originalBytes);
      let enhancedBytes: Buffer;
      let outMime = "image/jpeg";

      if (!quality.needsGemini) {
        // Pipeline Sharp uniquement
        const { default: sharp } = await import("sharp");
        enhancedBytes = await sharp(originalBytes)
          .rotate()               // EXIF auto-rotation
          .normalise()            // étirement histogramme
          .sharpen({ sigma: 0.8 })
          .jpeg({ quality: 90 })
          .toBuffer();
      } else {
        // Pipeline Gemini complet
        const result = await enhanceCulinaryImage(
          GEMINI_API_KEY.value(),
          originalBytes,
          "image/jpeg",
          { ...ctx, feature: "enhance_illustration" },
        );
        enhancedBytes = result.bytes;
        outMime = result.mimeType;
      }

      const newUrl = await uploadEnhancedIllustration(ctx.userId, enhancedBytes, outMime);

      // Remplace l'URL dans la liste image_urls de la recette.
      const recipeRef = getFirestore().collection(COLL_RECIPES).doc(recipeId);
      const snap = await recipeRef.get();
      const urls = (snap.data()?.image_urls as string[] | undefined) ?? [];
      const idx = urls.indexOf(illustrationUrl);
      const newUrls = [...urls];
      if (idx >= 0) {
        newUrls[idx] = newUrl;
      } else {
        newUrls.push(newUrl);
      }
      await recipeRef.update({ image_urls: newUrls, updated_at: new Date() });

      return { enhancedUrl: newUrl };
    } catch (e) { throw toHttpsError(e); }
  },
);

/**
 * Génère une illustration photo-réaliste pour une recette ou un plat.
 *
 * Le client fournit un contexte éditorial court, le backend fabrique l'image,
 * l'upload dans Storage et retourne l'URL prête à être ajoutée à la recette.
 */
export const generateRecipeIllustrationFn = onCall(
  { ...callableOpts, memory: "1GiB" as const },
  async (req) => {
    const ctx = requireAuth(req);
    const { recipeTitle, recipeContext, userInstruction, style } = (req.data ?? {}) as {
      recipeTitle?: string;
      recipeContext?: string;
      userInstruction?: string;
      style?: string;
    };

    if (!recipeTitle || !recipeContext) {
      throw new HttpsError(
        "invalid-argument",
        "recipeTitle et recipeContext sont requis.",
      );
    }

    try {
      const generated = await generateCulinaryImage(
        GEMINI_API_KEY.value(),
        {
          recipeTitle,
          recipeContext,
          userInstruction: userInstruction ?? null,
          style: style ?? null,
        },
        { ...ctx, feature: "generate_recipe_illustration" },
      );

      const out = await uploadGeneratedIllustration(
        ctx.userId,
        generated.bytes,
        generated.mimeType,
      );
      return { generatedUrl: out };
    } catch (e) {
      throw toHttpsError(e);
    }
  },
);
