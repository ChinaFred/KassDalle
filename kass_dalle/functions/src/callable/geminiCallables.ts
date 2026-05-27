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
import { getFirestore } from "firebase-admin/firestore";
import { COLL_RECIPES, GEMINI_API_KEY, REGION } from "../config";
import { requireAdmin, requireAuth } from "./_auth";
import { extractRecipeFromText } from "../gemini/extractor";
import { polishCooklang, polishMarkdown, refineRecipe, generateRecipe, type RefineInput } from "../gemini/refiner";
import { suggestRecipeTags, type SuggestTagsInput } from "../gemini/tagger";
import { searchRecipes, extractBookCover, generateWebSearchQuery, type SearchRecipesInput } from "../gemini/search";
import { suggestMealPlan, generateRecipeConcept, type PlanningInput, type RecipeConceptInput } from "../gemini/planning";
import { detectIllustrationRegions, detectMainCulinaryPhoto, cropIllustrations } from "../gemini/detector";
import {
  downloadStorageBytes,
  enhanceCulinaryImage,
  uploadEnhancedIllustration,
} from "../gemini/enhancer";
import { scoreImageQuality } from "../utils/imageQuality";
import { GeminiError, GeminiQuotaExceededError } from "../gemini/client";

// ── Helpers ──────────────────────────────────────────────────────────────────

const callableOpts = {
  region: REGION,
  secrets: [GEMINI_API_KEY],
  memory: "512MiB" as const,
  timeoutSeconds: 300,
  cors: true,
};

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
    return data;
  } catch (e) { throw toHttpsError(e); }
});

export const generateRecipeFn = onCall(callableOpts, async (req) => {
  const ctx = requireAuth(req);
  const { query, preferenceInsight } = (req.data ?? {}) as {
    query?: string; preferenceInsight?: string | null;
  };
  if (!query) throw new HttpsError("invalid-argument", "query est requis.");
  try {
    const data = await generateRecipe(GEMINI_API_KEY.value(), query, preferenceInsight ?? null, {
      ...ctx, feature: "generate", moduleType: "DESIGN",
    });
    return data;
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
