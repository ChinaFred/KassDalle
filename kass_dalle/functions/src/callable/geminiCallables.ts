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
import { GEMINI_API_KEY, REGION } from "../config";
import { requireAuth } from "./_auth";
import { extractRecipeFromText } from "../gemini/extractor";
import { polishCooklang, refineRecipe, generateRecipe, type RefineInput } from "../gemini/refiner";
import { searchRecipes, extractBookCover, type SearchRecipesInput } from "../gemini/search";
import { suggestMealPlan, type PlanningInput } from "../gemini/planning";
import { detectIllustrationRegions, detectMainCulinaryPhoto, cropIllustrations } from "../gemini/detector";
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
