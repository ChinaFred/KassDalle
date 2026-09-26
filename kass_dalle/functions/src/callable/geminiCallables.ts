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
import {
  MEAL_IDEAS_MAX_PREVIOUS,
  MEAL_IDEAS_MAX_PROMPT_CHARS,
  suggestMealIdeas,
  type MealIdeasInput,
} from "../gemini/mealIdeas";
import { consolidateShoppingList, type ShoppingIngredientInput } from "../gemini/shopping";
import {
  detectIllustrationRegions,
  cropAndSelectIllustrations,
  uprightImage,
} from "../gemini/detector";
import { rejectionLabel } from "../gemini/illustrationQuality";
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
import { BudgetExceededError } from "../ai/budget";
import { scoreImageQuality } from "../utils/imageQuality";
import { scanUpload, scanUploadHead, streamContainsEicar } from "../utils/uploadSecurity";
import { BOOK_UPLOAD_FOLDER } from "../books/bookFile";
import { GeminiError, GeminiQuotaExceededError } from "../gemini/client";
import { logAiText, logError, logInfo, qualify } from "../logging";

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
  // Plafond de dépense atteint : ce n'est ni une panne ni un défaut de droits,
  // et le message est déjà écrit pour la personne qui le lira. `internal`
  // l'aurait présenté comme un incident, et l'aurait fait réessayer.
  if (err instanceof BudgetExceededError) {
    return new HttpsError("resource-exhausted", err.message);
  }
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
  /** Scan de l'utilisateur — posé par le client, avant même que le job existe. */
  scanId?: string;
  sizeBytes: number;
  mimeType: string;
  scanStatus: "clean" | "blocked";
  reason?: string;
}): Promise<void> {
  const { uid, correlationId, scanId, sizeBytes, mimeType, scanStatus, reason } = args;
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
    scanId,
    costUsdOverride: estimatedCostUsd,
    entityType: "upload",
  });

  // Le détail du scan n'a pas sa place dans l'agrégat de consommation, mais il
  // reste utile pour comprendre un refus : il part dans les logs.
  await logInfo({
    message: `Scan de sécurité ${scanStatus === "clean" ? "accepté" : "bloqué"}`,
    correlationId,
    scanId,
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

/**
 * Le texte collé déroule DEUX appels de modèle, pas un.
 *
 * Transcrire est borné à 2 min, baliser à 3 : bout à bout, ils atteignent tout
 * juste les 300 s des autres callables, et l'utilisateur aurait reçu une
 * coupure sèche au moment précis où le travail se termine. Les 540 s ne sont
 * pas facturées : une fonction se paie au temps réellement passé.
 */
const extractionCallableOpts = { ...callableOpts, timeoutSeconds: 540 };

export const extractRecipeFromTextFn = onCall(extractionCallableOpts, async (req) => {
  const ctx = await requireAuth(req, "text_extraction");
  const { text } = (req.data ?? {}) as { text?: string };
  if (!text || typeof text !== "string") {
    throw new HttpsError("invalid-argument", "Le champ 'text' est requis.");
  }
  try {
    const extraction = await extractRecipeFromText(text, {
      ...ctx,
      feature: "text_extraction",
      moduleType: "IMPORT",
    });
    // Aucune recette : le client affiche le message, il n'a rien à ranger.
    if (!extraction) return { cooklang: null };
    return {
      cooklang: extraction.cooklang,
      // La liste vient du modèle, pas d'une relecture des balises @ par le
      // client : c'est la seule forme qui porte la note explicative et la
      // ligne d'origine, que le balisage inline ne peut pas contenir.
      ingredients: extraction.ingredients.map((i) => ({
        name: i.nom,
        qty: i.qte,
        unit: i.unite,
        ...(i.note ? { note: i.note } : {}),
        ...(i.section ? { category: i.section } : {}),
        ...(i.brut ? { source: i.brut } : {}),
      })),
      cuisines: extraction.cuisines,
      dish_types: extraction.dishTypes,
      // Le rapport n'est transmis que s'il a quelque chose à dire — même règle
      // que sur un import : « ok » n'est pas une information à afficher.
      ...(extraction.fidelity.level !== "ok"
        ? {
            fidelity_level: extraction.fidelity.level,
            fidelity_findings: extraction.fidelity.findings.map((f) => ({
              message: f.message,
              items: f.items ?? [],
            })),
          }
        : {}),
      recettes_trouvees: extraction.recettesTrouvees,
    };
  } catch (e) {
    throw toHttpsError(e);
  }
});

export const polishCooklangFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAuth(req, "polish_cooklang");
  const { cooklang } = (req.data ?? {}) as { cooklang?: string };
  if (!cooklang) throw new HttpsError("invalid-argument", "Le champ 'cooklang' est requis.");
  try {
    // Avant / après, sous le même correlationId : le polissage est demandé à la
    // main, mais rien ne disait ce qu'il changeait. Une retouche qu'on ne peut
    // pas relire est une retouche qu'on ne peut pas mettre en cause.
    await logAiText({
      stage: "polish.avant",
      text: cooklang,
      feature: "polish_cooklang",
      moduleType: "DESIGN",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
    });
    const polished = await polishCooklang(GEMINI_API_KEY.value(), cooklang, {
      ...ctx,
      feature: "polish_cooklang",
      moduleType: "DESIGN",
    });
    await logAiText({
      stage: "polish.apres",
      text: polished ?? "",
      feature: "polish_cooklang",
      moduleType: "DESIGN",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      extra: { unchanged: polished === cooklang },
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
    await logAiText({
      stage: "refine.avant",
      text: input.currentCooklang,
      feature: "refine",
      moduleType: "DESIGN",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      extra: { instruction: input.instruction },
    });
    const data = await refineRecipe(GEMINI_API_KEY.value(), input, {
      ...ctx,
      feature: "refine",
      moduleType: "DESIGN",
    });
    await logAiText({
      stage: "refine.apres",
      text: (data as { cooklang?: string }).cooklang ?? "",
      feature: "refine",
      moduleType: "DESIGN",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      extra: { instruction: input.instruction },
    });
    return data;
  } catch (e) {
    throw toHttpsError(e);
  }
});

export const generateRecipeFn = onCall(callableOpts, async (req) => {
  // L'écran Explorer demande TROIS recettes d'un coup — une par variante — puis
  // en relance une quand deux se ressemblent trop. Ces appels sont
  // indépendants, donc chacun porte son propre fil : sans la variante dans le
  // nom, l'écran de journaux alignait trois « generate » identiques, et la
  // question « pourquoi trois ? » n'avait aucune réponse lisible.
  const askedVariant = (req.data as { variantLabel?: unknown } | undefined)?.variantLabel;
  const ctx = await requireAuth(req, qualify("generation_recette", askedVariant));
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
    // Les recettes écartées par la fenêtre de variété voyagent avec les
    // suggestions : l'écran dit combien de plats récents n'ont pas été proposés.
    return { suggestions: data.slots, excludedRecentIds: data.excludedRecentIds };
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
 * Trois idées de repas sur une consigne libre, pour le sélecteur du planning.
 *
 * Ne conçoit pas de recette et n'écrit rien : l'idée retenue devient un repas
 * libre. La consigne est bornée, et les titres déjà rendus voyagent avec la
 * relance pour que « trois autres » en rende trois autres.
 */
export const suggestMealIdeasFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAuth(req, "planning_meal_ideas");
  const raw = (req.data ?? {}) as Partial<MealIdeasInput>;
  const prompt = typeof raw.prompt === "string" ? raw.prompt.trim() : "";
  if (!prompt) throw new HttpsError("invalid-argument", "prompt est requis.");
  if (prompt.length > MEAL_IDEAS_MAX_PROMPT_CHARS) {
    throw new HttpsError(
      "invalid-argument",
      `prompt dépasse ${MEAL_IDEAS_MAX_PROMPT_CHARS} caractères.`,
    );
  }
  const previousTitles = (Array.isArray(raw.previousTitles) ? raw.previousTitles : [])
    .filter((t): t is string => typeof t === "string")
    .map((t) => t.trim().slice(0, 120))
    .filter((t) => t.length > 0)
    .slice(0, MEAL_IDEAS_MAX_PREVIOUS);
  const globalConstraints =
    typeof raw.globalConstraints === "string" ? raw.globalConstraints.trim().slice(0, 2_000) : "";
  try {
    const ideas = await suggestMealIdeas(
      { prompt, globalConstraints, previousTitles },
      { ...ctx, feature: "planning_meal_ideas", moduleType: "DESIGN" },
    );
    return { ideas };
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

/** Réponse de `scanAndPromoteUploadFn` pour un fichier propre. */
type PromotedUpload = {
  status: "clean";
  downloadUrl: string;
  storagePath: string;
  mimeType: string;
  sizeBytes: number;
};

/** Les premiers octets d'un objet Storage, sans télécharger le reste. */
async function readHead(
  file: { createReadStream(options: { start: number; end: number }): AsyncIterable<Buffer> },
  length: number,
): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of file.createReadStream({ start: 0, end: length - 1 })) {
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
}

/** Code HTTP porté par une erreur du SDK Storage (404, 412…), sinon null. */
function storageErrorCode(err: unknown): number | null {
  const code = (err as { code?: unknown } | null)?.code;
  return typeof code === "number" ? code : null;
}

/**
 * Relit une promotion déjà terminée par une autre requête, ou rend null.
 *
 * La requête qui promeut supprime la source EN DERNIER, après avoir posé
 * `quarantine_status: clean` et le jeton de téléchargement. Une copie promue
 * qui porte ce statut est donc complète, et `getDownloadURL` n'écrit rien :
 * il relit le jeton existant.
 */
async function replayPromotion(promotedPath: string): Promise<PromotedUpload | null> {
  const promotedFile = getStorage().bucket().file(promotedPath);
  const [exists] = await promotedFile.exists();
  if (!exists) return null;
  const [meta] = await promotedFile.getMetadata();
  if (meta.metadata?.quarantine_status !== "clean") return null;
  return {
    status: "clean",
    downloadUrl: await getDownloadURL(promotedFile),
    storagePath: promotedPath,
    mimeType: meta.contentType ?? "application/octet-stream",
    sizeBytes: Number(meta.size ?? 0),
  };
}

/**
 * Attend que la requête concurrente ait supprimé la source en quarantaine.
 *
 * Elle la supprime en dernier, quelques centaines de millisecondes après la
 * copie. Dix essais espacés de 500 ms couvrent ce délai ; au-delà, elle s'est
 * arrêtée en chemin et l'appelant termine la promotion à sa place.
 */
async function waitForSourceGone(storagePath: string): Promise<boolean> {
  const sourceFile = getStorage().bucket().file(storagePath);
  for (let attempt = 0; attempt < 10; attempt++) {
    await new Promise((resolve) => setTimeout(resolve, 500));
    const [exists] = await sourceFile.exists();
    if (!exists) return true;
  }
  return false;
}

/**
 * Vérifie un upload en quarantaine puis le promeut vers scans/ si propre.
 *
 * Entrée: { storagePath: "quarantine/<uid>/<filename>" }
 * Sortie: { status: "clean", downloadUrl, storagePath, mimeType, sizeBytes }
 *
 * Idempotente. Le SDK Android rejoue un appel dont la connexion est tombée
 * avant la réponse : le serveur reçoit alors deux requêtes pour le même
 * fichier, la seconde pendant que la première tourne encore. Le 6 septembre
 * 2026, la première a supprimé la source pendant que la seconde la lisait ;
 * « No such object » est remonté tel quel jusqu'à l'écran, et le job d'import
 * n'a jamais été créé alors que le fichier était promu et sain. Deux requêtes
 * pour un même chemin rendent désormais la même réponse : une seule copie,
 * l'autre relit son résultat.
 */
export const scanAndPromoteUploadFn = onCall(callableOpts, async (req) => {
  const ctx = await requireAuth(req, "upload_security_scan");
  // `scanId` vient du client, et lui seul peut le fournir : le contrôle du
  // fichier a lieu AVANT que le job d'import existe, et une même photo peut
  // arriver avec ses pages supplémentaires en plusieurs appels. Sans lui, le
  // coût de ce contrôle restait un groupe de journaux orphelin.
  const { storagePath, scanId: rawScanId } = (req.data ?? {}) as {
    storagePath?: string;
    scanId?: string;
  };
  const scanId =
    typeof rawScanId === "string" && rawScanId.trim().length > 0 ? rawScanId.trim() : undefined;

  if (!storagePath || typeof storagePath !== "string") {
    throw new HttpsError("invalid-argument", "storagePath est requis.");
  }

  const expectedPrefix = `quarantine/${ctx.userId}/`;
  if (!storagePath.startsWith(expectedPrefix)) {
    throw new HttpsError("permission-denied", "Chemin de quarantaine invalide.");
  }

  const bucket = getStorage().bucket();
  const sourceFile = bucket.file(storagePath);
  const promotedPath = storagePath.replace("quarantine/", "scans/");
  // Un livre entier arrive sous `livres/` : plafond de 300 Mo, contrôle en flux.
  const isBookUpload = storagePath.startsWith(`${expectedPrefix}${BOOK_UPLOAD_FOLDER}/`);

  // Relit la promotion faite par l'autre requête, et le dit dans le journal :
  // sans cette ligne, un appel rejoué ressemble à un appel qui n'a rien coûté.
  const replayed = async (cause: string): Promise<PromotedUpload | null> => {
    const replay = await replayPromotion(promotedPath);
    if (replay) {
      await logInfo({
        message: "Upload deja promu par une requete concurrente : reponse rejouee",
        moduleType: "IMPORT",
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        scanId,
        extra: { quarantinePath: storagePath, promotedPath, cause },
      });
    }
    return replay;
  };

  try {
    const [exists] = await sourceFile.exists();
    if (!exists) {
      const replay = await replayed("source_absente");
      if (replay) return replay;
      await logError({
        message: "Fichier en quarantaine introuvable, et aucune promotion anterieure",
        moduleType: "IMPORT",
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        scanId,
        extra: { quarantinePath: storagePath, promotedPath },
      });
      throw new HttpsError("not-found", "Fichier en quarantaine introuvable.");
    }

    const [meta] = await sourceFile.getMetadata();
    const fileName = storagePath.split("/").pop() ?? "upload";

    // Un livre entier ne se charge pas en mémoire : la fonction en a 512 Mo, le
    // livre jusqu'à 300. On lit son en-tête pour la signature, et on parcourt le
    // reste en flux pour la recherche de signature antivirus.
    let scan: ReturnType<typeof scanUpload>;
    let sizeBytes: number;
    if (isBookUpload) {
      sizeBytes = Number(meta.size ?? 0);
      scan = scanUploadHead({
        fileName,
        mimeType: meta.contentType,
        size: sizeBytes,
        head: await readHead(sourceFile, 64 * 1024),
      });
      if (scan.clean && (await streamContainsEicar(sourceFile.createReadStream()))) {
        scan = { clean: false, reason: "Fichier detecte comme malveillant (signature EICAR)." };
      }
    } else {
      const [bytes] = await sourceFile.download();
      sizeBytes = bytes.length;
      scan = scanUpload({
        fileName,
        mimeType: meta.contentType,
        bytes,
      });
    }
    const detectedMime = scan.normalizedMimeType ?? meta.contentType ?? "application/octet-stream";
    await logUploadScanUsage({
      uid: ctx.userId,
      correlationId: ctx.correlationId,
      scanId,
      sizeBytes,
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

    // Une seule requête crée la copie promue : `ifGenerationMatch: 0` refuse
    // la copie (412) si l'objet existe déjà. Chaque chemin porte l'horodatage
    // en millisecondes de son envoi ; un objet déjà là est donc l'œuvre d'une
    // requête concurrente pour ce même envoi, jamais d'un envoi antérieur.
    let promotedFile = bucket.file(promotedPath);
    try {
      [promotedFile] = await sourceFile.copy(promotedFile, {
        preconditionOpts: { ifGenerationMatch: 0 },
      });
    } catch (copyError) {
      if (storageErrorCode(copyError) !== 412) throw copyError;
      if (await waitForSourceGone(storagePath)) {
        const replay = await replayed("copie_concurrente");
        if (replay) return replay;
      }
      // La source est toujours là : l'autre requête s'est arrêtée entre sa
      // copie et sa suppression. La copie existe, on termine la promotion ici.
      await logInfo({
        message: "Copie promue deja presente, promotion terminee par cette requete",
        moduleType: "IMPORT",
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        scanId,
        extra: { quarantinePath: storagePath, promotedPath },
      });
    }
    await promotedFile.setMetadata({
      contentType: detectedMime,
      metadata: {
        ...(meta.metadata ?? {}),
        quarantine_status: "clean",
        quarantine_scanned_at: new Date().toISOString(),
      },
    });

    const downloadUrl = await getDownloadURL(promotedFile);
    try {
      await sourceFile.delete();
    } catch (deleteError) {
      // Best-effort : la promotion est faite, le fichier reste en quarantaine
      // et occupe du stockage. Le dire, sans échouer.
      await logError({
        message: "Source en quarantaine non supprimee apres promotion",
        moduleType: "IMPORT",
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        scanId,
        errorDescription: deleteError instanceof Error ? deleteError.message : String(deleteError),
        extra: { quarantinePath: storagePath, promotedPath },
      });
    }

    await logInfo({
      message: "Upload scanne puis promu hors quarantaine",
      moduleType: "IMPORT",
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      scanId,
      extra: {
        quarantinePath: storagePath,
        promotedPath,
        mimeType: detectedMime,
        sizeBytes,
      },
    });

    const result: PromotedUpload = {
      status: "clean",
      downloadUrl,
      storagePath: promotedPath,
      mimeType: detectedMime,
      sizeBytes,
    };
    return result;
  } catch (e) {
    // La source a disparu entre `exists()` et sa lecture : l'autre requête a
    // fini avant nous. C'est le cas du 6 septembre 2026.
    if (storageErrorCode(e) === 404) {
      const replay = await replayed("source_disparue");
      if (replay) return replay;
    }
    if (!(e instanceof HttpsError)) {
      // Sans cette ligne, l'échec ne laissait qu'un 500 dans les journaux de
      // Cloud Run, sans chemin ni utilisateur.
      await logError({
        message: "Scan de securite en echec technique",
        moduleType: "IMPORT",
        userId: ctx.userId,
        correlationId: ctx.correlationId,
        scanId,
        errorDescription: e instanceof Error ? e.message : String(e),
        extra: { quarantinePath: storagePath, promotedPath, storageCode: storageErrorCode(e) },
      });
    }
    throw toHttpsError(e);
  }
});

/**
 * Détecte les illustrations et retourne les découpes (base64) prêtes à être
 * téléversées.
 *
 * Le client ne reçoit plus les boîtes. Il les recevait, et refaisait la découpe
 * lui-même au rectangle, avec le paquet Dart `image` : le redressement de
 * perspective calculé ici — et facturé — partait à la poubelle, et une page
 * photographiée de biais ressortait avec ses deux coins de table.
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
      // Redressée d'abord, comme dans le pipeline d'import : le modèle rend
      // ses coordonnées dans le repère AFFICHÉ, Sharp découpe le repère
      // STOCKÉ. Sur une photo de téléphone, les deux sont tournés de
      // quatre-vingt-dix degrés — c'est ce qui rendait « un bout de bureau »
      // au lieu du plat.
      const bytes = await uprightImage(bytesFromBase64(bytesBase64));
      const boxes = await detectIllustrationRegions(GEMINI_API_KEY.value(), bytes, mimeType, {
        ...ctx,
        feature: "detect_illustrations",
        moduleType: "DESIGN",
      });
      // Le tri de qualité écarte ce qui n'est manifestement pas une
      // photographie : une bande de texte, une icône, un bout de marge. Il ne
      // coûte aucun appel de modèle. Le client se contentait d'ignorer les
      // découpes de moins de cinquante pixels.
      const selection = await cropAndSelectIllustrations(bytes, boxes);
      if (selection.dropped.length > 0) {
        await logInfo({
          message: `Illustrations : ${selection.dropped.length} découpe(s) écartée(s) sur ${boxes.length}`,
          moduleType: "DESIGN",
          correlationId: ctx.correlationId,
          userId: ctx.userId,
          feature: "detect_illustrations",
          extra: { raisons: selection.dropped.map((d) => rejectionLabel(d.reason)) },
        });
      }
      return {
        detected: boxes.length,
        cropsBase64: selection.kept.map((c) => c.bytes.toString("base64")),
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
