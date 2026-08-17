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
import { getStorage, getDownloadURL } from "firebase-admin/storage";
import {
  ANTHROPIC_API_KEY,
  COLL_RECIPES,
  GEMINI_API_KEY,
  MAX_CALLABLE_INSTANCES,
  REGION,
} from "../config";
import { requireAdmin, requireAuth, requireEditor } from "./_auth";
import { extractRecipeFromText } from "../gemini/extractor";
import {
  polishCooklang,
  polishMarkdown,
  refineRecipe,
  generateRecipe,
  type RefineInput,
} from "../gemini/refiner";
import { suggestRecipeTags, type SuggestTagsInput } from "../gemini/tagger";
import {
  searchRecipes,
  extractBookCover,
  generateWebSearchQuery,
  type SearchRecipesInput,
} from "../gemini/search";
import {
  suggestMealPlan,
  generateRecipeConcept,
  type PlanningInput,
  type RecipeConceptInput,
} from "../gemini/planning";
import { consolidateShoppingList, type ShoppingIngredientInput } from "../gemini/shopping";
import {
  detectIllustrationRegions,
  detectMainCulinaryPhoto,
  cropIllustrations,
} from "../gemini/detector";
import {
  downloadStorageBytes,
  enhanceCulinaryImage,
  uploadEnhancedIllustration,
} from "../gemini/enhancer";
import {
  generateCulinaryImage,
  generatePlatingStepImage,
  uploadGeneratedIllustration,
} from "../gemini/imageGenerator";
import { PLATING_PROMPT_VERSION, suggestPlating } from "../gemini/plating";
import { STORAGE_PROMPT_VERSION, suggestStorageAdvice } from "../gemini/storageAdvice";
import { recordUsage } from "../ai/usage";
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
  // Les DEUX clés, même si ce fichier n'appelle jamais Claude directement.
  // Un secret non déclaré n'est pas monté dans l'environnement : sans cette
  // ligne, `anthropicApiKey()` rendait null ici, et le routeur repliait chaque
  // poste routé vers Claude sur Gemini — silencieusement, puisqu'une clé
  // absente est l'état normal avant activation. La politique était lue,
  // appliquée, et annulée à l'exécution.
  secrets: [GEMINI_API_KEY, ANTHROPIC_API_KEY],
  memory: "512MiB" as const,
  timeoutSeconds: 300,
  cors: ALLOWED_ORIGINS,
  // Sans plafond, une boucle ouvre autant d'instances que le projet l'autorise
  // — cent par défaut, chacune servant quatre-vingts requêtes, chacune partant
  // chez Gemini ou Anthropic. Voir MAX_CALLABLE_INSTANCES.
  maxInstances: MAX_CALLABLE_INSTANCES,
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

async function logUploadScanUsage(args: {
  uid: string;
  correlationId: string;
  sizeBytes: number;
  mimeType: string;
  scanStatus: "clean" | "blocked";
  reason?: string;
}): Promise<void> {
  const { uid, correlationId, sizeBytes, mimeType, scanStatus, reason } = args;
  const estimatedCostUsd =
    Number.isFinite(SECURITY_SCAN_UNIT_COST_USD) && SECURITY_SCAN_UNIT_COST_USD > 0
      ? SECURITY_SCAN_UNIT_COST_USD
      : 0;

  // `provider: "internal"` : ce poste n'est pas de l'inférence. Écrit sans
  // fournisseur, il était déduit « gemini » à la lecture — un antivirus
  // apparaissait dans le coût de l'IA Google, et faussait la réconciliation
  // d'autant. Son prix ne se déduit d'aucune grille de jetons : il est imposé.
  const recorded = await recordUsage({
    feature: "upload_security_scan",
    provider: "internal",
    model: "security-scan-v1",
    userId: uid,
    correlationId,
    costUsdOverride: estimatedCostUsd,
    entityType: "upload",
  });

  // Le détail du scan n'a pas sa place dans l'agrégat de consommation, mais il
  // reste utile pour comprendre un refus : il part dans les logs.
  await logInfo({
    message: `Scan de sécurité ${scanStatus === "clean" ? "accepté" : "bloqué"}`,
    correlationId,
    userId: uid,
    feature: "upload_security_scan",
    extra: {
      scanStatus,
      sizeBytes,
      mimeType,
      blockedReason: reason ?? null,
      period: recorded.period,
    },
  });
}

// ── Functions ────────────────────────────────────────────────────────────────

export const extractRecipeFromTextFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAuth(req, "text_extraction");
  const { text } = (req.data ?? {}) as { text?: string };
  if (!text || typeof text !== "string") {
    throw new HttpsError("invalid-argument", "Le champ 'text' est requis.");
  }
  try {
    const cooklang = await extractRecipeFromText(GEMINI_API_KEY.value(), text, {
      ...ctx,
      feature: "text_extraction",
      moduleType: "IMPORT",
    });
    return { cooklang };
  } catch (e) {
    throw toHttpsError(e);
  }
});

export const polishCooklangFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAuth(req, "polish_cooklang");
  const { cooklang } = (req.data ?? {}) as { cooklang?: string };
  if (!cooklang) throw new HttpsError("invalid-argument", "Le champ 'cooklang' est requis.");
  try {
    const polished = await polishCooklang(GEMINI_API_KEY.value(), cooklang, {
      ...ctx,
      feature: "polish_cooklang",
      moduleType: "DESIGN",
    });
    return { cooklang: polished };
  } catch (e) {
    throw toHttpsError(e);
  }
});

export const polishMarkdownFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAuth(req, "polish_markdown");
  const { markdown, instruction } = (req.data ?? {}) as { markdown?: string; instruction?: string };
  if (!markdown) throw new HttpsError("invalid-argument", "Le champ 'markdown' est requis.");
  try {
    const polished = await polishMarkdown(GEMINI_API_KEY.value(), markdown, instruction ?? null, {
      ...ctx,
      feature: "polish_markdown",
      moduleType: "DESIGN",
    });
    return { markdown: polished };
  } catch (e) {
    throw toHttpsError(e);
  }
});

export const refineRecipeFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAuth(req, "refine");
  const input = req.data as RefineInput | undefined;
  if (!input?.instruction || !input?.currentCooklang) {
    throw new HttpsError("invalid-argument", "instruction et currentCooklang sont requis.");
  }
  try {
    const data = await refineRecipe(GEMINI_API_KEY.value(), input, {
      ...ctx,
      feature: "refine",
      moduleType: "DESIGN",
    });
    return data;
  } catch (e) {
    throw toHttpsError(e);
  }
});

export const generateRecipeFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAuth(req, "generate");
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
    return data;
  } catch (e) {
    throw toHttpsError(e);
  }
});

export const searchRecipesFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAuth(req, "search");
  const input = req.data as SearchRecipesInput | undefined;
  if (!input?.query) throw new HttpsError("invalid-argument", "query est requis.");
  try {
    const data = await searchRecipes(GEMINI_API_KEY.value(), input, {
      ...ctx,
      feature: "search",
      moduleType: "SEARCH",
    });
    return data;
  } catch (e) {
    throw toHttpsError(e);
  }
});

export const extractBookCoverFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAuth(req, "book_cover");
  const { bytesBase64, mimeType } = (req.data ?? {}) as {
    bytesBase64?: string;
    mimeType?: string;
  };
  if (!bytesBase64 || !mimeType) {
    throw new HttpsError("invalid-argument", "bytesBase64 et mimeType requis.");
  }
  try {
    const data = await extractBookCover(
      GEMINI_API_KEY.value(),
      bytesFromBase64(bytesBase64),
      mimeType,
      {
        ...ctx,
        feature: "book_cover",
        moduleType: "IMPORT",
      },
    );
    return data;
  } catch (e) {
    throw toHttpsError(e);
  }
});

export const suggestMealPlanFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAuth(req, "planning");
  const input = req.data as PlanningInput | undefined;
  if (!input?.slotDates) throw new HttpsError("invalid-argument", "slotDates est requis.");
  try {
    const data = await suggestMealPlan(GEMINI_API_KEY.value(), input, {
      ...ctx,
      feature: "planning",
      moduleType: "DESIGN",
    });
    return { suggestions: data };
  } catch (e) {
    throw toHttpsError(e);
  }
});

export const consolidateShoppingListFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAuth(req, "shopping_list");
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
  } catch (e) {
    throw toHttpsError(e);
  }
});

/**
 * Génère une recette de toutes pièces pour un slot (conception IA).
 * Utilisé quand aucune recette existante ne satisfait les contraintes.
 */
export const generateRecipeConceptFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAuth(req, "planning_concept");
  const input = req.data as RecipeConceptInput | undefined;
  if (!input?.slotDate) throw new HttpsError("invalid-argument", "slotDate est requis.");
  try {
    const data = await generateRecipeConcept(GEMINI_API_KEY.value(), input, {
      ...ctx,
      feature: "planning_concept",
      moduleType: "DESIGN",
    });
    return data;
  } catch (e) {
    throw toHttpsError(e);
  }
});

/**
 * Génère une requête Google optimisée pour la recherche web.
 */
export const suggestRecipeTagsFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAuth(req, "suggest_tags");
  const { titre, cooklang } = (req.data ?? {}) as Partial<SuggestTagsInput>;
  if (!titre) throw new HttpsError("invalid-argument", "titre est requis.");
  try {
    const data = await suggestRecipeTags(
      GEMINI_API_KEY.value(),
      { titre, cooklang: cooklang ?? "" },
      { ...ctx, feature: "suggest_tags", moduleType: "DESIGN" },
    );
    return data;
  } catch (e) {
    throw toHttpsError(e);
  }
});

export const generateWebSearchQueryFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAuth(req, "web_search_query");
  const { userQuery } = (req.data ?? {}) as { userQuery?: string };
  if (!userQuery) throw new HttpsError("invalid-argument", "userQuery est requis.");
  try {
    const query = await generateWebSearchQuery(GEMINI_API_KEY.value(), userQuery, {
      ...ctx,
      feature: "web_search_query",
      moduleType: "SEARCH",
    });
    return { query };
  } catch (e) {
    throw toHttpsError(e);
  }
});

/**
 * Vérifie un upload en quarantaine puis le promeut vers scans/ si propre.
 *
 * Entrée: { storagePath: "quarantine/<uid>/<filename>" }
 * Sortie: { status: "clean", downloadUrl, storagePath, mimeType, sizeBytes }
 */
export const scanAndPromoteUploadFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAuth(req, "upload_security_scan");
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
  const ctx = await requireAuth(req, "detect_main_photo");
  const { bytesBase64, mimeType } = (req.data ?? {}) as {
    bytesBase64?: string;
    mimeType?: string;
  };
  if (!bytesBase64 || !mimeType) {
    throw new HttpsError("invalid-argument", "bytesBase64 et mimeType requis.");
  }
  try {
    const box = await detectMainCulinaryPhoto(
      GEMINI_API_KEY.value(),
      bytesFromBase64(bytesBase64),
      mimeType,
      {
        ...ctx,
        feature: "detect_main_photo",
        moduleType: "DESIGN",
      },
    );
    return { box };
  } catch (e) {
    throw toHttpsError(e);
  }
});

/**
 * Détecte les illustrations et retourne les bytes croppés (base64) prêts à
 * être uploadés. Évite que le client refasse le crop côté Dart.
 */
export const detectAndCropIllustrationsFn = onCall(
  { ...callableOpts, memory: "1GiB" as const },
  async (req) => {
    const ctx = await requireAuth(req, "detect_illustrations");
    const { bytesBase64, mimeType } = (req.data ?? {}) as {
      bytesBase64?: string;
      mimeType?: string;
    };
    if (!bytesBase64 || !mimeType) {
      throw new HttpsError("invalid-argument", "bytesBase64 et mimeType requis.");
    }
    try {
      const bytes = bytesFromBase64(bytesBase64);
      const boxes = await detectIllustrationRegions(GEMINI_API_KEY.value(), bytes, mimeType, {
        ...ctx,
        feature: "detect_illustrations",
        moduleType: "DESIGN",
      });
      const crops = await cropIllustrations(bytes, boxes);
      return {
        boxes,
        cropsBase64: crops.map((b) => b.toString("base64")),
      };
    } catch (e) {
      throw toHttpsError(e);
    }
  },
);

/**
 * Améliore une illustration existante via Gemini Image (redressement perspective
 * + équilibrage couleurs/contraste). Réservé aux administrateurs.
 *
 * - Télécharge l'image depuis Storage à partir de l'URL fournie.
 * - Appelle le modèle image du projet (`GEMINI_IMAGE_MODEL`) avec un prompt unique.
 * - Upload le résultat sous `illustrations/{uid}/{ts}_enhanced.jpg`.
 * - Remplace l'URL dans `recipes/{recipeId}.image_urls`.
 * - Retourne `{ enhancedUrl }`.
 */
export const enhanceIllustrationFn = onCall(
  { ...callableOpts, memory: "1GiB" as const },
  async (req) => {
    const ctx = await requireAdmin(req, "enhance_illustration");
    const { recipeId, illustrationUrl } = (req.data ?? {}) as {
      recipeId?: string;
      illustrationUrl?: string;
    };
    if (!recipeId || !illustrationUrl) {
      throw new HttpsError("invalid-argument", "recipeId et illustrationUrl sont requis.");
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
          .rotate() // EXIF auto-rotation
          .normalise() // étirement histogramme
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
    } catch (e) {
      throw toHttpsError(e);
    }
  },
);

/**
 * Génère une illustration photo-réaliste pour une recette ou un plat.
 *
 * Le client fournit un contexte éditorial court, le backend fabrique l'image,
 * l'upload dans Storage et retourne l'URL prête à être ajoutée à la recette.
 *
 * Réservé aux éditeurs, comme les deux autres postes qui **produisent** une
 * image : le visuel de dressage l'exigeait déjà, l'amélioration de photo est
 * même réservée aux administrateurs. Celui-ci se contentait d'un compte
 * connecté, alors qu'il coûte 0,0336 $ par appel — un lecteur pouvait donc
 * dépenser en boucle ce que la même famille de postes lui refusait à côté.
 */
export const generateRecipeIllustrationFn = onCall(
  { ...callableOpts, memory: "1GiB" as const },
  async (req) => {
    const ctx = await requireEditor(req, "generate_recipe_illustration");
    const { recipeTitle, recipeContext, userInstruction, style } = (req.data ?? {}) as {
      recipeTitle?: string;
      recipeContext?: string;
      userInstruction?: string;
      style?: string;
    };

    if (!recipeTitle || !recipeContext) {
      throw new HttpsError("invalid-argument", "recipeTitle et recipeContext sont requis.");
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

// ── Dressage ─────────────────────────────────────────────────────────────────

/** Forme stockée d'une étape de dressage (snake_case, comme le reste du doc). */
interface StoredPlatingStep {
  titre: string;
  geste: string;
  elements: string[];
  image_prompt: string | null;
  image_url: string | null;
}

interface StoredPlatingAdvice {
  complexite: string;
  resume: string;
  contenant: string;
  etapes: StoredPlatingStep[];
  pieges: string[];
  derniere_minute: string[];
  user_instruction: string | null;
  provider: string;
  model: string;
  prompt_version: number;
  generated_by: string;
  generated_at: Date;
}

/**
 * Rend le conseil transmissible au client.
 *
 * Une callable sérialise sa réponse en JSON : un `Date` y passerait en objet
 * vide et le client afficherait un conseil sans date. La date part donc en ISO,
 * la version Firestore garde son Timestamp.
 */
function platingAdviceToJson(stored: StoredPlatingAdvice): Record<string, unknown> {
  return { ...stored, generated_at: stored.generated_at.toISOString() };
}

function readStoredAdvice(data: Record<string, unknown> | undefined): StoredPlatingAdvice | null {
  const raw = data?.plating_advice;
  if (!raw || typeof raw !== "object") return null;
  return raw as StoredPlatingAdvice;
}

/**
 * Conseil de dressage sur mesure pour une recette existante.
 *
 * Le conseil est écrit sur la recette : il est cher à produire, identique pour
 * tous les lecteurs, et l'onglet ne doit pas le repayer à chaque ouverture.
 * L'appel n'est donc déclenché que par un geste explicite côté client.
 */
export const suggestPlatingFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAuth(req, "plating_coach");
  const { recipeId, userInstruction } = (req.data ?? {}) as {
    recipeId?: string;
    userInstruction?: string;
  };
  if (!recipeId) {
    throw new HttpsError("invalid-argument", "recipeId est requis.");
  }

  try {
    const ref = getFirestore().collection(COLL_RECIPES).doc(recipeId);
    const snap = await ref.get();
    if (!snap.exists) {
      throw new HttpsError("not-found", "Recette introuvable.");
    }
    const data = snap.data() ?? {};
    const cooklang = (data.raw_cooklang as string | undefined) ?? "";
    if (!cooklang.trim()) {
      throw new HttpsError("failed-precondition", "Cette recette n'a pas de contenu à dresser.");
    }

    const tags = (data.tags as Record<string, unknown> | undefined) ?? {};
    const instruction = userInstruction?.trim() ? userInstruction.trim() : null;

    const result = await suggestPlating(
      {
        titre: (data.titre as string | undefined) ?? "",
        cooklang,
        cuisines: Array.isArray(tags.cuisines) ? (tags.cuisines as string[]) : [],
        dishTypes: Array.isArray(tags.dish_types) ? (tags.dish_types as string[]) : [],
        portions: (data.portions as number | undefined) ?? null,
        userInstruction: instruction,
      },
      { ...ctx, feature: "plating_coach", moduleType: "DESIGN" },
    );

    const stored: StoredPlatingAdvice = {
      complexite: result.advice.complexite,
      resume: result.advice.resume,
      contenant: result.advice.contenant,
      etapes: result.advice.etapes.map((step) => ({
        titre: step.titre,
        geste: step.geste,
        elements: step.elements,
        image_prompt: step.imagePrompt,
        image_url: null,
      })),
      pieges: result.advice.pieges,
      derniere_minute: result.advice.derniereMinute,
      user_instruction: instruction,
      provider: result.provider,
      model: result.model,
      prompt_version: PLATING_PROMPT_VERSION,
      generated_by: ctx.userId,
      generated_at: new Date(),
    };

    // `updated_at` n'est volontairement pas touché : produire un conseil ne
    // modifie pas la recette, et remonter la date ferait mentir tous les tris
    // « recettes récemment modifiées ».
    await ref.update({ plating_advice: stored });

    await logInfo("Plating advice generated", {
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      provider: result.provider,
      model: result.model,
      feature: "plating_coach",
      extra: {
        recipeId,
        complexite: stored.complexite,
        steps: stored.etapes.length,
        imagePrompts: stored.etapes.filter((s) => s.image_prompt).length,
      },
    });

    return { platingAdvice: platingAdviceToJson(stored) };
  } catch (e) {
    throw toHttpsError(e);
  }
});

// ── Conservation et réchauffage ──────────────────────────────────────────────

/**
 * Conseil de conservation et de réchauffage d'une recette.
 *
 * Écrit sur la recette : il décrit le plat, pas un repas. Les deux régimes —
 * réfrigérateur et congélateur — sont produits d'un coup, et c'est le planning
 * qui retient celui qui s'applique au délai réel. Le contraire aurait fait
 * payer un appel par créneau planifié pour la même recette.
 *
 * L'appel part soit d'un geste explicite au planning, soit de l'ouverture d'une
 * recette depuis un repas préparé un autre jour — la question de la
 * conservation est alors déjà posée. Dans les deux cas le client relit le
 * conseil stocké avant de demander : un plat n'est chiffré qu'une fois.
 */
export const suggestStorageAdviceFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAuth(req, "storage_advice");
  const { recipeId } = (req.data ?? {}) as { recipeId?: string };
  if (!recipeId) {
    throw new HttpsError("invalid-argument", "recipeId est requis.");
  }

  try {
    const ref = getFirestore().collection(COLL_RECIPES).doc(recipeId);
    const snap = await ref.get();
    if (!snap.exists) {
      throw new HttpsError("not-found", "Recette introuvable.");
    }
    const data = snap.data() ?? {};
    const cooklang = (data.raw_cooklang as string | undefined) ?? "";
    if (!cooklang.trim()) {
      throw new HttpsError("failed-precondition", "Cette recette n'a pas de contenu à conserver.");
    }
    const tags = (data.tags as Record<string, unknown> | undefined) ?? {};

    const result = await suggestStorageAdvice(
      {
        titre: (data.titre as string | undefined) ?? "",
        cooklang,
        dishTypes: Array.isArray(tags.dish_types) ? (tags.dish_types as string[]) : [],
        portions: (data.portions as number | undefined) ?? null,
      },
      { ...ctx, feature: "storage_advice", moduleType: "DESIGN" },
    );

    const a = result.advice;
    const stored = {
      resume: a.resume,
      refroidissement: a.refroidissement,
      refrigerateur: a.refrigerateur,
      congelateur: a.congelateur,
      congelation_deconseillee: a.congelationDeconseillee,
      rechauffage: a.rechauffage,
      a_ajouter_au_dernier_moment: a.aAjouterAuDernierMoment,
      signes_d_alerte: a.signesDAlerte,
      provider: result.provider,
      model: result.model,
      prompt_version: STORAGE_PROMPT_VERSION,
      generated_by: ctx.userId,
      generated_at: new Date(),
    };

    // `updated_at` reste intact : produire un conseil ne modifie pas la recette,
    // et remonter la date ferait mentir les tris « récemment modifiées ».
    await ref.update({ storage_advice: stored });

    await logInfo("Storage advice generated", {
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      provider: result.provider,
      model: result.model,
      feature: "storage_advice",
      extra: {
        recipeId,
        freezable: a.congelateur != null,
        alerts: a.signesDAlerte.length,
      },
    });

    return { storageAdvice: { ...stored, generated_at: stored.generated_at.toISOString() } };
  } catch (e) {
    throw toHttpsError(e);
  }
});

/**
 * Génère le visuel de montage d'une étape.
 *
 * Réservé aux éditeurs : chaque image coûte.
 *
 * Le visuel se construit **par-dessus le précédent** quand il en existe un.
 * Regénérer chaque étape de zéro donnait une assiette différente à chaque fois
 * — autre cadrage, autres formes — et la séquence ne racontait plus un montage
 * mais quatre plats sans rapport.
 *
 * Il n'y a pas de visuel « final » séparé : la dernière étape EST le résultat.
 * En demander un de plus ne pouvait produire qu'une chose, puisque le modèle
 * part de l'image précédente et qu'on lui demande d'y ajouter quelque chose —
 * il ajoutait un objet qui n'avait rien à faire là.
 */
export const generatePlatingImageFn = onCall(
  { ...callableOpts, memory: "1GiB" as const },
  async (req) => {
    const ctx = await requireEditor(req, "plating_image");
    const { recipeId, stepIndex } = (req.data ?? {}) as {
      recipeId?: string;
      stepIndex?: number;
    };
    if (!recipeId || typeof stepIndex !== "number") {
      throw new HttpsError("invalid-argument", "recipeId et stepIndex sont requis.");
    }

    try {
      const ref = getFirestore().collection(COLL_RECIPES).doc(recipeId);
      const snap = await ref.get();
      const advice = readStoredAdvice(snap.data());
      if (!advice) {
        throw new HttpsError(
          "failed-precondition",
          "Aucun conseil de dressage à illustrer pour cette recette.",
        );
      }

      const etapes = advice.etapes ?? [];
      const targetIndex = stepIndex;
      const step = etapes[targetIndex];
      if (!step) {
        throw new HttpsError("not-found", "Étape de dressage introuvable.");
      }

      // Reprend le dernier visuel produit avant cette étape. Une étape sautée
      // n'interrompt donc pas la continuité : on repart de ce qui existe.
      const baseUrl = etapes
        .slice(0, targetIndex)
        .map((s) => s.image_url)
        .filter((url): url is string => typeof url === "string" && url.length > 0)
        .pop();
      const baseImage = baseUrl
        ? { bytes: await downloadStorageBytes(baseUrl), mimeType: "image/jpeg" }
        : null;

      const generated = await generatePlatingStepImage(
        GEMINI_API_KEY.value(),
        {
          recipeTitle: (snap.data()?.titre as string | undefined) ?? "",
          stepTitle: step.titre,
          stepGeste: step.geste,
          // Le coach décrit chaque visuel ; si le champ manque (conseil produit
          // par une version antérieure du prompt), le geste en tient lieu.
          visualPrompt: step.image_prompt ?? step.geste,
          contenant: advice.contenant,
          previousSteps: etapes.slice(0, targetIndex).map((s) => s.geste),
          baseImage,
        },
        { ...ctx, feature: "plating_image" },
      );

      const url = await uploadGeneratedIllustration(
        ctx.userId,
        generated.bytes,
        generated.mimeType,
        "plating",
      );

      // Firestore ne sait pas modifier un élément de tableau en place : on
      // réécrit la liste complète, à partir de celle qu'on vient de lire.
      const updated = etapes.map((s, i) => (i === targetIndex ? { ...s, image_url: url } : s));
      await ref.update({ "plating_advice.etapes": updated });

      return { imageUrl: url };
    } catch (e) {
      throw toHttpsError(e);
    }
  },
);
