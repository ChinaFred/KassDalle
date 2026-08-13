/**
 * Normalisation d'une recette contre les référentiels.
 *
 * Résout chaque ingrédient et chaque unité contre les collections
 * `nutrition_ingredients` et `nutrition_units`, complète les quantités
 * manquantes par IA, puis réécrit le CookLang avec les formes canoniques.
 *
 * Extrait de callable/nutritionCallable.ts.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";

import { COLL_RECIPES } from "../config";
import { logError, logInfo } from "../logging";
import { normalizeIngredientCanonicalId, normalizeIngredientStrictId } from "./ingredientName";
import { isIngredientDependentUnit } from "./quantityConversion";
import { resolveIngredientUnitFields } from "./ingredientUnitResolution";
import { upsertNutritionUnitReference } from "./unitReference";
import { extractIngredientsStructured } from "../cooklang/parser";
import {
  fallbackUnitLabel,
  parseQtyAndUnit,
  formatQtyAndUnit,
  inferUnitFromIngredientName,
  inferPieceUnitIfEmpty,
  cleanQtyValue,
  fallbackSingularize,
} from "./unitDisplay";
import {
  singularizeFrenchUnitsWithAI,
  completeIngredientQuantitiesWithAI,
  enrichUnknownUnitsWithAI,
  enrichUnknownIngredientsWithAI,
  estimateIngredientPieceWeightsWithAI,
  estimateIngredientUnitWeightsWithAI,
  detectNotConsumedIngredientsWithAI,
} from "./aiEnrichment";
import {
  parseSectionHeader,
  planSectionHeaders,
  buildCategoryByRefId,
  ingredientRefKey,
  ingredientSectionKey,
  dedupeResolvedIngredients,
} from "./ingredientSections";

export interface NormalizeRecipeReferentialsResult {
  rewrittenCooklang: string;
  resolvedIngredients: StoredRecipeIngredient[];
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

/**
 * Ingrédient tel qu'il est STOCKÉ sur la recette : ce que la recette dit.
 *
 * Les formes résolues (unité canonique, identité référentielle) sont des
 * intermédiaires de calcul, pas des données de la recette. Les persister
 * créait un champ que deux traitements se disputaient et que personne ne
 * relisait — le référentiel se recalcule depuis le nom, l'unité canonique
 * depuis l'unité.
 */
interface StoredRecipeIngredient {
  name: string;
  qty: string;
  unit: string;
  category?: string;
}

/** Ingrédient résolu, avec ses intermédiaires — vit en mémoire uniquement. */
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

/**
 * Choisit le nom LISIBLE d'un ingrédient.
 *
 * Un identifiant n'est pas un nom d'affichage. Les versions précédentes
 * fabriquaient `canonical_name` en remplaçant les soulignés de l'identifiant
 * par des espaces : « crème liquide entière » devenait la clé
 * `creme_liquide_entiere`, puis redevenait le texte « creme liquide entiere ».
 * Accents et apostrophes disparaissaient de la recette elle-même, puisque ce
 * nom appauvri remplace ensuite celui écrit par l'utilisateur.
 *
 * Règle : on préfère le nom brut de la recette quand il désigne le même
 * ingrédient — même identifiant normalisé — et que le nom stocké n'est qu'une
 * reconstitution de la clé. Sinon, le nom stocké fait foi : un administrateur
 * a pu le corriger à la main.
 */
function pickDisplayName(args: {
  stored: string;
  raw: string;
  ingredientRefId: string;
}): string {
  const raw = args.raw.trim();
  if (!args.stored) return raw || args.ingredientRefId.replace(/_/g, " ");
  if (!raw) return args.stored;

  const derivedFromId = args.ingredientRefId.replace(/_/g, " ");
  const storedIsDerivedFromId = args.stored === derivedFromId;
  const sameIngredient =
    normalizeIngredientStrictId(raw) === args.ingredientRefId;

  return storedIsDerivedFromId && sameIngredient && raw !== derivedFromId
    ? raw
    : args.stored;
}

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
    const stored = typeof data.canonical_name === "string" ? data.canonical_name.trim() : "";
    const canonicalName = pickDisplayName({
      stored,
      raw: args.ingredientRawName,
      ingredientRefId,
    });
    // Rattrape les noms fabriqués à partir de l'identifiant par les versions
    // précédentes : « creme liquide entiere » redevient « crème liquide entière ».
    const displayNameNeedsRepair = canonicalName !== stored;
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
    if (displayNameNeedsRepair) {
      updates.canonical_name = canonicalName;
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
    canonical_name: args.ingredientRawName.trim() || ingredientRefId.replace(/_/g, " "),
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
    canonicalName: args.ingredientRawName.trim() || ingredientRefId.replace(/_/g, " "),
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
  /** Suggestions IA de quantités, indexées par `ingredientSectionKey`. */
  qtyOverrides?: Map<string, { qty: string; unit: string }>;
  /** Callback de singularisation transmis à resolveOneIngredient. */
  singularizeUnit?: (unit: string) => string;
  /** Catégorie décidée par la liste d'ingrédients, par identifiant référentiel. */
  categoryByRefId?: Map<string, string>;
}): Promise<string> {
  // Traitement ligne à ligne : un en-tête de section occupe une ligne entière,
  // et les ingrédients du projet vivent dans la prose des étapes. Insérer une
  // section n'a de sens qu'AVANT une ligne, jamais au milieu d'une phrase.
  const lines = args.cooklang.split("\n");
  const rewrittenLines: string[] = [];
  const targetCategories: Array<string | null> = [];
  let sourceCategory = "";

  for (const line of lines) {
    const header = parseSectionHeader(line);
    if (header !== null) {
      sourceCategory = header;
      rewrittenLines.push(line);
      targetCategories.push(null);
      continue;
    }

    const re = /@([^{@#~\n]+)\{([^}]*)\}/g;
    const matches = [...line.matchAll(re)];
    if (matches.length === 0) {
      rewrittenLines.push(line);
      targetCategories.push(null);
      continue;
    }

    const tokens: Array<{
      match: RegExpMatchArray;
      resolved: NormalizedRecipeIngredient | null;
    }> = [];
    for (const m of matches) {
      const parsed = parseQtyAndUnit(m[2] ?? "");
      // La catégorie n'est pas transmise à la résolution : elle ne sert pas à
      // résoudre, et c'est justement ce que cette ligne cherche à déterminer.
      const resolved = await resolveOneIngredient({
        item: { name: m[1].trim(), qty: parsed.qty, unit: parsed.unit },
        recipeId: args.recipeId,
        singularizeUnit: args.singularizeUnit,
      });
      tokens.push({ match: m, resolved });
    }

    // Catégorie de la ligne : celle du premier ingrédient que la liste résolue
    // sait situer sans ambiguïté. C'est par là qu'une catégorie créée dans
    // l'éditeur entre dans le CookLang.
    let target: string | null = null;
    for (const token of tokens) {
      if (token.resolved == null) continue;
      const known = args.categoryByRefId?.get(ingredientRefKey(token.resolved));
      if (known !== undefined) {
        target = known;
        break;
      }
    }
    targetCategories.push(target);
    const effectiveCategory = target ?? sourceCategory;

    let out = "";
    let cursor = 0;
    for (const token of tokens) {
      const tokenStart = token.match.index ?? 0;
      out += line.slice(cursor, tokenStart);
      const resolved = token.resolved;
      if (resolved == null) {
        out += token.match[0];
      } else {
        let qty = resolved.qty;
        let unit = resolved.unit;
        // Applique les suggestions IA si la quantité est toujours vide.
        // La suggestion est cherchée dans la section de la ligne : la même
        // farine dans deux sections n'a pas la même quantité. Le repli sans
        // section ne vaut que pour les noms qui n'apparaissent qu'une fois.
        if (!qty && args.qtyOverrides) {
          const override =
            args.qtyOverrides.get(ingredientSectionKey(resolved.name, effectiveCategory)) ??
            args.qtyOverrides.get(ingredientSectionKey(resolved.name, ""));
          if (override) {
            qty = override.qty;
            if (!unit && override.unit) unit = override.unit;
          }
        }
        out += `@${resolved.name}{${formatQtyAndUnit(qty, unit)}}`;
      }
      cursor = tokenStart + token.match[0].length;
    }
    out += line.slice(cursor);
    rewrittenLines.push(out);
  }

  return planSectionHeaders({ lines: rewrittenLines, targetCategories }).join("\n");
}
export async function normalizeRecipeReferentialsCore(args: {
  recipeId?: string;
  cooklang: string;
  ingredients?: Array<Record<string, unknown>>;
  /** Clé API Gemini : active la passe IA de complétion des quantités manquantes. */
  geminiApiKey?: string;
  userId?: string;
  /**
   * Instant limite des passes IA. Au-delà, elles sont abandonnées et la
   * normalisation rend ce qu'elle a : le déclencheur `onRecipeWritten`
   * enrichira et recalculera ensuite. Sans borne, l'appelant (import) risquait
   * d'épuiser son propre timeout et de laisser son job en suspens.
   */
  deadlineMs?: number;
}): Promise<NormalizeRecipeReferentialsResult> {
  const cooklang = args.cooklang;
  const recipeId = args.recipeId;
  const hasTimeLeft = (): boolean =>
    args.deadlineMs == null || Date.now() < args.deadlineMs;
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
    unitSingularMap = await singularizeFrenchUnitsWithAI({
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

  // ── Déduplication : fusion par (canonical_id, section) ──────────────────────
  // Cas visé : Gemini a extrait « @cerfeuil frais{} » ET « @brins de cerfeuil frais{} »
  // dans la même liste. Après split, les deux deviennent « cerfeuil frais ».
  // La section fait partie de la clé : deux occurrences du même ingrédient dans
  // deux sections différentes sont deux ingrédients, comme côté Dart
  // (`_dedupeStructuredIngredients`) et comme le parseur lui-même le décide.
  const deduplicatedIngredients = dedupeResolvedIngredients(resolvedIngredients);
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
    if (unitCanonicalsToEnrich.length > 0 && hasTimeLeft()) {
      // Contexte ingrédients par unité : permet à l'IA d'estimer un poids
      // pertinent pour les unités vagues (une poignée de cacahuètes ≠ de roquette).
      const unitIngredientNames = new Map<string, string[]>();
      for (const ing of resolvedIngredients) {
        const canonical = ing.unit_canonical;
        const name = ing.name.trim();
        if (!canonical || !name) continue;
        const list = unitIngredientNames.get(canonical) ?? [];
        if (!list.includes(name)) list.push(name);
        unitIngredientNames.set(canonical, list);
      }
      await enrichUnknownUnitsWithAI({
        unitCanonicals: unitCanonicalsToEnrich,
        geminiApiKey: args.geminiApiKey,
        userId: args.userId,
        recipeId,
        unitIngredientNames,
      });
    }

    // ── Ingrédients comptés à la pièce ────────────────────────────────────
    // Ces ingrédients étaient jusqu'ici écartés de tout enrichissement : la
    // collecte ci-dessus ne retient que ceux qui portent déjà un
    // `unit_canonical`. Un œuf, un jaune, une gousse de vanille en sortaient
    // donc sans poids, et quittaient purement et simplement le calcul.
    //
    // La liste `PIECE_INGREDIENT_IDS` ne peut pas tenir ce rôle : c'est une
    // constante du code, qui exige un déploiement à chaque nouvel ingrédient.
    // Elle sert désormais d'amorçage, et le référentiel prend le relais.
    //
    // Les ingrédients écrits « 3 pièces » comptent AUSSI : ils portent une unité,
    // donc échappaient au filtre, mais « pièce » ne dit rien de leur poids. Ils
    // héritaient à vie du défaut générique de 100 g — trois échalotes pesaient
    // 300 g. Le poids d'une pièce appartient à l'ingrédient, pas à l'unité.
    const namesCountedByPiece = [...new Set(
      resolvedIngredients
        .filter((i) => (!i.unit_canonical || i.unit_canonical === "piece") && i.name.trim())
        .map((i) => i.name.trim()),
    )];
    if (namesCountedByPiece.length > 0 && hasTimeLeft()) {
      await estimateIngredientPieceWeightsWithAI({
        ingredientNames: namesCountedByPiece,
        geminiApiKey: args.geminiApiKey,
        recipeId,
        userId: args.userId,
      });
    }

    // ── Unités dont le poids dépend de l'ingrédient ───────────────────────
    // « branche », « tranche », « poignée » n'ont pas de poids propre : une
    // branche de thym pèse 1 g, une de céleri 60. La table intégrée en donnait
    // une moyenne (15 g) qui ne décrivait aucun ingrédient réel. Le poids du
    // COUPLE s'apprend ici et s'écrit sur l'ingrédient.
    const couples = resolvedIngredients
      .filter(
        (i) =>
          i.name.trim() &&
          i.unit_canonical &&
          i.unit_canonical !== "piece" &&
          isIngredientDependentUnit(i.unit_canonical),
      )
      .map((i) => ({ name: i.name.trim(), unit: i.unit_canonical as string }));
    if (couples.length > 0 && hasTimeLeft()) {
      await estimateIngredientUnitWeightsWithAI({
        pairs: couples,
        geminiApiKey: args.geminiApiKey,
        recipeId,
        userId: args.userId,
      });
    }

    // ── Ingrédients qui ne finissent pas dans l'assiette ──────────────────
    // Un litre de bain de friture pèse 8280 kcal : compté comme le reste, il
    // rend le total de la recette inutilisable. Le verdict est écrit sur
    // l'ingrédient, donc demandé une seule fois dans sa vie.
    const allNames = [...new Set(
      resolvedIngredients.map((i) => i.name.trim()).filter(Boolean),
    )];
    if (allNames.length > 0 && hasTimeLeft()) {
      await detectNotConsumedIngredientsWithAI({
        ingredientNames: allNames,
        geminiApiKey: args.geminiApiKey,
        recipeId,
        userId: args.userId,
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
    if (ingredientRefIds.length > 0 && hasTimeLeft()) {
      const enriched = await enrichUnknownIngredientsWithAI({
        ingredientRefIds,
        geminiApiKey: args.geminiApiKey,
        userId: args.userId,
        recipeId,
        deadlineMs: args.deadlineMs,
      });
      if (enriched > 0 && recipeId) {
        nutritionRecomputeNeeded = true;
      }
    }
  }

  // ── Passe IA : complétion automatique des quantités manquantes ──────────────
  let aiCompletedIngredients = 0;
  const qtyOverrides = new Map<string, { qty: string; unit: string }>();
  if (args.geminiApiKey) {
    const incomplete = resolvedIngredients.filter((i) => !i.qty.trim());
    if (incomplete.length > 0 && hasTimeLeft()) {
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
        qtyOverrides.set(ingredientSectionKey(ing.name, ing.category), {
          qty: ing.qty,
          unit: ing.unit,
        });
      }

      // Repli sans section, pour les seuls noms qui n'apparaissent que dans une
      // section : la liste d'ingrédients envoyée par le client et le texte
      // CookLang peuvent découper les sections différemment, et une suggestion
      // perdue vaut mieux qu'une quantité appliquée à la mauvaise section —
      // mais quand le nom est unique, il n'y a pas d'ambiguïté possible.
      const occurrencesByName = new Map<string, number>();
      for (const ing of resolvedIngredients) {
        const n = ing.name.trim().toLowerCase();
        occurrencesByName.set(n, (occurrencesByName.get(n) ?? 0) + 1);
      }
      for (const ing of resolvedIngredients) {
        if (occurrencesByName.get(ing.name.trim().toLowerCase()) !== 1) continue;
        const sectionKey = ingredientSectionKey(ing.name, ing.category);
        const override = qtyOverrides.get(sectionKey);
        if (override) qtyOverrides.set(ingredientSectionKey(ing.name, ""), override);
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

  // Le CookLang est la source de vérité : une catégorie qui n'existe que dans
  // la liste d'ingrédients (créée depuis l'éditeur) doit y être écrite, sans
  // quoi elle est perdue au rechargement, qui reparse le texte.
  const categoryByRefId = buildCategoryByRefId(resolvedIngredients);

  const rewrittenCooklang = cooklang
    ? await rewriteCooklangWithReferentials({
        cooklang,
        recipeId,
        qtyOverrides: qtyOverrides.size > 0 ? qtyOverrides : undefined,
        singularizeUnit,
        categoryByRefId,
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
    // Projection volontaire : seuls les champs de la recette sont renvoyés,
    // donc stockés. Tout le reste a servi ici et n'a plus lieu d'être.
    resolvedIngredients: resolvedIngredients.map((i) => ({
      name: i.name,
      qty: i.qty,
      unit: i.unit,
      ...(i.category ? { category: i.category } : {}),
    })),
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

  // ── Signaler que la nutrition est à refaire, sans la refaire soi-même ──────
  //
  // Cette fonction calculait ici la nutrition. Deux raisons de ne plus le faire.
  //
  // D'abord la justesse : à l'édition d'une recette, le client appelle la
  // normalisation AVANT d'écrire la recette. `computeAndPersistRecipeNutrition`
  // relit le document depuis Firestore — il travaillait donc sur la version
  // d'AVANT la modification, et écrivait sur la recette une nutrition périmée
  // que le déclencheur remplaçait quelques secondes plus tard. Du travail jeté,
  // qui affichait un chiffre faux entre-temps.
  //
  // Ensuite le contrat, déjà écrit dans TechnicalRequirements : la
  // normalisation possède `recipes.ingredients`, les déclencheurs possèdent
  // `nutrition`, `nutrition_validation` et `shopping_products`. Un seul
  // écrivain par champ.
  //
  // Le drapeau ci-dessous couvre le cas que le déclencheur ne verrait pas seul :
  // un enrichissement qui remplit des `per100g` manquants alors que les
  // ingrédients de la recette, eux, n'ont pas bougé. Sans lui, la garde du
  // déclencheur conclurait qu'il n'y a rien à faire et laisserait une nutrition
  // calculée sur un référentiel plus pauvre qu'il ne l'est maintenant.
  if (nutritionRecomputeNeeded && recipeId) {
    try {
      await getFirestore().collection(COLL_RECIPES).doc(recipeId).update({
        nutrition_stale: true,
      });
      void logInfo({
        message: "normalizeRecipeReferentialsCore: nutrition marquée à recalculer après enrichissement per100g",
        extra: { recipeId },
      });
    } catch (err) {
      void logError({
        message: "normalizeRecipeReferentialsCore: marquage nutrition_stale impossible (best-effort)",
        errorDescription: err instanceof Error ? err.message : String(err),
        correlationId: `stale-${recipeId}`,
      });
    }
  }

  return result;
}

