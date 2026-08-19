/**
 * Enrichissement par IA du référentiel nutritionnel.
 *
 * Regroupe les appels d'IA de la chaîne nutrition et leurs prompts :
 * singularisation des unités, complétion des quantités manquantes, estimation
 * du poids d'une unité inconnue, estimation des valeurs per100g d'un ingrédient
 * absent du référentiel.
 *
 * Extrait de callable/nutritionCallable.ts.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";

import { COLL_NUTRITION_INGREDIENTS, COLL_NUTRITION_UNITS } from "../config";
import { logDebug, logError, logInfo } from "../logging";
import { askJson } from "../ai/askJson";
import { callModel } from "../ai/router";
import { textPart } from "../ai/types";
import { readDocsByIds, writeDocsMerged } from "./firestoreBatch";
import { depluralizeToken, normalizeIngredientCanonicalId } from "./ingredientName";
import {
  AI_PER100G_MARKERS,
  estimatePer100gForTargets,
  hasPer100gValues,
  type Per100gEnrichmentTarget,
} from "./per100gEnrichment";
import { normalizeObservedUnit } from "./quantityConversion";
import { fallbackSingularize } from "./unitDisplay";

// ── Singularisation des unités culinaires ────────────────────────────────────
// La singularisation (brins → brin) est déléguée à l'IA par un appel batch
// unique par recette, avec repli algorithmique (`fallbackSingularize`) si le
// moteur est indisponible.

/**
 * Singularise les unités culinaires françaises — appel batch unique par recette.
 * Toutes les unités potentiellement plurielles (terminaison -s) sont envoyées en un seul
 * appel ; le moteur est choisi par la politique de routage et le coût imputé au
 * poste `singularize_units`.
 * Retourne une Map {forme_brute → singulier_lowercase}.
 * En cas d'échec du moteur, le fallback algorithmique (strip 's') est conservé.
 */
export async function singularizeFrenchUnitsWithAI(args: {
  units: string[];
  recipeId?: string;
  /** Fil du traitement appelant : import, declencheur, ecran. */
  correlationId?: string;
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
    message: `singularizeFrenchUnitsWithAI: ${potentialPlurals.length} unité(s) à singulariser`,
    extra: { recipeId: args.recipeId, units: potentialPlurals },
  });

  try {
    void logDebug({
      message: "singularizeFrenchUnitsWithAI: prompt envoyé au moteur",
      extra: { recipeId: args.recipeId, potentialPlurals, prompt },
    });

    const modelResult = await callModel({
      parts: [textPart(prompt)],
      ctx: {
        correlationId: args.correlationId ?? `singularize-units-${args.recipeId ?? Date.now()}`,
        feature: "singularize_units",
        userId: args.userId ?? "system",
        moduleType: "DESIGN",
        timeoutMs: 10_000,
      },
    });

    const raw = modelResult.text.trim();
    void logDebug({
      message: "singularizeFrenchUnitsWithAI: réponse brute du moteur",
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
      message: "singularizeFrenchUnitsWithAI: échec (best-effort, fallback algorithmique appliqué)",
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId: args.correlationId ?? `singularize-units-${args.recipeId ?? "norecipe"}`,
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
  /** Fil du traitement appelant : import, declencheur, ecran. */
  correlationId?: string;
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

    const modelResult = await callModel({
      parts: [textPart(prompt)],
      ctx: {
        correlationId: args.correlationId ?? `complete-qty-${args.recipeId ?? Date.now()}`,
        feature: "complete_ingredient_quantities",
        userId: args.userId ?? "system",
        moduleType: "DESIGN",
        timeoutMs: 30_000,
      },
    });

    const raw = modelResult.text.trim();
    void logDebug({
      message: "completeIngredientQuantitiesWithAI: réponse brute du moteur",
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
      const gramsPerUnit =
        typeof obj.gramsPerUnit === "number" && obj.gramsPerUnit > 0 ? obj.gramsPerUnit : undefined;
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
      correlationId: args.correlationId ?? `complete-qty-${args.recipeId ?? "norecipe"}`,
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

/**
 * Construit la demande d'estimation des poids d'unités.
 *
 * Le contexte ingrédient est un champ **séparé** du libellé, et chaque unité
 * porte un identifiant que la réponse doit reprendre. La version précédente
 * collait le contexte au libellé — « cuiller à soupe (utilisée pour : farine,
 * céleri…) » — puis réclamait « le nom exact tel que fourni » : le modèle
 * obéissait à la lettre et renvoyait la parenthèse avec, si bien qu'aucune
 * réponse ne se rapprochait plus de l'unité demandée. Plus le contexte était
 * riche, plus l'échec était certain.
 */
export function buildUnitWeightPrompt(
  units: Array<{ canonical?: string; label: string; ingredients: string[] }>,
): string {
  const unitList = units
    .map((u, index) => {
      const id = u.canonical ?? `u${index + 1}`;
      const ctx =
        u.ingredients.length > 0 ? `\n  contexte : ${u.ingredients.slice(0, 5).join(", ")}` : "";
      return `- id: ${id}\n  unité : ${u.label}${ctx}`;
    })
    .join("\n");

  return `Tu es un expert en mesures culinaires. Pour chaque unité ci-dessous, estime OBLIGATOIREMENT :
- gramsPerUnit : le poids moyen en grammes pour 1 unité — TOUJOURS un nombre strictement positif, JAMAIS null ni 0.
- volumeMl : le volume en millilitres si c'est une unité de volume liquide (sinon null).
- measurementType : "weight" (solide/comptable) ou "volume" (liquide).

Règles impératives :
- Même si l'unité est vague ou imprécise (poignée, brin, petit, gros, pincée, filet, noix, tranche, morceau…), donne TOUJOURS une estimation moyenne raisonnable fondée sur l'usage culinaire courant.
- Ne réponds JAMAIS 0 ni null pour gramsPerUnit : choisis la meilleure moyenne plausible.
- Tiens compte des ingrédients donnés en contexte : le poids d'une même unité varie selon l'ingrédient (ex. une poignée de cacahuètes ≈ 30 g, une poignée de roquette ≈ 20 g, un brin de menthe ≈ 1 g, un brin de thym ≈ 0,5 g). Le contexte oriente l'estimation, il ne fait jamais partie du nom de l'unité.

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

Retourne UNIQUEMENT un tableau JSON valide (sans texte additionnel), une entrée par
identifiant fourni, en reprenant l'identifiant CARACTÈRE POUR CARACTÈRE :
[{"id":"<id fourni ci-dessus>","gramsPerUnit":<nombre strictement positif>,"volumeMl":<nombre ou null>,"measurementType":"weight"|"volume"}]`;
}

/**
 * Clés sous lesquelles une graphie d'unité peut être reconnue : sa forme
 * normalisée, et la même dépluralisée mot à mot.
 *
 * Rapprocher deux graphies d'unité par égalité de chaîne, c'est perdre à chaque
 * différence de nombre — et la recette écrit le pluriel là où l'IA répond le
 * singulier, presque toujours.
 */
export function unitMatchKeys(value: string): string[] {
  const normalized = normalizeObservedUnit(value);
  if (!normalized) return [];
  const singular = normalized.split("_").map(depluralizeToken).join("_");
  return singular === normalized ? [normalized] : [normalized, singular];
}

/**
 * Retire le contexte parenthésé d'un libellé d'unité.
 *
 * Filet de sécurité du rapprochement : le prompt sépare désormais le contexte du
 * nom, mais un modèle reste libre de recoller les deux. Sans ce nettoyage, une
 * estimation par ailleurs correcte est jetée pour un motif purement typographique.
 */
export function stripUnitContext(value: string): string {
  const stripped = value.replace(/\s*\([^)]*\)\s*$/, "").trim();
  return stripped.length > 0 ? stripped : value.trim();
}

/** Unité en attente d'un poids, telle qu'elle est envoyée à l'IA. */
interface UnitNeedingWeight {
  canonical: string;
  label: string;
  ingredients: string[];
}

/** Poids d'une unité tel que l'IA vient de l'estimer. */
interface EstimatedUnitWeight {
  gramsPerUnit: number;
  volumeMl: number | null;
  measurementType: string;
}

/**
 * Interroge Gemini pour un lot d'unités et rapproche les réponses des unités
 * demandées.
 *
 * Le rapprochement est la partie sensible : la version précédente n'acceptait
 * une réponse que si son libellé était identique, caractère pour caractère, à
 * celui envoyé. Une réponse correcte mais reformulée (« tranche fine » pour
 * « fine tranche », un pluriel, une majuscule) était écartée par un `continue`
 * muet — l'unité restait sans poids et rien ne le signalait. On rapproche
 * désormais sur l'unité normalisée, la même fonction qui sert d'identifiant au
 * référentiel.
 */
async function askUnitWeights(args: {
  units: UnitNeedingWeight[];
  userId?: string;
  recipeId?: string;
  /** Fil du traitement appelant : import, declencheur, ecran. */
  correlationId?: string;
  insist: boolean;
}): Promise<Map<string, EstimatedUnitWeight>> {
  const out = new Map<string, EstimatedUnitWeight>();
  if (args.units.length === 0) return out;

  const prompt = args.insist
    ? `${buildUnitWeightPrompt(args.units)}

ATTENTION : une première demande n'a rien donné d'exploitable pour ces unités.
Reprends l'identifiant EXACTEMENT tel qu'il est écrit ci-dessus — sans le contexte — et
donne pour chacune un poids moyen strictement positif. Aucune omission n'est acceptable.`
    : buildUnitWeightPrompt(args.units);

  void logInfo({
    message: `enrichUnknownUnitsWithAI: estimation de ${args.units.length} unité(s)${args.insist ? " (relance)" : ""}`,
    extra: { recipeId: args.recipeId, units: args.units.map((u) => u.label), prompt },
  });

  const modelResult = await callModel({
    parts: [textPart(prompt)],
    ctx: {
      correlationId: args.correlationId ?? `enrich-units-${args.recipeId ?? Date.now()}`,
      feature: "enrich_unit_weights",
      userId: args.userId ?? "system",
      moduleType: "DESIGN",
      timeoutMs: 30_000,
    },
  });

  const raw = modelResult.text.trim();
  void logDebug({
    message: "enrichUnknownUnitsWithAI: réponse brute du moteur",
    extra: { recipeId: args.recipeId, rawResponse: raw.slice(0, 600) },
  });
  const jsonMatch = raw.match(/\[[\s\S]*\]/);
  if (!jsonMatch) return out;

  const parsed: unknown = JSON.parse(jsonMatch[0]);
  if (!Array.isArray(parsed)) return out;

  // Index des unités demandées, par forme normalisée, par libellé normalisé et
  // par forme singularisée : le référentiel indexe sur la première, l'IA répond
  // volontiers avec le second, et presque toujours au singulier là où la recette
  // écrivait un pluriel (« cuillerées à soupe » → « cuillerée à soupe »).
  const byNormalized = new Map<string, UnitNeedingWeight>();
  const byId = new Map<string, UnitNeedingWeight>();
  for (const unit of args.units) {
    byId.set(unit.canonical, unit);
    for (const key of unitMatchKeys(unit.canonical)) byNormalized.set(key, unit);
    for (const key of unitMatchKeys(unit.label)) byNormalized.set(key, unit);
  }

  for (const item of parsed) {
    if (!item || typeof item !== "object") continue;
    const obj = item as Record<string, unknown>;
    // `id` est le chemin nominal depuis que le prompt en fournit un ; `unit`
    // reste accepté pour les réponses qui ignorent l'identifiant.
    const unitId = typeof obj.id === "string" ? obj.id.trim() : "";
    const unitLabel = typeof obj.unit === "string" ? obj.unit.trim() : "";
    const gramsPerUnit =
      typeof obj.gramsPerUnit === "number" && obj.gramsPerUnit > 0 ? obj.gramsPerUnit : null;
    const volumeMl = typeof obj.volumeMl === "number" && obj.volumeMl > 0 ? obj.volumeMl : null;
    const measurementType =
      typeof obj.measurementType === "string" ? obj.measurementType : "weight";

    const answered = unitId || unitLabel;
    if (!answered || !gramsPerUnit) continue;

    // Trois passes, de la plus sûre à la plus tolérante : identifiant exact,
    // puis libellé normalisé, puis libellé débarrassé de son contexte.
    const match =
      byId.get(unitId) ??
      [answered, stripUnitContext(answered)]
        .flatMap((candidate) => unitMatchKeys(candidate))
        .map((key) => byNormalized.get(key))
        .find((candidate) => candidate != null);
    if (!match) {
      void logError({
        message: `enrichUnknownUnitsWithAI: réponse "${answered}" sans unité demandée correspondante`,
        errorDescription: "Libellé retourné par Gemini non rapprochable — estimation perdue",
        correlationId: args.correlationId ?? `enrich-units-${args.recipeId ?? "norecipe"}`,
        extra: { recipeId: args.recipeId, demandees: args.units.map((u) => u.label) },
      });
      continue;
    }

    out.set(match.canonical, { gramsPerUnit, volumeMl, measurementType });
  }

  return out;
}

/**
 * Enrichit en IA les unités sans poids détectées lors de la normalisation.
 *
 * Une unité sans poids retire l'ingrédient du calcul nutritionnel : on relance
 * donc une fois sur celles que le premier appel n'a pas couvertes, et celles qui
 * résistent partent en erreur — visibles, plutôt que silencieusement absentes.
 *
 * Best-effort : ne bloque jamais la normalisation en cas d'échec.
 */
export async function enrichUnknownUnitsWithAI(args: {
  unitCanonicals: string[];
  userId?: string;
  recipeId?: string;
  /** Fil du traitement appelant : import, declencheur, ecran. */
  correlationId?: string;
  /** Contexte : noms d'ingrédients associés à chaque unité canonique (améliore l'estimation). */
  unitIngredientNames?: Map<string, string[]>;
}): Promise<void> {
  if (args.unitCanonicals.length === 0) return;

  const db = getFirestore();
  const refs = args.unitCanonicals.map((u) => db.collection(COLL_NUTRITION_UNITS).doc(u));
  const snaps = await db.getAll(...refs);

  const unitsNeedingEnrichment: UnitNeedingWeight[] = [];
  for (const snap of snaps) {
    if (!snap.exists) continue;
    const data = snap.data() as Record<string, unknown>;
    const hasGrams = typeof data.grams_per_unit === "number" && data.grams_per_unit > 0;
    if (!hasGrams) {
      const label =
        typeof data.label === "string" && data.label.trim().length > 0
          ? data.label.trim()
          : snap.id.replace(/_/g, " ");
      // Contexte ingrédients : priorité au contexte de la recette courante,
      // complété par les échantillons déjà observés sur le référentiel unité.
      const fromRecipe = args.unitIngredientNames?.get(snap.id) ?? [];
      const fromDoc = Array.isArray(data.sample_ingredient_names)
        ? (data.sample_ingredient_names as unknown[]).filter(
            (v): v is string => typeof v === "string",
          )
        : [];
      const ingredients = [...new Set([...fromRecipe, ...fromDoc])].slice(0, 5);
      unitsNeedingEnrichment.push({ canonical: snap.id, label, ingredients });
    }
  }

  if (unitsNeedingEnrichment.length === 0) return;

  const estimates = new Map<string, EstimatedUnitWeight>();
  try {
    const first = await askUnitWeights({
      units: unitsNeedingEnrichment,
      userId: args.userId,
      recipeId: args.recipeId,
      correlationId: args.correlationId,
      insist: false,
    });
    for (const [canonical, estimate] of first) estimates.set(canonical, estimate);

    // Relance ciblée : une unité sans poids fait sortir son ingrédient du calcul
    // nutritionnel. Un second essai coûte un appel et sauve la recette.
    const missing = unitsNeedingEnrichment.filter((u) => !estimates.has(u.canonical));
    if (missing.length > 0) {
      const second = await askUnitWeights({
        units: missing,
        userId: args.userId,
        recipeId: args.recipeId,
        correlationId: args.correlationId,
        insist: true,
      });
      for (const [canonical, estimate] of second) estimates.set(canonical, estimate);
    }
  } catch (err) {
    void logError({
      message: "enrichUnknownUnitsWithAI: échec (best-effort)",
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId: args.correlationId ?? `enrich-units-${args.recipeId ?? "norecipe"}`,
      extra: { recipeId: args.recipeId, units: unitsNeedingEnrichment.map((u) => u.label) },
    });
  }

  for (const [canonical, estimate] of estimates) {
    try {
      await db
        .collection(COLL_NUTRITION_UNITS)
        .doc(canonical)
        .set(
          {
            grams_per_unit: estimate.gramsPerUnit,
            ...(estimate.volumeMl != null ? { volume_ml_per_unit: estimate.volumeMl } : {}),
            measurement_type: estimate.measurementType,
            status: "ai_estimated",
            conversion_source: "ai_estimation",
            updated_at: FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
    } catch (err) {
      void logError({
        message: `enrichUnknownUnitsWithAI: écriture du poids échouée pour "${canonical}"`,
        errorDescription: err instanceof Error ? err.message : String(err),
        correlationId: args.correlationId ?? `enrich-units-${args.recipeId ?? "norecipe"}`,
      });
    }
  }

  const stillMissing = unitsNeedingEnrichment.filter((u) => !estimates.has(u.canonical));
  if (stillMissing.length > 0) {
    // Ces unités laisseront leurs ingrédients hors du calcul : c'est une anomalie
    // à corriger depuis l'écran d'administration, pas un silence acceptable.
    void logError({
      message: `enrichUnknownUnitsWithAI: ${stillMissing.length} unité(s) restée(s) sans poids`,
      errorDescription:
        "Aucune estimation exploitable après relance — ingrédients exclus du calcul",
      correlationId: args.correlationId ?? `enrich-units-${args.recipeId ?? "norecipe"}`,
      extra: {
        recipeId: args.recipeId,
        units: stillMissing.map((u) => ({ canonical: u.canonical, label: u.label })),
      },
    });
  }

  void logInfo({
    message: `enrichUnknownUnitsWithAI: ${estimates.size}/${unitsNeedingEnrichment.length} unité(s) enrichie(s)`,
    extra: { recipeId: args.recipeId, enriched: [...estimates.keys()] },
  });
}

// ── Enrichissement IA des ingrédients sans per100g (appelé lors de la normalisation) ─

/**
 * Enrichit en IA TOUS les ingrédients d'une recette qui n'ont pas de per100g.
 *
 * L'ancienne version s'arrêtait aux cinq premiers, parce qu'elle dépensait un
 * appel Gemini par ingrédient : au-delà, le timeout de la function était en jeu.
 * Le lot ayant remplacé l'appel unitaire (un appel pour vingt ingrédients), le
 * plafond n'a plus de raison d'être — une recette de quinze ingrédients neufs
 * repartait sinon avec dix ingrédients définitivement muets.
 *
 * Best-effort : ne bloque jamais la normalisation en cas d'échec.
 * Retourne le nombre d'ingrédients effectivement enrichis.
 */
export async function enrichUnknownIngredientsWithAI(args: {
  ingredientRefIds: string[];
  userId?: string;
  recipeId?: string;
  /** Fil du traitement appelant : import, declencheur, ecran. */
  correlationId?: string;
  /** Instant limite au-delà duquel on s'arrête proprement (défaut : aucun). */
  deadlineMs?: number;
}): Promise<number> {
  if (args.ingredientRefIds.length === 0) return 0;

  const db = getFirestore();
  const refs = args.ingredientRefIds.map((id) => db.collection("nutrition_ingredients").doc(id));
  const snaps = await db.getAll(...refs);

  const toEnrich: Per100gEnrichmentTarget[] = [];
  for (const snap of snaps) {
    if (!snap.exists) continue;
    const data = snap.data() as Record<string, unknown>;
    if (hasPer100gValues(data.per100g)) continue; // déjà enrichi
    const canonicalName =
      typeof data.canonical_name === "string" && data.canonical_name.trim()
        ? data.canonical_name.trim()
        : snap.id.replace(/_/g, " ");
    const aliases = Array.isArray(data.aliases)
      ? (data.aliases as unknown[]).filter((v): v is string => typeof v === "string")
      : [];
    toEnrich.push({ id: snap.id, canonicalName, aliases });
  }

  if (toEnrich.length === 0) return 0;

  void logInfo({
    message: `enrichUnknownIngredientsWithAI: enrichissement de ${toEnrich.length} ingrédient(s) sans per100g`,
    extra: { recipeId: args.recipeId, ingredients: toEnrich.map((i) => i.id) },
  });

  const estimated = await estimatePer100gForTargets({
    targets: toEnrich,
    correlationId: args.correlationId ?? `enrich-ing-${args.recipeId ?? "norecipe"}`,
    userId: args.userId ?? "system",
    feature: "inline_ingredient_per100g_enrichment",
    deadlineMs: args.deadlineMs,
  });

  // Marque les ingrédients restés sans valeur : l'écran d'administration peut
  // les lister et les corriger, au lieu de les laisser disparaître du calcul
  // sans que personne ne sache lesquels.
  const failed = toEnrich.filter((t) => !estimated.has(t.id));

  // Valeurs trouvées et marquages d'échec partent dans le même lot : deux
  // boucles d'écritures séquentielles deviennent un seul passage régulé.
  const updates = new Map<string, Record<string, unknown>>();
  for (const [ingredientId, per100g] of estimated) {
    updates.set(ingredientId, {
      per100g,
      ...AI_PER100G_MARKERS,
      last_enriched_at: FieldValue.serverTimestamp(),
      updated_at: FieldValue.serverTimestamp(),
    });
  }
  for (const target of failed) {
    updates.set(target.id, {
      quality_status: "estimation_failed",
      last_enrichment_attempt_at: FieldValue.serverTimestamp(),
      updated_at: FieldValue.serverTimestamp(),
    });
  }

  let enrichedCount = estimated.size;
  try {
    await writeDocsMerged(COLL_NUTRITION_INGREDIENTS, updates);
  } catch (err) {
    // Best-effort : l'échec d'écriture ne doit pas annuler le calcul, mais il
    // ne doit pas non plus être compté comme un enrichissement réussi.
    enrichedCount = 0;
    void logError({
      message: "enrichUnknownIngredientsWithAI: écriture groupée du référentiel échouée",
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId: args.correlationId ?? `enrich-ing-${args.recipeId ?? "norecipe"}`,
    });
  }
  if (failed.length > 0) {
    void logError({
      message: `enrichUnknownIngredientsWithAI: ${failed.length} ingrédient(s) sans valeur après relance`,
      errorDescription:
        "Aucune estimation plausible — ces ingrédients sortent du calcul nutritionnel",
      correlationId: args.correlationId ?? `enrich-ing-${args.recipeId ?? "norecipe"}`,
      extra: { recipeId: args.recipeId, ingredients: failed.map((t) => t.id) },
    });
  }

  return enrichedCount;
}

/**
 * Estime par IA le poids d'UNE pièce pour des ingrédients qui se comptent à
 * l'unité — un œuf, un jaune, une gousse de vanille, une échalote.
 *
 * Répond à la question que `enrichUnknownUnitsWithAI` ne pose pas : cet
 * ingrédient n'a AUCUNE unité, faut-il le compter à la pièce et combien pèse
 * cette pièce ? Le résultat est écrit sur l'ingrédient, pas sur une unité :
 * le poids d'un jaune appartient au jaune, pas à « pièce ».
 *
 * Les valeurs sont marquées `ai_estimated` pour être filtrables et corrigibles
 * depuis l'écran d'administration, comme pour les unités.
 */
export async function estimateIngredientPieceWeightsWithAI(args: {
  ingredientNames: string[];
  recipeId?: string;
  /** Fil du traitement appelant : import, declencheur, ecran. */
  correlationId?: string;
  userId?: string;
}): Promise<number> {
  const candidates = [...new Set(args.ingredientNames.map((n) => n.trim()).filter(Boolean))];
  if (candidates.length === 0) return 0;

  // On ne redemande pas un poids déjà connu. Depuis que les ingrédients écrits
  // « 3 pièces » entrent aussi ici, la liste contient à chaque recette des
  // ingrédients courants dont le référentiel sait déjà tout : sans ce filtre,
  // chaque enregistrement paierait un appel pour réécrire ce qu'il savait —
  // et écraserait au passage un poids corrigé à la main.
  const correlationId = args.correlationId ?? `piece-weights-${args.recipeId ?? "norecipe"}`;
  const byName = new Map<string, string>();
  for (const name of candidates) {
    const id = normalizeIngredientCanonicalId(name);
    if (id) byName.set(name, id);
  }
  if (byName.size === 0) return 0;

  // Une lecture groupée remplace un `get()` par candidat. Référentiel illisible :
  // on demande quand même l'estimation plutôt que de laisser l'ingrédient sans
  // poids, mais l'incident reste visible.
  let known = new Map<string, Record<string, unknown>>();
  try {
    known = (await readDocsByIds(COLL_NUTRITION_INGREDIENTS, [...byName.values()])) as Map<
      string,
      Record<string, unknown>
    >;
  } catch (err) {
    void logError({
      message: "estimateIngredientPieceWeightsWithAI: lecture groupée des poids connus impossible",
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId,
    });
  }

  const names = [...byName.entries()]
    .filter(([, id]) => {
      const weight = known.get(id)?.grams_per_piece;
      return !(typeof weight === "number" && Number.isFinite(weight) && weight > 0);
    })
    .map(([name]) => name);
  if (names.length === 0) return 0;

  const prompt = `Tu es un expert en cuisine française et en pesée d'ingrédients.

Pour chacun des ingrédients ci-dessous, indique s'il se compte à la PIÈCE et, si oui,
le poids moyen d'UNE pièce en grammes, tel qu'il est utilisé en cuisine.

Règles :
- « se compte à la pièce » signifie qu'une recette écrit « 3 <ingrédient> » sans unité
  (un œuf, un jaune d'œuf, une gousse de vanille, une échalote, un citron).
- Un ingrédient qui se pèse ou se mesure en volume (farine, lait, huile) N'est PAS
  compté à la pièce : réponds null pour lui.
- Poids NET, sans coquille ni peau non consommée.
- Distingue bien les parties : un jaune d'œuf ne pèse pas ce que pèse un œuf entier.

Ingrédients : ${names.map((n) => `"${n}"`).join(", ")}

Retourne UNIQUEMENT un objet JSON {"<ingrédient>": <grammes ou null>}, sans texte autour :`;

  try {
    const weights = await askJson({
      prompt,
      ctx: {
        correlationId,
        feature: "estimate_piece_weights",
        userId: args.userId ?? "system",
        moduleType: "DESIGN",
        timeoutMs: 20_000,
      },
      validate: (parsed) =>
        parsed && typeof parsed === "object" && !Array.isArray(parsed)
          ? (parsed as Record<string, unknown>)
          : null,
    });

    const updates = new Map<string, Record<string, unknown>>();
    for (const [name, value] of Object.entries(weights)) {
      if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) continue;
      const id = normalizeIngredientCanonicalId(name);
      if (!id) continue;
      updates.set(id, {
        grams_per_piece: value,
        piece_weight_source: "ai_estimated",
        default_unit: "pièce",
        updated_at: FieldValue.serverTimestamp(),
        ...(args.recipeId ? { last_seen_recipe_id: args.recipeId } : {}),
      });
    }
    const written = await writeDocsMerged(COLL_NUTRITION_INGREDIENTS, updates);

    await logInfo({
      message: `estimateIngredientPieceWeightsWithAI: ${written} poids à la pièce enregistré(s)`,
      extra: { recipeId: args.recipeId, demandes: names },
    });
    return written;
  } catch (err) {
    // Best-effort : la recette reste calculable sans ces poids, mais l'échec
    // doit rester visible (règle projet : aucun catch silencieux).
    await logError({
      message: "estimateIngredientPieceWeightsWithAI: échec",
      errorDescription: err instanceof Error ? err.message : String(err),
      extra: { recipeId: args.recipeId, demandes: names },
    });
    return 0;
  }
}

const NOT_CONSUMED_SCHEMA = {
  type: "object",
  properties: {
    ingredients: {
      type: "array",
      items: {
        type: "object",
        properties: {
          id: { type: "string" },
          consomme: { type: "boolean" },
        },
        required: ["id", "consomme"],
        additionalProperties: false,
      },
    },
  },
  required: ["ingredients"],
  additionalProperties: false,
} as const;

/**
 * Distingue les ingrédients qui finissent dans l'assiette de ceux qui servent
 * seulement à cuire ou à parfumer.
 *
 * Un litre de bain de friture pèse 8280 kcal, du foin de fumage en apporte 48 :
 * comptés comme le reste, ils écrasent le total de la recette et le rendent
 * inutilisable. Ils ne sont pas pour autant des erreurs de saisie — ils font
 * partie de la recette, ils ne font pas partie du repas.
 *
 * Le verdict est écrit sur l'ingrédient du référentiel, donc demandé une seule
 * fois dans sa vie : les ingrédients dont le champ est déjà renseigné ne sont
 * pas resoumis.
 */
export async function detectNotConsumedIngredientsWithAI(args: {
  ingredientNames: string[];
  recipeId?: string;
  /** Fil du traitement appelant : import, declencheur, ecran. */
  correlationId?: string;
  userId?: string;
}): Promise<number> {
  const correlationId = args.correlationId ?? `not-consumed-${args.recipeId ?? "norecipe"}`;

  // Candidats dédupliqués, dans l'ordre de la recette.
  const candidates: Array<{ name: string; id: string }> = [];
  const seen = new Set<string>();
  for (const raw of args.ingredientNames) {
    const name = raw.trim();
    if (!name) continue;
    const id = normalizeIngredientCanonicalId(name);
    if (!id || seen.has(id)) continue;
    seen.add(id);
    candidates.push({ name, id });
  }
  if (candidates.length === 0) return 0;

  // Une seule lecture pour tout le lot, au lieu d'un aller-retour Firestore par
  // ingrédient dans la boucle. Une lecture qui échoue n'annule pas la passe :
  // le verdict sera simplement redemandé, ce qui est le comportement voulu.
  let known = new Map<string, Record<string, unknown>>();
  try {
    known = (await readDocsByIds(
      COLL_NUTRITION_INGREDIENTS,
      candidates.map((c) => c.id),
    )) as Map<string, Record<string, unknown>>;
  } catch (err) {
    void logError({
      message:
        "detectNotConsumedIngredientsWithAI: lecture groupée impossible, tous les ingrédients sont resoumis",
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId,
    });
  }

  // Le verdict est écrit sur l'ingrédient du référentiel : ceux qui le portent
  // déjà ne sont pas resoumis au moteur.
  const pending = candidates.filter((c) => typeof known.get(c.id)?.not_consumed !== "boolean");
  if (pending.length === 0) return 0;

  const prompt = `Tu es un cuisinier professionnel. Pour chaque ingrédient ci-dessous,
dis s'il est RÉELLEMENT MANGÉ dans le plat servi.

Répond \`false\` (non consommé) pour :
- un bain de friture ou d'huile de cuisson que l'on jette (« huile pour friture »)
- un support de cuisson ou de fumage (foin, paille, sarment, planche de cèdre)
- un lit de gros sel ou de riz de cuisson que l'on retire
- une marinade ou une saumure jetée avant cuisson
- un élément de décoration non comestible

Répond \`true\` pour tout ce qui est mangé, même en petite quantité, même s'il
n'en reste qu'une trace après cuisson : une huile de cuisson d'une poêlée est
absorbée, elle est consommée ; un aromate infusé puis retiré (bouquet garni,
feuille de laurier) est consommé partiellement — réponds \`true\`.

Dans le doute, réponds \`true\` : compter un ingrédient qui ne l'était pas est
une erreur bien plus visible qu'une omission silencieuse.

Ingrédients (identifiant : nom) :
${pending.map((p, index) => `- "${index}" : ${p.name}`).join("\n")}

Format strict : {"ingredients":[{"id":"0","consomme":true}]}`;

  try {
    const verdicts = await askJson({
      prompt,
      ctx: {
        correlationId,
        feature: "detect_not_consumed",
        userId: args.userId ?? "system",
        moduleType: "DESIGN",
        timeoutMs: 30_000,
      },
      outputSchema: {
        name: "not_consumed_ingredients",
        schema: NOT_CONSUMED_SCHEMA as unknown as Record<string, unknown>,
      },
      validate: (parsed) => {
        const list = (parsed as { ingredients?: unknown }).ingredients;
        return Array.isArray(list) ? list : null;
      },
    });

    // On rassemble les écritures avant de les poser : un seul lot Firestore
    // remplace une écriture par ingrédient à l'intérieur de la boucle.
    const updates = new Map<string, Record<string, unknown>>();
    let flagged = 0;
    for (const entry of verdicts) {
      if (!entry || typeof entry !== "object") continue;
      const record = entry as Record<string, unknown>;
      const index = Number(record.id);
      if (!Number.isInteger(index) || index < 0 || index >= pending.length) continue;
      if (typeof record.consomme !== "boolean") continue;

      const notConsumed = record.consomme === false;
      updates.set(pending[index].id, {
        not_consumed: notConsumed,
        not_consumed_source: "ai_estimated",
        updated_at: FieldValue.serverTimestamp(),
      });
      if (notConsumed) flagged++;
    }

    const written = await writeDocsMerged(COLL_NUTRITION_INGREDIENTS, updates);

    await logInfo({
      message: `detectNotConsumedIngredientsWithAI: ${written} ingrédient(s) qualifié(s), ${flagged} hors calcul`,
      extra: { recipeId: args.recipeId, demandes: pending.map((p) => p.name) },
    });
    return flagged;
  } catch (err) {
    await logError({
      message: "detectNotConsumedIngredientsWithAI: échec",
      errorDescription: err instanceof Error ? err.message : String(err),
      extra: { recipeId: args.recipeId, demandes: pending.map((p) => p.name) },
    });
    return 0;
  }
}

const DUPLICATE_SCHEMA = {
  type: "object",
  properties: {
    doublons: {
      type: "array",
      items: {
        type: "object",
        properties: {
          id: { type: "string" },
          reprend: { type: "string" },
        },
        required: ["id", "reprend"],
        additionalProperties: false,
      },
    },
  },
  required: ["doublons"],
  additionalProperties: false,
} as const;

/** Une ligne de la liste d'ingrédients, telle que la recette l'écrit. */
export interface DuplicateCandidate {
  name: string;
  qty: string;
  unit: string;
}

/**
 * Repère les lignes qui reprennent un ingrédient déjà listé.
 *
 * Une recette qui achète 1,5 kg de côte et en dresse « 4 tranches de viande »
 * décrit le même aliment à deux stades. Le calcul, lui, additionne : la recette
 * affichait 8254 kcal dont la moitié comptée deux fois.
 *
 * La reconnaissance demande de comprendre le texte : « viande » et « côte de
 * freygaard » n'ont aucun mot commun, tandis que deux lignes très proches —
 * beurre pour la pâte, beurre pour la poêle — sont deux achats réels. Aucune
 * heuristique de nom ne tient ; d'où cet appel.
 *
 * Rend les indices des lignes à écarter. En cas de doute, la ligne est
 * conservée : compter deux fois est visible, effacer un ingrédient ne l'est pas.
 */
export async function detectDuplicateIngredientsWithAI(args: {
  ingredients: DuplicateCandidate[];
  recipeId?: string;
  /** Fil du traitement appelant : import, declencheur, ecran. */
  correlationId?: string;
  userId?: string;
}): Promise<number[]> {
  if (args.ingredients.length < 2) return [];

  const prompt = `Tu es un cuisinier professionnel. Voici la liste d'ingrédients d'UNE recette,
telle qu'elle a été extraite du texte.

Certaines lignes décrivent le MÊME aliment à deux stades : la pièce achetée, puis
la même pièce découpée ou nommée autrement au moment du dressage. Additionner ces
lignes double les apports du plat.

Indique UNIQUEMENT les lignes qui REPRENNENT un aliment déjà listé plus haut.

Règles :
- Un terme générique (« viande », « poisson », « légumes », « fromage ») qui
  désigne une pièce déjà listée sous son nom précis est une reprise.
- Une découpe d'une pièce déjà listée (tranches, morceaux, quartiers, lanières)
  est une reprise.
- Deux emplois distincts d'un même produit acheté séparément — beurre pour la
  pâte et beurre pour la poêle, huile de cuisson et huile d'assaisonnement — ne
  sont PAS des reprises : ce sont deux quantités réellement achetées.
- Deux morceaux différents d'un même animal (côte et joue, blanc et cuisse) ne
  sont PAS des reprises.
- La ligne conservée est celle qui décrit l'achat ; la reprise est celle qui
  apparaît APRÈS.
- Dans le doute, n'indique rien : compter deux fois se voit, effacer un
  ingrédient ne se voit pas.

Lignes (identifiant : quantité unité nom) :
${args.ingredients
  .map((i, index) => `- "${index}" : ${i.qty} ${i.unit} ${i.name}`.replace(/\s+/g, " "))
  .join("\n")}

Format strict — \`reprend\` porte l'identifiant de la ligne d'origine :
{"doublons":[{"id":"7","reprend":"0"}]}`;

  try {
    const modelResult = await callModel({
      parts: [textPart(prompt)],
      ctx: {
        correlationId: args.correlationId ?? `duplicate-ingredients-${args.recipeId ?? "norecipe"}`,
        feature: "detect_duplicate_ingredients",
        userId: args.userId ?? "system",
        moduleType: "DESIGN",
        timeoutMs: 30_000,
      },
      outputSchema: {
        name: "duplicate_ingredients",
        schema: DUPLICATE_SCHEMA as unknown as Record<string, unknown>,
      },
    });

    const raw = modelResult.text.trim();
    const match = raw.match(/\{[\s\S]*\}/);
    if (!match) return [];
    const parsed = JSON.parse(match[0]) as { doublons?: unknown };
    if (!Array.isArray(parsed.doublons)) return [];

    const duplicates: number[] = [];
    for (const entry of parsed.doublons) {
      if (!entry || typeof entry !== "object") continue;
      const record = entry as Record<string, unknown>;
      const index = Number(record.id);
      const source = Number(record.reprend);
      if (!Number.isInteger(index) || index < 0 || index >= args.ingredients.length) continue;
      // Une ligne ne peut pas se reprendre elle-même, et la source doit exister :
      // sans ces garde-fous, une réponse approximative viderait la recette.
      if (!Number.isInteger(source) || source < 0 || source >= args.ingredients.length) continue;
      if (source === index) continue;
      if (!duplicates.includes(index)) duplicates.push(index);
    }

    // Garde-fou de dernier ressort : une recette dont plus de la moitié des
    // lignes seraient des reprises n'existe pas. C'est le signe d'une réponse
    // partie de travers, et mieux vaut ne rien écarter que vider le calcul.
    if (duplicates.length * 2 > args.ingredients.length) {
      await logError({
        message: `detectDuplicateIngredientsWithAI: ${duplicates.length}/${args.ingredients.length} lignes déclarées en doublon, réponse ignorée`,
        errorDescription: "Proportion invraisemblable — aucun ingrédient n'est écarté",
        correlationId: args.correlationId ?? `duplicate-ingredients-${args.recipeId ?? "norecipe"}`,
      });
      return [];
    }

    await logInfo({
      message: `detectDuplicateIngredientsWithAI: ${duplicates.length} reprise(s) sur ${args.ingredients.length} ligne(s)`,
      extra: {
        recipeId: args.recipeId,
        reprises: duplicates.map((index) => args.ingredients[index].name),
      },
    });
    return duplicates;
  } catch (err) {
    await logError({
      message: "detectDuplicateIngredientsWithAI: échec",
      errorDescription: err instanceof Error ? err.message : String(err),
      extra: { recipeId: args.recipeId },
    });
    return [];
  }
}

/** Couple ingrédient/unité dont le poids reste à établir. */
export interface IngredientUnitPair {
  name: string;
  /** Unité canonique (`branche`, `tranche`, `poignee`…). */
  unit: string;
}

const UNIT_WEIGHT_SCHEMA = {
  type: "object",
  properties: {
    weights: {
      type: "array",
      items: {
        type: "object",
        properties: {
          id: { type: "string" },
          grams: { type: "number" },
        },
        required: ["id", "grams"],
        additionalProperties: false,
      },
    },
  },
  required: ["weights"],
  additionalProperties: false,
} as const;

/**
 * Estime le poids d'UNE unité pour un couple ingrédient/unité précis.
 *
 * Une branche de thym pèse 1 g, une branche de céleri 60 : le poids de ces
 * unités n'appartient ni à l'unité ni à l'ingrédient seuls, mais à leur couple.
 * La table intégrée porte une moyenne (`branche: 15 g`) qui ne décrit aucun
 * ingrédient réel — quatre branches de thym y pesaient 60 g, soixante fois
 * trop. Le résultat est écrit dans `grams_per_unit.<unité>` sur l'ingrédient.
 *
 * Les couples déjà connus ne sont pas redemandés : sans ce filtre, chaque
 * enregistrement de recette paierait un appel pour réécrire ce qu'il savait.
 */
export async function estimateIngredientUnitWeightsWithAI(args: {
  pairs: IngredientUnitPair[];
  recipeId?: string;
  /** Fil du traitement appelant : import, declencheur, ecran. */
  correlationId?: string;
  userId?: string;
}): Promise<number> {
  const correlationId = args.correlationId ?? `unit-couple-weights-${args.recipeId ?? "norecipe"}`;
  const seen = new Set<string>();
  const candidates: Array<{ pair: IngredientUnitPair; id: string }> = [];

  for (const pair of args.pairs) {
    const name = pair.name.trim();
    const unit = pair.unit.trim();
    if (!name || !unit) continue;
    const id = normalizeIngredientCanonicalId(name);
    if (!id) continue;
    const key = `${id}|${unit}`;
    if (seen.has(key)) continue;
    seen.add(key);
    candidates.push({ pair: { name, unit }, id });
  }
  if (candidates.length === 0) return 0;

  // Un seul aller-retour pour tous les couples, au lieu d'un `get()` par couple.
  let known = new Map<string, Record<string, unknown>>();
  try {
    known = (await readDocsByIds(
      COLL_NUTRITION_INGREDIENTS,
      candidates.map((c) => c.id),
    )) as Map<string, Record<string, unknown>>;
  } catch (err) {
    void logError({
      message:
        "estimateIngredientUnitWeightsWithAI: lecture groupée impossible, tous les couples sont resoumis",
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId,
    });
  }

  const pending = candidates.filter((c) => {
    const map = known.get(c.id)?.grams_per_unit;
    const value =
      map && typeof map === "object" ? (map as Record<string, unknown>)[c.pair.unit] : undefined;
    return !(typeof value === "number" && Number.isFinite(value) && value > 0);
  });
  if (pending.length === 0) return 0;

  const prompt = `Tu es un expert en cuisine française et en pesée d'ingrédients.

Pour chaque couple ci-dessous, donne le poids en grammes d'UNE seule unité de CET
ingrédient précis, tel qu'il est employé en cuisine.

Règles :
- Le poids dépend de l'ingrédient : une branche de thym pèse environ 1 g, une
  branche de céleri environ 60 g. Ne donne jamais une moyenne toutes plantes
  confondues.
- Poids NET de la partie réellement utilisée, sans tige ligneuse ni peau jetée.
- Une tranche dépend de ce qu'on tranche : jambon, pain de mie et rôti n'ont pas
  le même poids à la tranche.
- Donne TOUJOURS une valeur strictement positive : une approximation raisonnable
  vaut mieux qu'une absence de valeur.
- Le champ \`id\` reprend l'identifiant EXACTEMENT tel qu'il est écrit ci-dessous.

Couples à estimer (identifiant : une <unité> de <ingrédient>) :
${pending.map((p, index) => `- "${index}" : une ${p.pair.unit} de ${p.pair.name}`).join("\n")}

Format strict : {"weights":[{"id":"0","grams":1}]}`;

  try {
    const entries = await askJson({
      prompt,
      ctx: {
        correlationId,
        feature: "estimate_unit_couple_weights",
        userId: args.userId ?? "system",
        moduleType: "DESIGN",
        timeoutMs: 30_000,
      },
      outputSchema: {
        name: "unit_couple_weights",
        schema: UNIT_WEIGHT_SCHEMA as unknown as Record<string, unknown>,
      },
      validate: (parsed) => {
        const list = (parsed as { weights?: unknown }).weights;
        return Array.isArray(list) ? list : null;
      },
    });

    // Deux couples peuvent viser le même ingrédient sous deux unités
    // différentes : les écritures sont fusionnées avant d'être posées, sinon la
    // seconde écraserait la map de la première.
    const updates = new Map<string, Record<string, unknown>>();
    for (const entry of entries) {
      if (!entry || typeof entry !== "object") continue;
      const record = entry as Record<string, unknown>;
      const index = Number(record.id);
      const grams = Number(record.grams);
      if (!Number.isInteger(index) || index < 0 || index >= pending.length) continue;
      if (!Number.isFinite(grams) || grams <= 0) continue;

      const target = pending[index];
      const existing = updates.get(target.id);
      const perUnit = {
        ...((existing?.grams_per_unit as Record<string, number> | undefined) ?? {}),
        [target.pair.unit]: grams,
      };
      updates.set(target.id, {
        // Map imbriquée et non clé pointée : dans un `set(..., {merge:true})`,
        // « grams_per_unit.branche » créerait un champ dont le nom contient un
        // point, invisible pour le lecteur qui interroge la map.
        grams_per_unit: perUnit,
        unit_weight_source: "ai_estimated",
        updated_at: FieldValue.serverTimestamp(),
        ...(args.recipeId ? { last_seen_recipe_id: args.recipeId } : {}),
      });
    }
    const written = await writeDocsMerged(COLL_NUTRITION_INGREDIENTS, updates);

    await logInfo({
      message: `estimateIngredientUnitWeightsWithAI: ${written}/${pending.length} poids de couple enregistré(s)`,
      extra: {
        recipeId: args.recipeId,
        demandes: pending.map((p) => `${p.pair.unit} de ${p.pair.name}`),
      },
    });
    return written;
  } catch (err) {
    await logError({
      message: "estimateIngredientUnitWeightsWithAI: échec",
      errorDescription: err instanceof Error ? err.message : String(err),
      extra: {
        recipeId: args.recipeId,
        demandes: pending.map((p) => `${p.pair.unit} de ${p.pair.name}`),
      },
    });
    return 0;
  }
}
