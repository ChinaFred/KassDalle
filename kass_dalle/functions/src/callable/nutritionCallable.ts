import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue, getFirestore } from "firebase-admin/firestore";

import { REGION, COLL_APP_CONFIG, COLL_RECIPES, COLL_NUTRITION_UNITS, GEMINI_API_KEY } from "../config";
import { requireAdmin, requireAuth } from "./_auth";
import {
  DEFAULT_NUTRITION_POLICY,
  getNutritionSourcePolicy,
  NUTRITION_POLICY_DOC_ID,
  type NutritionSourcePolicy,
} from "../nutrition/policy";
import { normalizeNutrients } from "../nutrition/nutrients";
import { buildIngredientLookupIds, normalizeIngredientStrictId } from "../nutrition/ingredientName";
import { canonicalizeNormalizedUnit, unitFactorToGrams, normalizeObservedUnit } from "../nutrition/quantityConversion";
import { normalizeIngredientCanonicalId } from "../nutrition/ingredientName";
import { resolveIngredientUnitFields } from "../nutrition/ingredientUnitResolution";
import { upsertNutritionUnitReference } from "../nutrition/unitReference";
import { extractIngredientsStructured } from "../cooklang/parser";
import { logError, logInfo } from "../logging";
import { callGemini, textPart } from "../gemini/client";
import { recordTokenUsage } from "../gemini/tokenUsage";
import { estimatePer100gWithGemini, hasPer100gValues } from "../nutrition/per100gEnrichment";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const callableOpts = {
  region: REGION,
  memory: "256MiB" as const,
  timeoutSeconds: 60,
  cors: ALLOWED_ORIGINS,
};

interface SetNutritionPolicyRequest {
  policy?: Partial<NutritionSourcePolicy>;
}

interface NormalizeNutrientsRequest {
  nutrients?: Record<string, unknown>;
}

interface ComputeRecipeNutritionRequest {
  recipeId?: string;
  selectedPortions?: number;
}

interface NormalizeRecipeReferentialsRequest {
  recipeId?: string;
  cooklang?: string;
  ingredients?: Array<Record<string, unknown>>;
}

export interface NormalizeRecipeReferentialsResult {
  rewrittenCooklang: string;
  resolvedIngredients: Array<Record<string, unknown>>;
  stats: {
    totalIngredients: number;
    unitsResolved: number;
    ingredientsKnown: number;
    ingredientsProposed: number;
    renamedUnits: number;
    renamedIngredients: number;
    aiCompletedIngredients: number;
  };
}

interface NormalizedRecipeIngredient {
  name: string;
  qty: string;
  unit: string;
  category?: string;
  unit_raw: string;
  unit_canonical: string;
  unit_resolution_source: string;
  unit_resolution_confidence: number;
  ingredient_ref_id: string;
  ingredient_ref_status: "known" | "proposed";
  ingredient_canonical_name: string;
  ingredient_resolution_source: "referential" | "fallback";
  ingredient_resolution_confidence: number;
}

interface IngredientInput {
  name?: unknown;
  qty?: unknown;
  unit?: unknown;
}

interface IngredientProfile {
  per100g?: Record<string, unknown>;
  source?: string;
}

interface IngredientResolution {
  name: string;
  weightGrams: number;
  lookupIds: string[];
}

const NUTRIENT_KEYS = [
  "kcal",
  "protein_g",
  "carbs_g",
  "sugar_g",
  "fiber_g",
  "fat_g",
  "saturated_fat_g",
  "sodium_mg",
  "salt_g",
] as const;

function asPositiveNumber(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value) && value > 0) return value;
  if (typeof value === "string") {
    const trimmed = value.trim().replace(",", ".");
    const fraction = trimmed.match(/^(\d+)\s*\/\s*(\d+)$/);
    if (fraction) {
      const num = Number(fraction[1]);
      const den = Number(fraction[2]);
      if (Number.isFinite(num) && Number.isFinite(den) && den > 0) {
        return num / den;
      }
    }
    const parsed = Number(trimmed);
    if (Number.isFinite(parsed) && parsed > 0) return parsed;
  }
  return null;
}

function unitFactor(unit: unknown): number | null {
  if (typeof unit !== "string") return null;
  const key = normalizeIngredientStrictId(unit);
  return key ? unitFactorToGrams(canonicalizeNormalizedUnit(key)) : null;
}

function roundValue(value: number, digits = 2): number {
  const factor = Math.pow(10, digits);
  return Math.round(value * factor) / factor;
}

const UNIT_LABEL_BY_CANONICAL: Record<string, string> = {
  c_a_c: "c.à.c.",
  c_a_s: "c.à.s.",
  c_a_d: "c.à.d.",
  piece: "pièce",
  pincee: "pincée",
  l: "L",
};

function fallbackUnitLabel(normalizedUnit: string): string {
  if (!normalizedUnit) return "";
  return UNIT_LABEL_BY_CANONICAL[normalizedUnit] ?? normalizedUnit.replace(/_/g, " ");
}

function parseQtyAndUnit(raw: string): { qty: string; unit: string } {
  const parts = raw.split("%");
  const qty = parts.length > 0 ? parts[0].trim() : "";
  const unit = parts.length > 1 ? parts.slice(1).join("%").trim() : "";
  return { qty, unit };
}

function formatQtyAndUnit(qty: string, unit: string): string {
  if (!qty && !unit) return "";
  if (!unit) return qty;
  return `${qty}%${unit}`;
}

function inferUnitFromIngredientName(args: {
  rawName: string;
  rawUnit: string;
}): { ingredientName: string; unit: string } {
  const initialName = args.rawName.trim();
  const initialUnit = args.rawUnit.trim();
  if (initialName.length == 0 || initialUnit.length > 0) {
    return { ingredientName: initialName, unit: initialUnit };
  }

  // Cas fréquent OCR/IA : l'unité est incluse dans le nom
  // ex: "brin de cerfeuil frais", "gousse d'ail".
  const match = initialName.match(
    /^(brin|brins|gousse|gousses|pinc[ée]e|pinc[ée]es|pi[èe]ce|pi[èe]ces|tranche|tranches|feuille|feuilles|bouquet|bouquets|branche|branches|filet|filets|tige|tiges|noisette|noisettes|zeste|zestes)\s+(?:de|d')\s+(.+)$/i,
  );
  if (!match) {
    return { ingredientName: initialName, unit: "" };
  }

  const unit = match[1].trim().toLowerCase();
  const ingredientName = match[2].trim(); // Conserve les qualificatifs ("frais", "séché"…) — identitaires pour la nutrition
  if (ingredientName.length == 0) {
    return { ingredientName: initialName, unit: "" };
  }
  return { ingredientName, unit };
}

// ── Singularisation des unités culinaires ──────────────────────────────────────────────
// Note : le regex `inferUnitFromIngredientName` est un parseur STRUCTUREL (détecte le
// patron "<unité> de <ingrédient>" dans le nom) — ce n'est PAS une table de mapping.
// La singularisation (brins→brin) est déléguée à Gemini (appel batch par recette),
// avec fallback algorithmique (strip 's' final) si Gemini est indisponible.

/** Singularisation algorithmique de repli : strip le 's' final (valide pour ~100 % des unités culinaires fr.). */
function fallbackSingularize(unit: string): string {
  const t = unit.trim().toLowerCase();
  if (t.length > 2 && t.endsWith("s")) return t.slice(0, -1);
  return t;
}

/**
 * Singularise les unités culinaires françaises via Gemini — appel batch unique par recette.
 * Toutes les unités potentiellement plurielles (terminaison -s) sont envoyées en un seul
 * appel ; les résultats sont loggés et les coûts tracés via recordTokenUsage.
 * Retourne une Map {forme_brute → singulier_lowercase}.
 * En cas d'échec Gemini, le fallback algorithmique (strip 's') est conservé.
 */
async function singularizeFrenchUnitsWithGemini(args: {
  units: string[];
  geminiApiKey: string;
  recipeId?: string;
  userId?: string;
}): Promise<Map<string, string>> {
  // Valeur par défaut pour chaque unité : fallback algorithmique
  const result = new Map<string, string>();
  for (const u of args.units) {
    result.set(u, fallbackSingularize(u));
  }

  // Filtre : seules les formes se terminant par 's' (heuristique pluriel français)
  const potentialPlurals = args.units.filter((u) => {
    const t = u.trim().toLowerCase();
    return t.length > 2 && t.endsWith("s");
  });
  if (potentialPlurals.length === 0) return result;

  const unitList = potentialPlurals.map((u) => `"${u.trim()}"`).join(", ");
  const prompt = `Tu es un expert en terminologie culinaire française.
Mets chacune de ces unités culinaires au singulier si elle est au pluriel.
Si elle est déjà au singulier ou n'est pas une unité culinaire reconnue, retourne-la telle quelle.

Unités : ${unitList}

Retourne UNIQUEMENT un objet JSON valide {"pluriel": "singulier"}, sans texte additionnel :`;

  void logInfo({
    message: `singularizeFrenchUnitsWithGemini: ${potentialPlurals.length} unité(s) à singulariser`,
    extra: { recipeId: args.recipeId, units: potentialPlurals },
  });

  try {
    void logInfo({
      message: "singularizeFrenchUnitsWithGemini: prompt envoyé à Gemini",
      extra: { recipeId: args.recipeId, potentialPlurals, prompt },
    });

    const geminiResult = await callGemini(
      args.geminiApiKey,
      [textPart(prompt)],
      {
        correlationId: `singularize-units-${args.recipeId ?? Date.now()}`,
        feature: "singularize_units",
        userId: args.userId ?? "system",
        moduleType: "DESIGN",
        timeoutMs: 10_000,
      },
    );

    await recordTokenUsage(geminiResult, "singularize_units", args.userId ?? "system");

    const raw = (geminiResult.response.text() ?? "").trim();
    void logInfo({
      message: "singularizeFrenchUnitsWithGemini: réponse brute Gemini",
      extra: { recipeId: args.recipeId, rawResponse: raw.slice(0, 600) },
    });
    const jsonMatch = raw.match(/\{[\s\S]*?\}/);
    if (!jsonMatch) return result;

    const parsed: unknown = JSON.parse(jsonMatch[0]);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return result;

    for (const [plural, singular] of Object.entries(parsed as Record<string, unknown>)) {
      if (typeof singular === "string" && singular.trim().length > 0) {
        const singularLower = singular.trim().toLowerCase();
        result.set(plural, singularLower);
        // Map aussi la forme originale (pour une correspondance insensible à la casse)
        const originalForm = args.units.find(
          (u) => u.trim().toLowerCase() === plural.trim().toLowerCase(),
        );
        if (originalForm) result.set(originalForm, singularLower);
      }
    }
  } catch (err) {
    void logError({
      message: "singularizeFrenchUnitsWithGemini: échec (best-effort, fallback algorithmique appliqué)",
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId: `singularize-units-${args.recipeId ?? "norecipe"}`,
    });
  }

  return result;
}

// Ingrédients comptés à la pièce qui doivent recevoir « pièce » comme unité
// quand aucune unité n'est fournie (ni dans le champ unit, ni inférable du nom).
const PIECE_INGREDIENT_IDS = [
  // Protéines portionnées
  "blanc_de_poulet",
  "filet_de_poulet",
  "haut_de_cuisse_de_poulet",
  "haut_de_cuisse",
  "cuisse_de_poulet",
  "escalope",
  "steak",
  "steack",
  "cote_de_veau",
  "cote_de_porc",
  "cote_d_agneau",
  "entrecote",
  "filet_mignon",
  "magret_de_canard",
  "magret",
  // Légumes/aromates typiquement comptés à la pièce
  "echalote",
  "oignon",
  "aubergine",
  "courgette",
  "poivron",
  "concombre",
  "navet",
  "poireau",
  "citron",
  "orange",
];

function inferPieceUnitIfEmpty(ingredientName: string): string {
  const normalizedId = normalizeIngredientCanonicalId(ingredientName);
  if (!normalizedId) return "";
  return PIECE_INGREDIENT_IDS.some((pid) => normalizedId.includes(pid)) ? "pièce" : "";
}

// Quantités non numériques issues de l'extraction Gemini ("pour la cuisson",
// "à volonté", etc.) à traiter comme vides lors de la normalisation.
const INVALID_QTY_PATTERNS: RegExp[] = [
  /^pour\s/i,
  /^à\s+volon/i,
  /^au\s+go[uû]t/i,
  /^qsp$/i,
  /^qs$/i,
  /^selon\s/i,
  /^un\s+peu/i,
  /^quelques$/i,
  /^suffisamment/i,
];

function cleanQtyValue(qty: string): string {
  if (!qty) return "";
  return INVALID_QTY_PATTERNS.some((p) => p.test(qty.trim())) ? "" : qty;
}

// ── Complétion IA des quantités manquantes ────────────────────────────────────

function buildCompleteQuantitiesPrompt(cooklang: string, ingredientList: string): string {
  return `Tu es un expert en cuisine française. La recette ci-dessous a des ingrédients dont la quantité n'est pas précisée.
En analysant les étapes de préparation et le contexte du plat, propose une quantité typique pour chacun.

Recette (CookLang) :
---
${cooklang.slice(0, 3000)}
---

Ingrédients à compléter :
${ingredientList}

Règles :
- Huile/matière grasse pour cuisson (fond de poêle, saisir) → qty="1" unit="filet" ou qty="2" unit="c.à.s."
- Herbes fraîches sans unité indiquée (cerfeuil, persil, coriandre, anéth, basilic, estragon, thym, romarin, menthe, ciboulette...) :
  Cherche dans les étapes comment elles apparaissent (« brins de... », « bouquet de... », « feuilles de... ») et utilise cette unité. Défaut : unit="brin" qty="2" à "5".
- Herbes fraîches avec unité déjà connue (brin, feuille, bouquet...) → qty entre "2" et "5"
- Sel ou poivre clairement omis des étapes → qty="1" unit="pincée"
- Liquide de déglaçage → adapte au plat
- Utilise EXACTEMENT le même nom que dans la liste ci-dessus (pas de paraphrase)
- Si impossible à déduire du contexte, omet cet ingrédient du résultat
- N'invente PAS de précision excessive

Retourne UNIQUEMENT un tableau JSON (tableau vide [] si aucune suggestion) :
[{"name":"<nom exact>","qty":"<nombre>","unit":"<unité ou chaîne vide si déjà fournie>","gramsPerUnit":<poids en g pour 1 unité ou null si inconnu>}]`;
}

/**
 * Passe IA secondaire (best-effort) : complète les quantités manquantes
 * en s'appuyant sur le contexte de la recette.
 * Ne lève jamais d'erreur — retourne une Map vide en cas d'échec.
 */
async function completeIngredientQuantitiesWithAI(args: {
  cooklang: string;
  incompleteIngredients: Array<{ name: string; unit: string }>;
  recipeId?: string;
  geminiApiKey: string;
  userId?: string;
}): Promise<Map<string, { qty: string; unit: string; gramsPerUnit?: number }>> {
  const result = new Map<string, { qty: string; unit: string; gramsPerUnit?: number }>();
  if (args.incompleteIngredients.length === 0) return result;

  const ingredientList = args.incompleteIngredients
    .map((i) => `- ${i.name}${i.unit ? ` (unité déjà connue : ${i.unit})` : ""}`)
    .join("\n");

  const prompt = buildCompleteQuantitiesPrompt(args.cooklang, ingredientList);

  try {
    void logInfo({
      message: `completeIngredientQuantitiesWithAI: envoi ${args.incompleteIngredients.length} ingrédient(s) incomplet(s)`,
      extra: {
        recipeId: args.recipeId,
        ingredients: args.incompleteIngredients,
        prompt: prompt.slice(0, 2000),
      },
    });

    const geminiResult = await callGemini(
      args.geminiApiKey,
      [textPart(prompt)],
      {
        correlationId: `complete-qty-${args.recipeId ?? Date.now()}`,
        feature: "complete_ingredient_quantities",
        userId: args.userId ?? "system",
        moduleType: "DESIGN",
        timeoutMs: 30_000,
      },
    );

    await recordTokenUsage(geminiResult, "complete_ingredient_quantities", args.userId ?? "system");

    const raw = (geminiResult.response.text() ?? "").trim();
    void logInfo({
      message: "completeIngredientQuantitiesWithAI: réponse brute Gemini",
      extra: { recipeId: args.recipeId, rawResponse: raw.slice(0, 800) },
    });
    const jsonMatch = raw.match(/\[[\s\S]*?\]/);
    if (!jsonMatch) return result;

    const parsed: unknown = JSON.parse(jsonMatch[0]);
    if (!Array.isArray(parsed)) return result;

    for (const item of parsed) {
      if (!item || typeof item !== "object") continue;
      const obj = item as Record<string, unknown>;
      const name = typeof obj.name === "string" ? obj.name.trim().toLowerCase() : "";
      const qty = typeof obj.qty === "string" ? obj.qty.trim() : "";
      const unit = typeof obj.unit === "string" ? obj.unit.trim() : "";
      const gramsPerUnit = typeof obj.gramsPerUnit === "number" && obj.gramsPerUnit > 0
        ? obj.gramsPerUnit
        : undefined;
      if (name && qty) {
        result.set(name, { qty, unit, gramsPerUnit });
      }
    }
    void logInfo({
      message: `completeIngredientQuantitiesWithAI: ${result.size} suggestion(s) parsée(s)`,
      extra: { recipeId: args.recipeId, suggestions: Object.fromEntries(result) },
    });
  } catch (err) {
    // Best-effort : une erreur IA ne bloque pas la normalisation
    const msg = err instanceof Error ? err.message : String(err);
    void logError({
      message: "completeIngredientQuantitiesWithAI: échec (best-effort)",
      errorDescription: msg,
      correlationId: `complete-qty-${args.recipeId ?? "norecipe"}`,
    });
  }

  return result;
}

/**
 * Assure l’existence du document ingrédient dans `nutrition_ingredients`.
 *
 * - Si `observedUnit` est fourni et que le document n’a pas encore de `default_unit`,
 *   l’unité est persistée pour les futures résolutions (principe d’apprentissage).
 * - Retourne `defaultUnit` : l’unité par défaut stockée en référentiel (si disponible).
 */
async function ensureIngredientReference(args: {
  ingredientRawName: string;
  recipeId?: string;
  /** Unité observée à persister comme default_unit si le référentiel n’en a pas encore. */
  observedUnit?: string;
}): Promise<{ ingredientRefId: string; canonicalName: string; status: "known" | "proposed"; defaultUnit?: string }> {
  const db = getFirestore();
  const ingredientRefId = normalizeIngredientCanonicalId(args.ingredientRawName);
  if (!ingredientRefId) {
    return {
      ingredientRefId: "",
      canonicalName: args.ingredientRawName.trim(),
      status: "proposed",
    };
  }

  const observed = args.observedUnit?.trim() || "";
  const docRef = db.collection("nutrition_ingredients").doc(ingredientRefId);
  const snap = await docRef.get();

  if (snap.exists) {
    const data = snap.data() as Record<string, unknown>;
    const canonicalName = typeof data.canonical_name === "string" && data.canonical_name.trim().length > 0
      ? data.canonical_name.trim()
      : ingredientRefId.replace(/_/g, " ");
    const storedDefaultUnit = typeof data.default_unit === "string" && data.default_unit.trim().length > 0
      ? data.default_unit.trim()
      : undefined;

    // Enrichit le référentiel si l’unité n’était pas encore connue pour cet ingrédient.
    const updates: Record<string, unknown> = {
      aliases: FieldValue.arrayUnion(args.ingredientRawName.trim()),
      seen_count: FieldValue.increment(1),
      last_seen_at: FieldValue.serverTimestamp(),
      updated_at: FieldValue.serverTimestamp(),
      ...(args.recipeId ? { last_seen_recipe_id: args.recipeId } : {}),
    };
    if (!storedDefaultUnit && observed) {
      updates.default_unit = observed;
    }
    await docRef.set(updates, { merge: true });

    return {
      ingredientRefId,
      canonicalName,
      status: "known",
      defaultUnit: storedDefaultUnit,
    };
  }

  // Création : persist le default_unit dès la première rencontre si une unité est connue.
  await docRef.set({
    canonical_name: ingredientRefId.replace(/_/g, " "),
    aliases: FieldValue.arrayUnion(args.ingredientRawName.trim()),
    per100g: {},
    source: "recipe_referential_resolution",
    quality_status: "pending",
    status: "proposed",
    seen_count: 1,
    ...(observed ? { default_unit: observed } : {}),
    first_seen_at: FieldValue.serverTimestamp(),
    last_seen_at: FieldValue.serverTimestamp(),
    ...(args.recipeId ? { last_seen_recipe_id: args.recipeId } : {}),
    created_at: FieldValue.serverTimestamp(),
    updated_at: FieldValue.serverTimestamp(),
  }, { merge: true });

  return {
    ingredientRefId,
    canonicalName: ingredientRefId.replace(/_/g, " "),
    status: "proposed",
    defaultUnit: observed || undefined,
  };
}

async function resolveUnitDisplay(args: {
  ingredientName: string;
  unitRaw: string;
  recipeId?: string;
}): Promise<{
  displayUnit: string;
  unitCanonical: string;
  unitRaw: string;
  unitResolutionSource: string;
  unitResolutionConfidence: number;
}> {
  const db = getFirestore();
  const resolved = resolveIngredientUnitFields({
    name: args.ingredientName,
    qty: "",
    unit: args.unitRaw,
  });

  let canonical = resolved.unit_canonical;
  if (!canonical && args.unitRaw.trim().length > 0) {
    const upserted = await upsertNutritionUnitReference({
      db,
      unitRaw: args.unitRaw,
      ingredientName: args.ingredientName,
      recipeId: args.recipeId,
    });
    canonical = upserted.normalizedUnit ?? "";
  }

  if (!canonical) {
    return {
      displayUnit: args.unitRaw.trim(),
      unitCanonical: "",
      unitRaw: args.unitRaw.trim(),
      unitResolutionSource: resolved.unit_resolution_source,
      unitResolutionConfidence: resolved.unit_resolution_confidence,
    };
  }

  const unitRef = await db.collection("nutrition_units").doc(canonical).get();
  if (!unitRef.exists) {
    await upsertNutritionUnitReference({
      db,
      unitRaw: args.unitRaw || canonical,
      ingredientName: args.ingredientName,
      recipeId: args.recipeId,
    });
  }

  const unitData = unitRef.data() as Record<string, unknown> | undefined;
  const fromDisplayLabel = typeof unitData?.display_label === "string"
    ? unitData.display_label.trim()
    : "";
  const fromLabel = typeof unitData?.label === "string"
    ? unitData.label.trim()
    : "";
  const aliases = Array.isArray(unitData?.aliases)
    ? unitData?.aliases.filter((v): v is string => typeof v === "string" && v.trim().length > 0)
    : [];

  const displayUnit =
    fromDisplayLabel ||
    fromLabel ||
    (aliases.length > 0 ? aliases[0].trim() : "") ||
    fallbackUnitLabel(canonical);

  return {
    displayUnit,
    unitCanonical: canonical,
    unitRaw: resolved.unit_raw,
    unitResolutionSource: resolved.unit_resolution_source,
    unitResolutionConfidence: resolved.unit_resolution_confidence,
  };
}

async function resolveOneIngredient(args: {
  item: Record<string, unknown>;
  recipeId?: string;
  /** Callback de singularisation fourni par normalizeRecipeReferentialsCore (Gemini ou fallback). */
  singularizeUnit?: (unit: string) => string;
}): Promise<NormalizedRecipeIngredient | null> {
  const rawName = typeof args.item.name === "string" ? args.item.name.trim() : "";
  if (!rawName) return null;
  // Nettoie les fausses quantités Gemini ("pour la cuisson", "à volonté"…)
  const qty = cleanQtyValue(typeof args.item.qty === "string" ? args.item.qty.trim() : "");
  const rawUnit = typeof args.item.unit === "string" ? args.item.unit.trim() : "";
  const category = typeof args.item.category === "string" ? args.item.category.trim() : "";

  const inferred = inferUnitFromIngredientName({
    rawName,
    rawUnit,
  });
  // Singularise via Gemini (batch pré-calculé) ou fallback algorithmique
  const singularUnit = args.singularizeUnit
    ? args.singularizeUnit(inferred.unit)
    : fallbackSingularize(inferred.unit);
  // Heuristique bootstrap : infère « pièce » pour les ingrédients portionnés connus.
  // (Le référentiel prendra le relais une fois default_unit persisté.)
  const heuristicUnit = singularUnit || inferPieceUnitIfEmpty(inferred.ingredientName);

  // On ne persiste dans le référentiel que les unités INFÉRÉES (rawUnit était vide).
  // Si l'unité est explicite dans la recette (ex: "45 g"), on ne l'écrit PAS comme
  // default_unit : ce serait faux pour un ingrédient comme l'échalote la prochaine
  // fois qu'il apparaît sans unité.
  const unitWasInferred = !rawUnit.trim() && !!heuristicUnit;
  const unitToStore = unitWasInferred ? heuristicUnit : undefined;

  // Lecture du référentiel : si l'ingrédient a déjà un default_unit stocké,
  // on l'utilise en priorité. L'unité inférée est persistée si elle est nouvelle.
  const ingredientRef = await ensureIngredientReference({
    ingredientRawName: inferred.ingredientName,
    recipeId: args.recipeId,
    observedUnit: unitToStore,
  });
  // Priorité : unité extraite/inférée > default_unit du référentiel
  const resolvedUnitRaw = heuristicUnit || ingredientRef.defaultUnit || "";

  const unit = await resolveUnitDisplay({
    ingredientName: ingredientRef.canonicalName,
    unitRaw: resolvedUnitRaw,
    recipeId: args.recipeId,
  });

  return {
    name: ingredientRef.canonicalName,
    qty,
    unit: unit.displayUnit,
    ...(category ? { category } : {}),
    unit_raw: unit.unitRaw,
    unit_canonical: unit.unitCanonical,
    unit_resolution_source: unit.unitResolutionSource,
    unit_resolution_confidence: unit.unitResolutionConfidence,
    ingredient_ref_id: ingredientRef.ingredientRefId,
    ingredient_ref_status: ingredientRef.status,
    ingredient_canonical_name: ingredientRef.canonicalName,
    ingredient_resolution_source: ingredientRef.status === "known" ? "referential" : "fallback",
    ingredient_resolution_confidence: ingredientRef.status === "known" ? 1 : 0.6,
  };
}

async function rewriteCooklangWithReferentials(args: {
  cooklang: string;
  recipeId?: string;
  /** Suggestions IA de quantités pour les ingrédients sans qty. */
  qtyOverrides?: Map<string, { qty: string; unit: string }>;
  /** Callback de singularisation transmis à resolveOneIngredient. */
  singularizeUnit?: (unit: string) => string;
}): Promise<string> {
  const re = /@([^{@#~\n]+)\{([^}]*)\}/g;
  const matches = [...args.cooklang.matchAll(re)];
  if (matches.length === 0) return args.cooklang;

  let out = "";
  let cursor = 0;
  for (const m of matches) {
    const tokenStart = m.index ?? 0;
    const tokenEnd = tokenStart + m[0].length;
    out += args.cooklang.slice(cursor, tokenStart);

    const rawName = m[1].trim();
    const parsed = parseQtyAndUnit(m[2] ?? "");
    const resolved = await resolveOneIngredient({
      item: {
        name: rawName,
        qty: parsed.qty,
        unit: parsed.unit,
      },
      recipeId: args.recipeId,
      singularizeUnit: args.singularizeUnit,
    });

    if (resolved == null) {
      out += m[0];
    } else {
      let qty = resolved.qty;
      let unit = resolved.unit;
      // Applique les suggestions IA si la quantité est toujours vide
      if (!qty && args.qtyOverrides) {
        const override = args.qtyOverrides.get(resolved.name.toLowerCase());
        if (override) {
          qty = override.qty;
          if (!unit && override.unit) unit = override.unit;
        }
      }
      out += `@${resolved.name}{${formatQtyAndUnit(qty, unit)}}`;
    }
    cursor = tokenEnd;
  }
  out += args.cooklang.slice(cursor);
  return out;
}

// ── Enrichissement IA des unités sans poids (appelé lors de la normalisation) ─────────

function buildUnitWeightPrompt(unitList: string): string {
  return `Tu es un expert en mesures culinaires. Pour chaque unité ci-dessous, estime :
- Le poids approximatif en grammes pour 1 unité (gramsPerUnit)
- Le volume en millilitres si c'est une unité de volume liquide (volumeMl, sinon null)
- Le type de mesure : "weight" (solide/comptable) ou "volume" (liquide)

Unités à évaluer :
${unitList}

Exemples de référence :
- brin (d'herbe fraîche) : gramsPerUnit=2, volumeMl=null, measurementType=weight
- filet (d'huile) : gramsPerUnit=5, volumeMl=5, measurementType=volume
- tige (de citronnelle) : gramsPerUnit=20, volumeMl=null, measurementType=weight
- zeste (de citron) : gramsPerUnit=3, volumeMl=null, measurementType=weight

Retourne UNIQUEMENT un tableau JSON valide (sans texte additionnel) :
[{"unit":"<nom exact>","gramsPerUnit":<nombre ou null>,"volumeMl":<nombre ou null>,"measurementType":"weight"|"volume"}]`;
}

/**
 * Enrichit en IA les unités sans poids détectées lors de la normalisation.
 * Best-effort : ne bloque jamais la normalisation en cas d'échec.
 */
async function enrichUnknownUnitsWithAI(args: {
  unitCanonicals: string[];
  geminiApiKey: string;
  userId?: string;
  recipeId?: string;
}): Promise<void> {
  if (args.unitCanonicals.length === 0) return;

  const db = getFirestore();
  const refs = args.unitCanonicals.map((u) => db.collection(COLL_NUTRITION_UNITS).doc(u));
  const snaps = await db.getAll(...refs);

  const unitsNeedingEnrichment: Array<{ canonical: string; label: string }> = [];
  for (const snap of snaps) {
    if (!snap.exists) continue;
    const data = snap.data() as Record<string, unknown>;
    const hasGrams = typeof data.grams_per_unit === "number" && data.grams_per_unit > 0;
    if (!hasGrams) {
      const label = typeof data.label === "string" && data.label.trim().length > 0
        ? data.label.trim()
        : snap.id.replace(/_/g, " ");
      unitsNeedingEnrichment.push({ canonical: snap.id, label });
    }
  }

  if (unitsNeedingEnrichment.length === 0) return;

  const unitList = unitsNeedingEnrichment.map((u) => `- ${u.label}`).join("\n");
  const unitWeightPrompt = buildUnitWeightPrompt(unitList);

  try {
    void logInfo({
      message: `enrichUnknownUnitsWithAI: enrichissement de ${unitsNeedingEnrichment.length} unité(s) inconnue(s)`,
      extra: { recipeId: args.recipeId, units: unitsNeedingEnrichment.map((u) => u.label), prompt: unitWeightPrompt },
    });

    const geminiResult = await callGemini(
      args.geminiApiKey,
      [textPart(unitWeightPrompt)],
      {
        correlationId: `enrich-units-${args.recipeId ?? Date.now()}`,
        feature: "enrich_unit_weights",
        userId: args.userId ?? "system",
        moduleType: "DESIGN",
        timeoutMs: 20_000,
      },
    );

    await recordTokenUsage(geminiResult, "enrich_unit_weights", args.userId ?? "system");

    const raw = (geminiResult.response.text() ?? "").trim();
    void logInfo({
      message: "enrichUnknownUnitsWithAI: réponse brute Gemini",
      extra: { recipeId: args.recipeId, rawResponse: raw.slice(0, 600) },
    });
    const jsonMatch = raw.match(/\[[\s\S]*?\]/);
    if (!jsonMatch) return;

    const parsed: unknown = JSON.parse(jsonMatch[0]);
    if (!Array.isArray(parsed)) return;

    for (const item of parsed) {
      if (!item || typeof item !== "object") continue;
      const obj = item as Record<string, unknown>;
      const unitLabel = typeof obj.unit === "string" ? obj.unit.trim() : "";
      const gramsPerUnit = typeof obj.gramsPerUnit === "number" && obj.gramsPerUnit > 0 ? obj.gramsPerUnit : null;
      const volumeMl = typeof obj.volumeMl === "number" && obj.volumeMl > 0 ? obj.volumeMl : null;
      const measurementType = typeof obj.measurementType === "string" ? obj.measurementType : "weight";

      if (!unitLabel || !gramsPerUnit) continue;

      const match = unitsNeedingEnrichment.find((u) =>
        u.label.toLowerCase() === unitLabel.toLowerCase() ||
        u.canonical.toLowerCase() === unitLabel.toLowerCase().replace(/\s+/g, "_"),
      );
      if (!match) continue;

      await db.collection(COLL_NUTRITION_UNITS).doc(match.canonical).set({
        grams_per_unit: gramsPerUnit,
        ...(volumeMl != null ? { volume_ml_per_unit: volumeMl } : {}),
        measurement_type: measurementType,
        status: "ai_estimated",
        conversion_source: "ai_estimation",
        updated_at: FieldValue.serverTimestamp(),
      }, { merge: true });
    }
  } catch (err) {
    void logError({
      message: "enrichUnknownUnitsWithAI: échec (best-effort)",
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId: `enrich-units-${args.recipeId ?? "norecipe"}`,
    });
  }
}

export interface ComputedNutritionResult {
  recipeId: string;
  nutrition: Record<string, unknown>;
}

// ── Enrichissement IA des ingrédients sans per100g (appelé lors de la normalisation) ─

/**
 * Enrichit en IA les ingrédients sans données per100g détectés lors de la normalisation.
 * Traite en parallèle (limité à 5) pour rester dans le timeout de la function.
 * Best-effort : ne bloque jamais la normalisation en cas d'échec.
 * Retourne true si au moins un ingrédient a été enrichi.
 */
async function enrichUnknownIngredientsWithAI(args: {
  ingredientRefIds: string[];
  geminiApiKey: string;
  userId?: string;
  recipeId?: string;
}): Promise<boolean> {
  if (args.ingredientRefIds.length === 0) return false;

  const db = getFirestore();
  const refs = args.ingredientRefIds.map((id) => db.collection("nutrition_ingredients").doc(id));
  const snaps = await db.getAll(...refs);

  const toEnrich: Array<{ id: string; canonicalName: string; aliases: string[] }> = [];
  for (const snap of snaps) {
    if (!snap.exists) continue;
    const data = snap.data() as Record<string, unknown>;
    if (hasPer100gValues(data.per100g)) continue; // déjà enrichi
    const canonicalName = typeof data.canonical_name === "string" && data.canonical_name.trim()
      ? data.canonical_name.trim()
      : snap.id.replace(/_/g, " ");
    const aliases = Array.isArray(data.aliases)
      ? (data.aliases as unknown[]).filter((v): v is string => typeof v === "string")
      : [];
    toEnrich.push({ id: snap.id, canonicalName, aliases });
  }

  if (toEnrich.length === 0) return false;

  // Limite à 5 ingrédients par appel pour rester dans le timeout
  const batch = toEnrich.slice(0, 5);

  void logInfo({
    message: `enrichUnknownIngredientsWithAI: enrichissement de ${batch.length} ingrédient(s) sans per100g`,
    extra: { recipeId: args.recipeId, ingredients: batch.map((i) => i.id) },
  });

  const results = await Promise.allSettled(batch.map(async (ingredient) => {
    const per100g = await estimatePer100gWithGemini({
      apiKey: args.geminiApiKey,
      ingredientId: ingredient.id,
      canonicalName: ingredient.canonicalName,
      aliases: ingredient.aliases,
      correlationId: `enrich-ing-${ingredient.id}-${args.recipeId ?? Date.now()}`,
      userId: args.userId ?? "system",
      feature: "inline_ingredient_per100g_enrichment",
    });
    if (Object.keys(per100g).length === 0) {
      void logInfo({
        message: `enrichUnknownIngredientsWithAI: per100g vide pour "${ingredient.id}" (aucune écriture)`,
        extra: { recipeId: args.recipeId, ingredientId: ingredient.id },
      });
      return false; // aucune écriture Firestore
    }
    await db.collection("nutrition_ingredients").doc(ingredient.id).set({
      per100g,
      source: "gemini_estimated",
      quality_status: "pending_review",
      updated_at: FieldValue.serverTimestamp(),
    }, { merge: true });
    return true; // écriture réussie
  }));

  let enrichedCount = 0;
  for (const result of results) {
    if (result.status === "fulfilled" && result.value === true) {
      enrichedCount++;
    } else if (result.status === "rejected") {
      void logError({
        message: "enrichUnknownIngredientsWithAI: échec sur un ingrédient (best-effort)",
        errorDescription: result.reason instanceof Error ? result.reason.message : String(result.reason),
        correlationId: `enrich-ing-${args.recipeId ?? "norecipe"}`,
      });
    }
  }

  return enrichedCount > 0;
}

export async function computeAndPersistRecipeNutrition(args: {
  recipeId: string;
  selectedPortions?: number;
}): Promise<ComputedNutritionResult> {
  const db = getFirestore();
  const recipeRef = db.collection(COLL_RECIPES).doc(args.recipeId);
  const recipeSnap = await recipeRef.get();
  if (!recipeSnap.exists) {
    throw new HttpsError("not-found", "Recette introuvable.");
  }

  const recipe = recipeSnap.data() as Record<string, unknown>;
  const rawIngredients = Array.isArray(recipe.ingredients) ? recipe.ingredients : [];
  const ingredients: IngredientInput[] = rawIngredients
    .filter((item): item is Record<string, unknown> => !!item && typeof item === "object")
    .map((item) => ({ name: item.name, qty: item.qty, unit: item.unit }));

  if (ingredients.length === 0) {
    const emptySnapshot = {
      selected_portions: asPositiveNumber(args.selectedPortions) ?? asPositiveNumber(recipe.portions) ?? 1,
      total_weight_g: 0,
      coverage: 0,
      coverage_state: "low",
      totals: {},
      per_portion: {},
      per_100g: null,
      quality: {
        score: 0,
        level: "C",
        warnings: ["Aucun ingrédient exploitable pour calculer la nutrition."],
      },
      missing_ingredients: [],
      policy_version: 0,
      computed_at: FieldValue.serverTimestamp(),
      fallback_policy: "none",
    };

    await recipeRef.set({ nutrition: emptySnapshot }, { merge: true });

    return {
      recipeId: args.recipeId,
      nutrition: {
        ...emptySnapshot,
        computed_at: new Date().toISOString(),
      },
    };
  }

  const selectedPortions = asPositiveNumber(args.selectedPortions) ??
    asPositiveNumber(recipe.portions) ??
    1;

  const policy = await getNutritionSourcePolicy();

  const totals: Record<string, number> = {};
  const missingIngredients: string[] = [];
  let totalWeightGrams = 0;
  let convertibleCount = 0;
  let mappedCount = 0;

  // Pré-charge depuis nutrition_units les facteurs de conversion pour toutes les unités
  // présentes dans la recette. Le référentiel Firestore prend la priorité sur la table
  // statique, ce qui permet de mettre à jour les poids botaniques sans redéploiement.
  const referentialUnitFactors = new Map<string, number>();
  {
    const unitsToFetch = new Set<string>();
    for (const ingredient of ingredients) {
      const unitStr = typeof ingredient.unit === "string" ? ingredient.unit.trim() : "";
      if (!unitStr) continue;
      const normalized = normalizeObservedUnit(unitStr);
      if (normalized) unitsToFetch.add(normalized);
    }
    if (unitsToFetch.size > 0) {
      const refs = [...unitsToFetch].map((u) => db.collection(COLL_NUTRITION_UNITS).doc(u));
      const unitSnaps = await db.getAll(...refs);
      for (const snap of unitSnaps) {
        if (!snap.exists) continue;
        const data = snap.data() as Record<string, unknown>;
        const g = typeof data.grams_per_unit === "number" && data.grams_per_unit > 0
          ? data.grams_per_unit
          : null;
        if (g != null) referentialUnitFactors.set(snap.id, g);
      }
    }
  }

  const resolutions: IngredientResolution[] = [];
  const uniqueLookupIds = new Set<string>();

  for (const ingredient of ingredients) {
    const name = typeof ingredient.name === "string" ? ingredient.name.trim() : "";
    if (!name) continue;

    const qty = asPositiveNumber(ingredient.qty);
    const unitStr = typeof ingredient.unit === "string" ? ingredient.unit.trim() : "";
    let factor = unitFactorToGrams(unitStr, name);
    // Priorité Firestore : si le référentiel a une valeur configurée, elle prend
    // le dessus sur la table statique (mise à jour sans redéploiement).
    if (unitStr) {
      const normalized = normalizeObservedUnit(unitStr);
      const referentialFactor = normalized ? (referentialUnitFactors.get(normalized) ?? null) : null;
      if (referentialFactor != null) factor = referentialFactor;
    }
    if (qty == null || factor == null) {
      missingIngredients.push(name);
      continue;
    }

    convertibleCount++;
    const weightGrams = qty * factor;
    totalWeightGrams += weightGrams;

    const lookupIds = buildIngredientLookupIds(name);
    if (lookupIds.length === 0) {
      missingIngredients.push(name);
      continue;
    }

    for (const lookupId of lookupIds) {
      uniqueLookupIds.add(lookupId);
    }
    resolutions.push({ name, weightGrams, lookupIds });
  }

  const normalizedProfilesById = new Map<string, Record<string, number>>();
  const docsToFetch = [...uniqueLookupIds].map((id) => db.collection("nutrition_ingredients").doc(id));

  for (let i = 0; i < docsToFetch.length; i += 300) {
    const chunk = docsToFetch.slice(i, i + 300);
    if (chunk.length === 0) continue;
    const snaps = await db.getAll(...chunk);
    for (const snap of snaps) {
      if (!snap.exists) continue;
      const profile = snap.data() as IngredientProfile;
      const normalized = normalizeNutrients(profile.per100g ?? {});
      if (Object.keys(normalized).length === 0) continue;
      normalizedProfilesById.set(snap.id, normalized);
    }
  }

  for (const resolution of resolutions) {
    let normalizedProfile: Record<string, number> | null = null;
    for (const profileId of resolution.lookupIds) {
      const candidate = normalizedProfilesById.get(profileId);
      if (!candidate) continue;
      normalizedProfile = candidate;
      break;
    }

    if (!normalizedProfile) {
      missingIngredients.push(resolution.name);
      continue;
    }

    mappedCount++;
    for (const key of NUTRIENT_KEYS) {
      const per100 = normalizedProfile[key] ?? 0;
      if (!Number.isFinite(per100) || per100 <= 0) continue;
      totals[key] = (totals[key] ?? 0) + (resolution.weightGrams * per100) / 100;
    }
  }

  const coverage = ingredients.length > 0 ? mappedCount / ingredients.length : 0;
  const canShowPer100g = coverage >= policy.quality_policy.minCoverageForPer100g && totalWeightGrams > 0;
  const canShowPartial = coverage >= policy.quality_policy.minCoverageForPartial;

  const perPortion: Record<string, number> = {};
  const per100g: Record<string, number> = {};
  for (const key of NUTRIENT_KEYS) {
    const total = totals[key] ?? 0;
    if (total <= 0) continue;
    perPortion[key] = roundValue(total / selectedPortions, key === "kcal" ? 0 : 2);
    if (canShowPer100g) {
      per100g[key] = roundValue((total / totalWeightGrams) * 100, key === "kcal" ? 0 : 2);
    }
    totals[key] = roundValue(total, key === "kcal" ? 0 : 2);
  }

  const kcal = totals.kcal ?? 0;
  const kcalTheory =
    ((totals.protein_g ?? 0) * 4) +
    ((totals.carbs_g ?? 0) * 4) +
    ((totals.fat_g ?? 0) * 9);
  const kcalDeltaPct = kcal > 0 ? Math.abs(kcal - kcalTheory) / kcal : 0;

  const qualityScore = Math.max(
    0,
    Math.min(
      100,
      Math.round((coverage * 60) + (Math.min(1, convertibleCount / Math.max(1, ingredients.length)) * 25) +
        (Math.max(0, 1 - (kcalDeltaPct / Math.max(0.01, policy.quality_policy.kcalConsistencyWarnDeltaPct))) * 15)),
    ),
  );

  const qualityLevel = qualityScore >= 80 ? "A" : (qualityScore >= 60 ? "B" : "C");
  const warnings: string[] = [];
  if (!canShowPartial) warnings.push("Couverture insuffisante pour une valeur partielle fiable.");
  if (!canShowPer100g) warnings.push("Vue pour 100 g masquée: couverture poids insuffisante.");
  if (kcalDeltaPct > policy.quality_policy.kcalConsistencyWarnDeltaPct) {
    warnings.push("Incohérence énergétique détectée entre kcal et macronutriments.");
  }

  const snapshot = {
    selected_portions: selectedPortions,
    total_weight_g: roundValue(totalWeightGrams, 1),
    coverage,
    coverage_state: canShowPer100g ? "full" : (canShowPartial ? "partial" : "low"),
    totals,
    per_portion: perPortion,
    per_100g: canShowPer100g ? per100g : null,
    quality: {
      score: qualityScore,
      level: qualityLevel,
      warnings,
    },
    missing_ingredients: missingIngredients,
    policy_version: policy.version,
    computed_at: FieldValue.serverTimestamp(),
    fallback_policy: policy.fallback_policy,
  };

  await recipeRef.set(
    {
      nutrition: snapshot,
    },
    { merge: true },
  );

  return {
    recipeId: args.recipeId,
    nutrition: {
      ...snapshot,
      computed_at: new Date().toISOString(),
    },
  };
}

export const getNutritionSourcePolicyFn = onCall(callableOpts, async (req) => {
  requireAuth(req);
  const policy = await getNutritionSourcePolicy();
  return { policy };
});

export const setNutritionSourcePolicyFn = onCall<SetNutritionPolicyRequest>(
  callableOpts,
  async (req) => {
    await requireAdmin(req);

    const next = req.data?.policy;
    if (!next) {
      throw new HttpsError("invalid-argument", "policy est requis.");
    }

    const merged: NutritionSourcePolicy = {
      ...DEFAULT_NUTRITION_POLICY,
      ...next,
      source_priority: next.source_priority ?? DEFAULT_NUTRITION_POLICY.source_priority,
      nutrient_aliases: next.nutrient_aliases ?? DEFAULT_NUTRITION_POLICY.nutrient_aliases,
      quality_policy: {
        ...DEFAULT_NUTRITION_POLICY.quality_policy,
        ...(next.quality_policy ?? {}),
      },
      version: typeof next.version === "number" ? next.version : Date.now(),
    };

    await getFirestore()
      .collection(COLL_APP_CONFIG)
      .doc(NUTRITION_POLICY_DOC_ID)
      .set({
        ...merged,
        updated_at: FieldValue.serverTimestamp(),
      }, { merge: true });

    return { policy: merged };
  },
);

export const normalizeNutrientsFn = onCall<NormalizeNutrientsRequest>(
  callableOpts,
  async (req) => {
    requireAuth(req);
    const nutrients = req.data?.nutrients;
    if (!nutrients || typeof nutrients !== "object") {
      throw new HttpsError("invalid-argument", "nutrients est requis.");
    }

    const normalized = normalizeNutrients(nutrients);
    return { normalized };
  },
);

export const computeRecipeNutritionFn = onCall<ComputeRecipeNutritionRequest>(
  { ...callableOpts, timeoutSeconds: 90 },
  async (req) => {
    requireAuth(req);
    const recipeId = req.data?.recipeId;
    if (!recipeId || typeof recipeId !== "string") {
      throw new HttpsError("invalid-argument", "recipeId est requis.");
    }
    try {
      return await computeAndPersistRecipeNutrition({
        recipeId,
        selectedPortions: req.data?.selectedPortions,
      });
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      await logError({
        message: "computeRecipeNutritionFn: ERREUR",
        errorDescription: message,
        correlationId: `compute-nutrition-${Date.now()}`,
        extra: {
          recipeId,
          uid: req.auth?.uid ?? null,
          selectedPortions: req.data?.selectedPortions ?? null,
        },
      });
      throw err;
    }
  },
);

export const normalizeRecipeReferentialsFn = onCall<NormalizeRecipeReferentialsRequest>(
  { ...callableOpts, timeoutSeconds: 120, secrets: [GEMINI_API_KEY], memory: "512MiB" as const },
  async (req) => {
    requireAuth(req);

    return normalizeRecipeReferentialsCore({
      recipeId: typeof req.data?.recipeId === "string" ? req.data.recipeId : undefined,
      cooklang: typeof req.data?.cooklang === "string" ? req.data.cooklang : "",
      ingredients: Array.isArray(req.data?.ingredients)
        ? req.data?.ingredients
        : undefined,
      geminiApiKey: GEMINI_API_KEY.value(),
      userId: req.auth?.uid ?? undefined,
    });
  },
);

export async function normalizeRecipeReferentialsCore(args: {
  recipeId?: string;
  cooklang: string;
  ingredients?: Array<Record<string, unknown>>;
  /** Clé API Gemini : active la passe IA de complétion des quantités manquantes. */
  geminiApiKey?: string;
  userId?: string;
}): Promise<NormalizeRecipeReferentialsResult> {
  const cooklang = args.cooklang;
  const recipeId = args.recipeId;
  const ingredientsInput = Array.isArray(args.ingredients)
    ? args.ingredients
    : extractIngredientsStructured(cooklang).map((i) => ({
      name: i.name,
      qty: i.qty,
      unit: i.unit,
      ...(i.category ? { category: i.category } : {}),
    }));

  // ── Pré-singularisation batch des unités via Gemini ─────────────────────────
  // Collecte toutes les unités brutes (y compris celles inférées depuis les noms via regex)
  // pour un unique appel Gemini — évite N appels individuels.
  const rawUnitsForSingularization = new Set<string>();
  for (const item of ingredientsInput) {
    if (!item || typeof item !== "object") continue;
    const obj = item as Record<string, unknown>;
    const rawUnit = typeof obj.unit === "string" ? obj.unit.trim() : "";
    const rawName = typeof obj.name === "string" ? obj.name.trim() : "";
    if (rawUnit) {
      rawUnitsForSingularization.add(rawUnit);
    } else if (rawName) {
      const inferred = inferUnitFromIngredientName({ rawName, rawUnit: "" });
      if (inferred.unit) rawUnitsForSingularization.add(inferred.unit);
    }
  }

  let unitSingularMap = new Map<string, string>();
  if (args.geminiApiKey && rawUnitsForSingularization.size > 0) {
    unitSingularMap = await singularizeFrenchUnitsWithGemini({
      units: [...rawUnitsForSingularization],
      geminiApiKey: args.geminiApiKey,
      recipeId,
      userId: args.userId,
    });
  } else {
    // Fallback purement algorithmique si pas de clé Gemini
    for (const u of rawUnitsForSingularization) {
      unitSingularMap.set(u, fallbackSingularize(u));
    }
  }

  const singularizeUnit = (unit: string): string =>
    unitSingularMap.get(unit) ??
    unitSingularMap.get(unit.trim().toLowerCase()) ??
    fallbackSingularize(unit);

  const resolvedIngredients: NormalizedRecipeIngredient[] = [];
  for (const item of ingredientsInput) {
    if (!item || typeof item !== "object") continue;
    const resolved = await resolveOneIngredient({
      item: item as Record<string, unknown>,
      recipeId,
      singularizeUnit,
    });
    if (resolved != null) resolvedIngredients.push(resolved);
  }

  // ── Déduplication : fusion des ingrédients ayant le même canonical_id ────────────
  // Cas typique : Gemini a extrait « @cerfeuil frais{} » ET « @brins de cerfeuil frais{} »
  // dans la même recette. Après split, les deux deviennent « cerfeuil frais » ;
  // on garde l'entrée la plus complète (avec unité ou qty en priorité).
  const deduplicatedIngredients: NormalizedRecipeIngredient[] = [];
  const seenByRefId = new Map<string, number>(); // ingredient_ref_id → index
  for (const ing of resolvedIngredients) {
    const key = ing.ingredient_ref_id || ing.name.toLowerCase();
    const existing = seenByRefId.get(key);
    if (existing === undefined) {
      seenByRefId.set(key, deduplicatedIngredients.length);
      deduplicatedIngredients.push(ing);
    } else {
      const prev = deduplicatedIngredients[existing];
      // Privilégie l'entrée la plus informative (unité > pas d'unité, qty > pas de qty)
      const ingScore = (ing.unit ? 2 : 0) + (ing.qty ? 1 : 0);
      const prevScore = (prev.unit ? 2 : 0) + (prev.qty ? 1 : 0);
      if (ingScore > prevScore) {
        deduplicatedIngredients[existing] = { ...ing, qty: ing.qty || prev.qty };
      } else {
        deduplicatedIngredients[existing] = { ...prev, qty: prev.qty || ing.qty };
      }
    }
  }
  // Remplacement de resolvedIngredients par la version dédupliquée pour le reste du pipeline
  resolvedIngredients.length = 0;
  resolvedIngredients.push(...deduplicatedIngredients);

  // ── Enrichissement IA des nouvelles unités sans poids ────────────────────────
  // Appelé inline pour que chaque nouvelle unité (zeste, tige…) reçoive
  // immédiatement son poids/volume, sans attendre un backfill admin.
  if (args.geminiApiKey) {
    const unitCanonicalsToEnrich = [...new Set(
      resolvedIngredients
        .map((i) => i.unit_canonical)
        .filter((u): u is string => !!u),
    )];
    if (unitCanonicalsToEnrich.length > 0) {
      await enrichUnknownUnitsWithAI({
        unitCanonicals: unitCanonicalsToEnrich,
        geminiApiKey: args.geminiApiKey,
        userId: args.userId,
        recipeId,
      });
    }
  }

  // ── Enrichissement IA des ingrédients sans per100g ───────────────────────────
  // Appelé inline pour que chaque nouvel ingrédient reçoive immédiatement ses
  // valeurs nutritionnelles, sans attendre un backfill admin.
  let nutritionRecomputeNeeded = false;
  if (args.geminiApiKey) {
    const ingredientRefIds = [
      ...new Set(
        resolvedIngredients
          .map((i) => i.ingredient_ref_id)
          .filter((id): id is string => !!id),
      ),
    ];
    if (ingredientRefIds.length > 0) {
      const enriched = await enrichUnknownIngredientsWithAI({
        ingredientRefIds,
        geminiApiKey: args.geminiApiKey,
        userId: args.userId,
        recipeId,
      });
      if (enriched && recipeId) {
        nutritionRecomputeNeeded = true;
      }
    }
  }

  // ── Passe IA : complétion automatique des quantités manquantes ──────────────
  let aiCompletedIngredients = 0;
  const qtyOverrides = new Map<string, { qty: string; unit: string }>();
  if (args.geminiApiKey) {
    const incomplete = resolvedIngredients.filter((i) => !i.qty.trim());
    if (incomplete.length > 0) {
      void logInfo({
        message: `normalizeRecipeReferentialsCore: passe IA démarrée (${incomplete.length} ingrédients sans qty)`,
        extra: { recipeId, cooklangLen: cooklang.length, ingredients: incomplete.map((i) => i.name) },
      });
      const suggestions = await completeIngredientQuantitiesWithAI({
        cooklang,
        incompleteIngredients: incomplete.map((i) => ({ name: i.name, unit: i.unit })),
        recipeId,
        geminiApiKey: args.geminiApiKey,
        userId: args.userId,
      });
      for (const ing of resolvedIngredients) {
        if (ing.qty.trim()) continue;
        // Matching canonique pour résister aux légères variations de nom retounées par l'IA
        const ingId = normalizeIngredientCanonicalId(ing.name) ?? ing.name.toLowerCase();
        const suggestion = [...suggestions.entries()].find(([key]) => {
          const keyId = normalizeIngredientCanonicalId(key) ?? key.toLowerCase();
          return keyId === ingId || key === ing.name.toLowerCase();
        })?.[1];
        if (!suggestion) {
          void logInfo({
            message: `normalizeRecipeReferentialsCore: pas de suggestion IA pour "${ing.name}"`,
            extra: { recipeId, ingId, availableKeys: [...suggestions.keys()] },
          });
          continue;
        }
        ing.qty = suggestion.qty;
        if (!ing.unit.trim() && suggestion.unit) {
          ing.unit = suggestion.unit;
          ing.unit_raw = suggestion.unit;
          ing.unit_resolution_source = "ai_completion";
          ing.unit_resolution_confidence = 0.7;
        }
        aiCompletedIngredients++;
        void logInfo({
          message: `normalizeRecipeReferentialsCore: suggestion appliquée pour "${ing.name}"`,
          extra: { recipeId, qty: ing.qty, unit: ing.unit },
        });
        qtyOverrides.set(ing.name.toLowerCase(), { qty: ing.qty, unit: ing.unit });
      }
      // Enrichit nutrition_units avec le poids estimé par l'IA pour les nouvelles unités
      const db = getFirestore();
      for (const [, suggestion] of suggestions) {
        if (!suggestion.unit || suggestion.gramsPerUnit == null) continue;
        await upsertNutritionUnitReference({
          db,
          unitRaw: suggestion.unit,
          gramsPerUnitEstimate: suggestion.gramsPerUnit,
          recipeId,
        });
      }
    }
  }

  // ── Log résumé final de tous les ingrédients après toutes les passes ───────────────
  void logInfo({
    message: `normalizeRecipeReferentialsCore: état final des ${resolvedIngredients.length} ingrédient(s)`,
    extra: {
      recipeId,
      aiCompletedIngredients,
      ingredients: resolvedIngredients.map((i) => ({
        name: i.name,
        qty: i.qty || "(vide)",
        unit: i.unit || "(vide)",
        unit_source: i.unit_resolution_source,
        ref_status: i.ingredient_ref_status,
      })),
    },
  });

  const rewrittenCooklang = cooklang
    ? await rewriteCooklangWithReferentials({
        cooklang,
        recipeId,
        qtyOverrides: qtyOverrides.size > 0 ? qtyOverrides : undefined,
        singularizeUnit,
      })
    : "";

  const originalItems = ingredientsInput
    .filter((item): item is Record<string, unknown> => !!item && typeof item === "object")
    .map((item) => ({
      name: typeof item.name === "string" ? item.name.trim() : "",
      unit: typeof item.unit === "string" ? item.unit.trim() : "",
    }));

  const comparedCount = Math.min(originalItems.length, resolvedIngredients.length);
  let renamedUnits = 0;
  let renamedIngredients = 0;
  for (let i = 0; i < comparedCount; i++) {
    if (
      originalItems[i].unit.length > 0 &&
      resolvedIngredients[i].unit.length > 0 &&
      originalItems[i].unit.toLowerCase() !== resolvedIngredients[i].unit.toLowerCase()
    ) {
      renamedUnits++;
    }
    if (
      originalItems[i].name.length > 0 &&
      resolvedIngredients[i].name.length > 0 &&
      originalItems[i].name.toLowerCase() !== resolvedIngredients[i].name.toLowerCase()
    ) {
      renamedIngredients++;
    }
  }

  const result = {
    rewrittenCooklang,
    resolvedIngredients: resolvedIngredients.map((i) => ({ ...i })),
    stats: {
      totalIngredients: resolvedIngredients.length,
      unitsResolved: resolvedIngredients.filter((i) => i.unit_canonical.length > 0).length,
      ingredientsKnown: resolvedIngredients.filter((i) => i.ingredient_ref_status === "known").length,
      ingredientsProposed: resolvedIngredients.filter((i) => i.ingredient_ref_status === "proposed").length,
      renamedUnits,
      renamedIngredients,
      aiCompletedIngredients,
    },
  };

  // ── Recompute nutrition si de nouveaux per100g ont été enrichis ─────────────
  // IMPORTANT : await synchrone (pas void) — garantit l'exécution complète
  // avant que Cloud Run ne termine le container.
  if (nutritionRecomputeNeeded && recipeId) {
    try {
      await computeAndPersistRecipeNutrition({ recipeId });
      void logInfo({
        message: `normalizeRecipeReferentialsCore: nutrition recomputée après enrichissement per100g`,
        extra: { recipeId },
      });
    } catch (err) {
      void logError({
        message: "normalizeRecipeReferentialsCore: échec recompute nutrition post-enrichissement (best-effort)",
        errorDescription: err instanceof Error ? err.message : String(err),
        correlationId: `recompute-${recipeId}`,
      });
    }
  }

  return result;
}
