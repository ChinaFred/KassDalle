/**
 * Enrichissement par IA du référentiel nutritionnel.
 *
 * Regroupe les appels Gemini de la chaîne nutrition et leurs prompts :
 * singularisation des unités, complétion des quantités manquantes, estimation
 * du poids d'une unité inconnue, estimation des valeurs per100g d'un ingrédient
 * absent du référentiel.
 *
 * Extrait de callable/nutritionCallable.ts.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";

import { COLL_NUTRITION_UNITS } from "../config";
import { logError, logInfo } from "../logging";
import { callGemini, textPart } from "../gemini/client";
import { recordTokenUsage } from "../gemini/tokenUsage";
import { estimatePer100gWithGemini, hasPer100gValues } from "./per100gEnrichment";
import { fallbackSingularize } from "./unitDisplay";

// ── Singularisation des unités culinaires ────────────────────────────────────
// La singularisation (brins → brin) est déléguée à Gemini par un appel batch
// unique par recette, avec repli algorithmique (`fallbackSingularize`) si
// Gemini est indisponible.

/**
 * Singularise les unités culinaires françaises via Gemini — appel batch unique par recette.
 * Toutes les unités potentiellement plurielles (terminaison -s) sont envoyées en un seul
 * appel ; les résultats sont loggés et les coûts tracés via recordTokenUsage.
 * Retourne une Map {forme_brute → singulier_lowercase}.
 * En cas d'échec Gemini, le fallback algorithmique (strip 's') est conservé.
 */
export async function singularizeFrenchUnitsWithGemini(args: {
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

    const raw = (geminiResult.text ?? "").trim();
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

// ── Complétion IA des quantités manquantes ────────────────────────────────────

export function buildCompleteQuantitiesPrompt(cooklang: string, ingredientList: string): string {
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
export async function completeIngredientQuantitiesWithAI(args: {
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

    const raw = (geminiResult.text ?? "").trim();
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
// ── Enrichissement IA des unités sans poids (appelé lors de la normalisation) ─────────

export function buildUnitWeightPrompt(
  units: Array<{ label: string; ingredients: string[] }>,
): string {
  const unitList = units
    .map((u) => {
      const ctx = u.ingredients.length > 0
        ? ` (utilisée pour : ${u.ingredients.slice(0, 5).join(", ")})`
        : "";
      return `- ${u.label}${ctx}`;
    })
    .join("\n");

  return `Tu es un expert en mesures culinaires. Pour chaque unité ci-dessous, estime OBLIGATOIREMENT :
- gramsPerUnit : le poids moyen en grammes pour 1 unité — TOUJOURS un nombre strictement positif, JAMAIS null ni 0.
- volumeMl : le volume en millilitres si c'est une unité de volume liquide (sinon null).
- measurementType : "weight" (solide/comptable) ou "volume" (liquide).

Règles impératives :
- Même si l'unité est vague ou imprécise (poignée, brin, petit, gros, pincée, filet, noix, tranche, morceau…), donne TOUJOURS une estimation moyenne raisonnable fondée sur l'usage culinaire courant.
- Ne réponds JAMAIS 0 ni null pour gramsPerUnit : choisis la meilleure moyenne plausible.
- Tiens compte de l'ingrédient associé quand il est indiqué entre parenthèses : le poids d'une même unité varie selon l'ingrédient (ex. une poignée de cacahuètes ≈ 30 g, une poignée de roquette ≈ 20 g, un brin de menthe ≈ 1 g, un brin de thym ≈ 0,5 g).

Unités à évaluer :
${unitList}

Exemples de référence :
- poignée (cacahuètes) : gramsPerUnit=30, volumeMl=null, measurementType=weight
- poignée (herbes/salade) : gramsPerUnit=20, volumeMl=null, measurementType=weight
- brin (herbe fraîche, ex. menthe) : gramsPerUnit=1.5, volumeMl=null, measurementType=weight
- petit (légume, ex. concombre) : gramsPerUnit=150, volumeMl=null, measurementType=weight
- pincée : gramsPerUnit=0.5, volumeMl=null, measurementType=weight
- filet (huile) : gramsPerUnit=5, volumeMl=5, measurementType=volume
- tige (citronnelle) : gramsPerUnit=20, volumeMl=null, measurementType=weight
- zeste (citron) : gramsPerUnit=3, volumeMl=null, measurementType=weight

Retourne UNIQUEMENT un tableau JSON valide (sans texte additionnel) :
[{"unit":"<nom exact tel que fourni>","gramsPerUnit":<nombre strictement positif>,"volumeMl":<nombre ou null>,"measurementType":"weight"|"volume"}]`;
}

/**
 * Enrichit en IA les unités sans poids détectées lors de la normalisation.
 * Best-effort : ne bloque jamais la normalisation en cas d'échec.
 */
export async function enrichUnknownUnitsWithAI(args: {
  unitCanonicals: string[];
  geminiApiKey: string;
  userId?: string;
  recipeId?: string;
  /** Contexte : noms d'ingrédients associés à chaque unité canonique (améliore l'estimation). */
  unitIngredientNames?: Map<string, string[]>;
}): Promise<void> {
  if (args.unitCanonicals.length === 0) return;

  const db = getFirestore();
  const refs = args.unitCanonicals.map((u) => db.collection(COLL_NUTRITION_UNITS).doc(u));
  const snaps = await db.getAll(...refs);

  const unitsNeedingEnrichment: Array<{ canonical: string; label: string; ingredients: string[] }> = [];
  for (const snap of snaps) {
    if (!snap.exists) continue;
    const data = snap.data() as Record<string, unknown>;
    const hasGrams = typeof data.grams_per_unit === "number" && data.grams_per_unit > 0;
    if (!hasGrams) {
      const label = typeof data.label === "string" && data.label.trim().length > 0
        ? data.label.trim()
        : snap.id.replace(/_/g, " ");
      // Contexte ingrédients : priorité au contexte de la recette courante,
      // complété par les échantillons déjà observés sur le référentiel unité.
      const fromRecipe = args.unitIngredientNames?.get(snap.id) ?? [];
      const fromDoc = Array.isArray(data.sample_ingredient_names)
        ? (data.sample_ingredient_names as unknown[]).filter((v): v is string => typeof v === "string")
        : [];
      const ingredients = [...new Set([...fromRecipe, ...fromDoc])].slice(0, 5);
      unitsNeedingEnrichment.push({ canonical: snap.id, label, ingredients });
    }
  }

  if (unitsNeedingEnrichment.length === 0) return;

  const unitWeightPrompt = buildUnitWeightPrompt(unitsNeedingEnrichment);

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

    const raw = (geminiResult.text ?? "").trim();
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

// ── Enrichissement IA des ingrédients sans per100g (appelé lors de la normalisation) ─

/**
 * Enrichit en IA les ingrédients sans données per100g détectés lors de la normalisation.
 * Traite en parallèle (limité à 5) pour rester dans le timeout de la function.
 * Best-effort : ne bloque jamais la normalisation en cas d'échec.
 * Retourne true si au moins un ingrédient a été enrichi.
 */
export async function enrichUnknownIngredientsWithAI(args: {
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
