/**
 * Normalisation d'une recette contre les référentiels.
 *
 * Résout chaque ingrédient et chaque unité contre les collections
 * `nutrition_ingredients` et `nutrition_units`, et complète par IA ce que la
 * recette ne dit pas : quantités manquantes, poids d'une pièce, poids d'un
 * couple ingrédient/unité, ingrédients qui ne finissent pas dans l'assiette.
 * Le texte CookLang, lui, ressort intact.
 *
 * Ce qu'elle ne fait PLUS : demander le poids d'une unité inconnue ni les
 * valeurs per100g d'un ingrédient. Ces deux passes vivaient ici ET dans le
 * déclencheur `onRecipeWritten`, qui part à chaque écriture de recette — donc
 * en même temps qu'un import, sur la même recette, avec le même référentiel
 * vide. Elles n'existent plus qu'au déclencheur, qui en a besoin dans la foulée
 * pour calculer la nutrition.
 *
 * Extrait de callable/nutritionCallable.ts.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";

import { logInfo } from "../logging";
import { normalizeIngredientCanonicalId, normalizeIngredientStrictId } from "./ingredientName";
import { isIngredientDependentUnit } from "./quantityConversion";
import { resolveIngredientUnitFields } from "./ingredientUnitResolution";
import { upsertNutritionUnitReference } from "./unitReference";
import { extractIngredientsStructured } from "../cooklang/parser";
import {
  fallbackUnitLabel,
  inferUnitFromIngredientName,
  inferPieceUnitIfEmpty,
  cleanQtyValue,
  fallbackSingularize,
  defaultQuantityForMissing,
} from "./unitDisplay";
import {
  singularizeFrenchUnitsWithAI,
  completeIngredientQuantitiesWithAI,
  estimateIngredientPieceWeightsWithAI,
  estimateIngredientUnitWeightsWithAI,
  detectNotConsumedIngredientsWithAI,
} from "./aiEnrichment";
import { ingredientSectionKey, dedupeResolvedIngredients } from "./ingredientSections";

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
function pickDisplayName(args: { stored: string; raw: string; ingredientRefId: string }): string {
  const raw = args.raw.trim();
  if (!args.stored) return raw || args.ingredientRefId.replace(/_/g, " ");
  if (!raw) return args.stored;

  const derivedFromId = args.ingredientRefId.replace(/_/g, " ");
  const storedIsDerivedFromId = args.stored === derivedFromId;
  const sameIngredient = normalizeIngredientStrictId(raw) === args.ingredientRefId;

  return storedIsDerivedFromId && sameIngredient && raw !== derivedFromId ? raw : args.stored;
}

async function ensureIngredientReference(args: {
  ingredientRawName: string;
  recipeId?: string;
  /** Unité observée à persister comme default_unit si le référentiel n’en a pas encore. */
  observedUnit?: string;
}): Promise<{
  ingredientRefId: string;
  canonicalName: string;
  status: "known" | "proposed";
  defaultUnit?: string;
}> {
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
    const storedDefaultUnit =
      typeof data.default_unit === "string" && data.default_unit.trim().length > 0
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
  await docRef.set(
    {
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
    },
    { merge: true },
  );

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
  const fromDisplayLabel =
    typeof unitData?.display_label === "string" ? unitData.display_label.trim() : "";
  const fromLabel = typeof unitData?.label === "string" ? unitData.label.trim() : "";
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

// rewriteCooklangWithReferentials a été supprimée, avec sa réécriture.
//
// Elle remplaçait dans les phrases le nom écrit par l'auteur par le nom
// canonique du référentiel, insérait des quantités estimées par l'IA là où le
// livre n'en donnait aucune, et pouvait remplacer un titre de section par une
// catégorie calculée. Trois façons de faire dire au livre ce qu'il n'a pas
// écrit — et une centaine de lignes qui relisaient le référentiel une seconde
// fois, pour un texte que plus personne ne devait produire.
//
// planSectionHeaders et buildCategoryByRefId restent dans ingredientSections.ts,
// testées : elles servent à situer un ingrédient dans sa section, ce qui reste
// vrai. Seule leur application au TEXTE disparaît.

export async function normalizeRecipeReferentialsCore(args: {
  recipeId?: string;
  cooklang: string;
  ingredients?: Array<Record<string, unknown>>;
  /**
   * Autorise les passes IA : complétion des quantités manquantes,
   * singularisation des unités, estimation des poids et des valeurs per100g.
   *
   * Ce drapeau s'appelait `geminiApiKey` et se testait par sa seule présence —
   * une clé d'API qui servait d'interrupteur, sous un nom devenu faux depuis
   * que ces postes peuvent être servis par Claude.
   */
  aiEnabled?: boolean;
  userId?: string;
  /**
   * Instant limite des passes IA. Au-delà, elles sont abandonnées et la
   * normalisation rend ce qu'elle a : le déclencheur `onRecipeWritten`
   * enrichira et recalculera ensuite. Sans borne, l'appelant (import) risquait
   * d'épuiser son propre timeout et de laisser son job en suspens.
   */
  deadlineMs?: number;
  /**
   * Fil du traitement appelant — import, déclencheur, écran.
   *
   * Chaque passe d'enrichissement fabriquait jusqu'ici son propre identifiant
   * (`enrich-units-…`, `enrich-ing-…`, `piece-weights-…`). Un seul import
   * produisait donc huit groupes de journaux sans lien entre eux, ni avec le
   * job qui les avait déclenchés : impossible de suivre un scan de bout en
   * bout. Le fil reçu prime désormais sur celui qu'on fabrique.
   */
  correlationId?: string;
}): Promise<NormalizeRecipeReferentialsResult> {
  const cooklang = args.cooklang;
  const recipeId = args.recipeId;
  const hasTimeLeft = (): boolean => args.deadlineMs == null || Date.now() < args.deadlineMs;
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
  if (args.aiEnabled && rawUnitsForSingularization.size > 0) {
    unitSingularMap = await singularizeFrenchUnitsWithAI({
      units: [...rawUnitsForSingularization],
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

  // Le poids des unités inconnues et les valeurs per100g des ingrédients ne
  // sont PLUS demandés ici.
  //
  // Ces deux passes vivaient aussi dans le déclencheur `onRecipeWritten`, qui
  // part à chaque écriture de recette. Un import écrivait la recette, réveillant
  // le déclencheur, puis normalisait en parallèle : les deux trouvaient le
  // référentiel vide au même instant et posaient la même question au modèle.
  // Deux fois le travail, deux fois la facture, et des journaux illisibles.
  //
  // Elles restent dans le déclencheur, et lui seul : il part sur TOUS les
  // chemins — import, saisie manuelle, modification — et c'est lui qui a besoin
  // de ces valeurs, immédiatement après, pour calculer la nutrition. Les
  // enrichir ailleurs, c'est les enrichir trop tôt ou deux fois.
  if (args.aiEnabled) {
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
    const namesCountedByPiece = [
      ...new Set(
        resolvedIngredients
          .filter((i) => (!i.unit_canonical || i.unit_canonical === "piece") && i.name.trim())
          .map((i) => i.name.trim()),
      ),
    ];
    if (namesCountedByPiece.length > 0 && hasTimeLeft()) {
      await estimateIngredientPieceWeightsWithAI({
        ingredientNames: namesCountedByPiece,
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
        recipeId,
        userId: args.userId,
        correlationId: args.correlationId,
      });
    }

    // ── Ingrédients qui ne finissent pas dans l'assiette ──────────────────
    // Un litre de bain de friture pèse 8280 kcal : compté comme le reste, il
    // rend le total de la recette inutilisable. Le verdict est écrit sur
    // l'ingrédient, donc demandé une seule fois dans sa vie.
    const allNames = [...new Set(resolvedIngredients.map((i) => i.name.trim()).filter(Boolean))];
    if (allNames.length > 0 && hasTimeLeft()) {
      await detectNotConsumedIngredientsWithAI({
        ingredientNames: allNames,
        recipeId,
        userId: args.userId,
      });
    }
  }

  // Les valeurs per100g manquantes sont demandées par le déclencheur, pas ici :
  // voir plus haut. `nutrition_stale` n'a donc plus à être posé par cette
  // fonction — le déclencheur enrichit puis recalcule dans la foulée, sans
  // avoir besoin qu'on lui laisse un mot.

  // ── Passe IA : complétion automatique des quantités manquantes ──────────────
  let aiCompletedIngredients = 0;
  const qtyOverrides = new Map<string, { qty: string; unit: string }>();
  if (args.aiEnabled) {
    const incomplete = resolvedIngredients.filter((i) => !i.qty.trim());
    if (incomplete.length > 0 && hasTimeLeft()) {
      void logInfo({
        message: `normalizeRecipeReferentialsCore: passe IA démarrée (${incomplete.length} ingrédients sans qty)`,
        extra: {
          recipeId,
          cooklangLen: cooklang.length,
          ingredients: incomplete.map((i) => i.name),
        },
      });
      const suggestions = await completeIngredientQuantitiesWithAI({
        cooklang,
        incompleteIngredients: incomplete.map((i) => ({ name: i.name, unit: i.unit })),
        recipeId,
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

  // ── Repli déterministe : matières grasses de cuisson sans quantité ─────────
  //
  // Hors du bloc précédent, donc appliqué même sans clé d'IA et même quand la
  // passe de complétion s'est tue. Une « huile pour graisser le fond du plat »
  // n'aura jamais de quantité écrite : sans repli, elle sort du calcul, et ce
  // sont une centaine de kilocalories qui manquent au total sans que rien ne
  // le signale.
  for (const ing of resolvedIngredients) {
    if (ing.qty.trim()) continue;
    const fallback = defaultQuantityForMissing(ing.name);
    if (!fallback) continue;

    ing.qty = fallback.qty;
    if (!ing.unit.trim()) {
      ing.unit = fallback.unit;
      ing.unit_raw = fallback.unit;
      ing.unit_resolution_source = "builtin_default";
      ing.unit_resolution_confidence = 0.5;
    }
    qtyOverrides.set(ingredientSectionKey(ing.name, ing.category), {
      qty: ing.qty,
      unit: ing.unit,
    });
    qtyOverrides.set(ingredientSectionKey(ing.name, ""), {
      qty: ing.qty,
      unit: ing.unit,
    });
    void logInfo({
      message: `normalizeRecipeReferentialsCore: quantité par défaut appliquée à "${ing.name}"`,
      extra: { recipeId, qty: ing.qty, unit: ing.unit },
    });
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

  // Le texte de la recette n'est PAS réécrit — il appartient au livre.
  //
  // Cette réécriture remplaçait, DANS les phrases, le nom écrit par l'auteur
  // par le nom canonique du référentiel, insérait des quantités estimées par
  // l'IA là où le livre n'en donnait aucune, et pouvait remplacer un titre de
  // section par une catégorie calculée — « Pour la sauce à l'aneth et à la
  // moutarde » devenant le nom d'une catégorie. Trois façons de faire dire au
  // livre ce qu'il n'a pas écrit, dans un traitement que rien n'annonçait.
  //
  // Le travail de la normalisation est la LISTE résolue : elle nourrit la
  // nutrition et les courses, où les noms canoniques et les quantités
  // complétées ont leur place. La prose, elle, reste celle du livre.
  //
  // Le champ survit dans le résultat, inchangé, parce que deux appelants le
  // lisent encore ; il rend désormais le texte reçu, sans une virgule de plus.
  const rewrittenCooklang = cooklang;

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
      ingredientsKnown: resolvedIngredients.filter((i) => i.ingredient_ref_status === "known")
        .length,
      ingredientsProposed: resolvedIngredients.filter((i) => i.ingredient_ref_status === "proposed")
        .length,
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
  // Le drapeau `nutrition_stale` était posé ici quand cette fonction venait
  // d'enrichir des `per100g` sans que les ingrédients aient bougé — le seul cas
  // que la garde du déclencheur ne voyait pas seule. Elle n'enrichit plus : le
  // déclencheur le fait lui-même, juste avant de calculer, et n'a donc plus
  // besoin qu'on lui laisse un mot. Le drapeau reste lu là-bas, pour les
  // recettes qui le portent encore.

  return result;
}
