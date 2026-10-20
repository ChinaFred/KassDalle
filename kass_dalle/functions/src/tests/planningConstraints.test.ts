/**
 * Préférences comprises — lecture de la réponse du modèle, cache, et leur
 * effet sur la génération (critères par créneau, prompt, écarts rendus).
 *
 * Une erreur ici ne casse aucun écran : une valeur inventée par le modèle
 * écarterait des plats à tort, un texte compris mais perdu ne partirait plus
 * au prompt. Logique pure : ni Firestore, ni réseau, ni appel de modèle.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  CONSTRAINT_TEXT_MAX_CHARS,
  PLANNING_CONSTRAINTS_PROMPT_VERSION,
  buildConstraintsPrompt,
  constraintTextHash,
  parseConstraintsAnswer,
  planningRunCost,
  translationFitsCap,
  translationSpentUsd,
  type TextUnderstanding,
} from "../gemini/planningConstraints";
import { readConstraintCache } from "../gemini/planningConstraintsStore";
import { EMPTY_CRITERIA, readPlanningCriteria } from "../gemini/planningCriteria";
import {
  DEFAULT_PLANNING_POLICY,
  buildPlanningPrompt,
  criteriaItemOf,
  isLightRecipe,
  planningTexts,
  preselect,
  seededRng,
  slotCriteriaOf,
  validateModelChoices,
  type PlanningInput,
  type PlanningRecipeSummary,
} from "../gemini/planning";

describe("réponse du modèle", () => {
  const texts = ["Pas de porc, 30 min max", "pas trop gras", "sans noix"];

  test("valeurs hors vocabulaire écartées, reste recopié", () => {
    const out = parseConstraintsAnswer(
      {
        textes: [
          {
            index: 0,
            proteines_exclues: ["porc", "jambon"],
            preparation_max_min: 30,
            non_traduit: "",
          },
          { index: 1, non_traduit: "pas trop gras" },
          { index: 2, allergenes_exclus: ["fruits_a_coque", "noix"], non_traduit: "" },
        ],
      },
      texts,
    );
    assert.ok(out);
    assert.deepEqual(out.get(0)?.criteria.excludedProteins, ["porc"]);
    assert.equal(out.get(0)?.criteria.maxDuration, 30);
    assert.equal(out.get(0)?.untranslated, "");
    assert.deepEqual(out.get(1)?.criteria, EMPTY_CRITERIA);
    assert.equal(out.get(1)?.untranslated, "pas trop gras");
    assert.deepEqual(out.get(2)?.criteria.excludedAllergens, ["fruits_a_coque"]);
  });

  test("index hors bornes ou en double ignoré ; texte sans réponse absent", () => {
    const out = parseConstraintsAnswer(
      {
        textes: [
          { index: 5, non_traduit: "" },
          { index: 0, proteines_exclues: ["porc"], non_traduit: "" },
          { index: 0, proteines_exclues: ["boeuf"], non_traduit: "" },
          { index: 1.5, non_traduit: "" },
          "abîmé",
        ],
      },
      texts,
    );
    assert.ok(out);
    assert.deepEqual([...out.keys()], [0]);
    assert.deepEqual(out.get(0)?.criteria.excludedProteins, ["porc"]);
  });

  test("non_traduit absent : tout le texte reste non vérifié ; plus long : ramené au texte", () => {
    const out = parseConstraintsAnswer(
      {
        textes: [
          { index: 0, proteines_exclues: ["porc"] },
          { index: 1, non_traduit: "pas trop gras et bien d'autres choses encore" },
        ],
      },
      texts,
    );
    assert.equal(out?.get(0)?.untranslated, "Pas de porc, 30 min max");
    assert.equal(out?.get(1)?.untranslated, "pas trop gras");
  });

  test("forme qui ne tient pas : null", () => {
    assert.equal(parseConstraintsAnswer(null, texts), null);
    assert.equal(parseConstraintsAnswer({ textes: "porc" }, texts), null);
    assert.equal(parseConstraintsAnswer([], texts), null);
  });

  test("le prompt numérote les textes et cite le vocabulaire, sans exemple rempli", () => {
    const prompt = buildConstraintsPrompt(texts);
    assert.ok(prompt.includes("--- texte 0 ---\nPas de porc, 30 min max"));
    assert.ok(prompt.includes("--- texte 2 ---\nsans noix"));
    assert.ok(prompt.includes("fruits_a_coque (Fruits à coque)"));
    assert.ok(prompt.includes("legumineuses"));
    assert.ok(!prompt.includes('"index": 0'));
  });

  test("empreinte : le texte sans espaces en bord", () => {
    assert.equal(constraintTextHash("  sans porc "), constraintTextHash("sans porc"));
    assert.notEqual(constraintTextHash("sans porc"), constraintTextHash("sans boeuf"));
    assert.match(constraintTextHash("x"), /^[0-9a-f]{64}$/);
    assert.ok(CONSTRAINT_TEXT_MAX_CHARS >= 1000);
  });
});

describe("plafond de la génération", () => {
  test("la traduction part si son coût plafond tient dans le plafond", () => {
    assert.equal(translationFitsCap({ capUsd: 0.5, estimateUsd: 0.02 }), true);
    assert.equal(translationFitsCap({ capUsd: 0.5, estimateUsd: 0.5 }), true);
    assert.equal(translationFitsCap({ capUsd: 0.01, estimateUsd: 0.02 }), false);
  });

  test("sans plafond ou sans estimation : aucun chiffre inventé, elle part", () => {
    assert.equal(translationFitsCap({ capUsd: null, estimateUsd: 9 }), true);
    assert.equal(translationFitsCap({ capUsd: 0.01, estimateUsd: null }), true);
  });

  test("retiré du plafond : coût enregistré, à défaut estimation, sans appel rien", () => {
    assert.equal(
      translationSpentUsd({ called: true, recordedUsd: 0.003, estimateUsd: 0.02 }),
      0.003,
    );
    assert.equal(translationSpentUsd({ called: true, recordedUsd: null, estimateUsd: 0.02 }), 0.02);
    assert.equal(translationSpentUsd({ called: true, recordedUsd: null, estimateUsd: null }), 0);
    assert.equal(translationSpentUsd({ called: false, recordedUsd: 0.003, estimateUsd: 0.02 }), 0);
  });
});

describe("coût du document de génération", () => {
  test("traduction sans montant : son estimation entre dans cost_usd, et compte sans montant", () => {
    const run = planningRunCost({
      modelCall: { costUsd: 0.01 },
      translation: { called: true, costUsd: null, spentUsd: 0.02 },
    });
    assert.ok(run.costUsd >= 0.02);
    assert.ok(Math.abs(run.costUsd - 0.03) < 1e-12);
    assert.equal(run.unpricedCalls, 1);
  });

  test("traduction avec montant : son coût, aucun appel sans montant", () => {
    const run = planningRunCost({
      modelCall: { costUsd: 0.01 },
      translation: { called: true, costUsd: 0.004, spentUsd: 0.004 },
    });
    assert.ok(Math.abs(run.costUsd - 0.014) < 1e-12);
    assert.equal(run.unpricedCalls, 0);
  });

  test("sans traduction ni appel de planning : rien", () => {
    assert.deepEqual(
      planningRunCost({
        modelCall: null,
        translation: { called: false, costUsd: null, spentUsd: 0 },
      }),
      { costUsd: 0, unpricedCalls: 0 },
    );
    assert.deepEqual(planningRunCost({ modelCall: { costUsd: null }, translation: null }), {
      costUsd: 0,
      unpricedCalls: 1,
    });
  });
});

describe("cache des préférences comprises", () => {
  test("entrée d'une autre version, abîmée ou sans texte : ignorée", () => {
    const cache = readConstraintCache({
      entries: {
        a: {
          text: "sans porc",
          criteria: { excluded_proteins: ["porc", "jambon"] },
          untranslated: "",
          prompt_version: PLANNING_CONSTRAINTS_PROMPT_VERSION,
          translated_at: { toMillis: () => 1000 },
        },
        b: { text: "vieux", prompt_version: 0 },
        c: "abîmée",
        d: { prompt_version: PLANNING_CONSTRAINTS_PROMPT_VERSION },
      },
    });
    assert.deepEqual([...cache.keys()], ["a"]);
    assert.deepEqual(cache.get("a")?.understanding.criteria.excludedProteins, ["porc"]);
    assert.equal(cache.get("a")?.translatedAtMs, 1000);
  });

  test("document absent ou mal formé : vide", () => {
    assert.equal(readConstraintCache(null).size, 0);
    assert.equal(readConstraintCache({ entries: [] }).size, 0);
  });
});

function inputWith(
  recipes: PlanningRecipeSummary[],
  opts: { global?: string; notes?: string; format?: string } = {},
): PlanningInput {
  return {
    recipes,
    slotDates: ["2026-10-14"],
    dailyConstraints: {},
    slotConstraints: [
      opts.notes != null || opts.format != null
        ? {
            ...(opts.notes != null ? { notes: opts.notes } : {}),
            ...(opts.format != null ? { mealFormat: opts.format } : {}),
          }
        : null,
    ],
    globalConstraints: opts.global ?? "",
  };
}

const understood = (
  entries: Array<[string, Record<string, unknown>, string]>,
): Map<string, TextUnderstanding> =>
  new Map(
    entries.map(([text, criteria, untranslated]) => [
      text,
      { criteria: readPlanningCriteria(criteria), untranslated },
    ]),
  );

describe("critères d'une génération", () => {
  test("textes : préférences générales et notes, une fois chacun", () => {
    const input = inputWith([], { global: "  sans porc ", notes: "sans porc" });
    assert.deepEqual(planningTexts(input), ["sans porc"]);
  });

  test("créneau : préférences générales et note du jour réunies", () => {
    const input = inputWith([], { global: "sans porc", notes: "30 min max" });
    const [c] = slotCriteriaOf(
      input,
      understood([
        ["sans porc", { excluded_proteins: ["porc"] }, ""],
        ["30 min max", { max_duration: 30 }, ""],
      ]),
    );
    assert.deepEqual(c.excludedProteins, ["porc"]);
    assert.equal(c.maxDuration, 30);
  });

  test("léger : entrée, en-cas, soupe ou salade ; un autre plat ne l'est pas ; sans rôle : inconnu", () => {
    assert.equal(isLightRecipe({ id: "a", titre: "a", mealRole: "entree" }), true);
    assert.equal(
      isLightRecipe({ id: "b", titre: "b", mealRole: "plat", dishTypes: ["Velouté"] }),
      true,
    );
    assert.equal(isLightRecipe({ id: "c", titre: "c", mealRole: "plat" }), false);
    assert.equal(isLightRecipe({ id: "d", titre: "d" }), null);
  });

  test("allergènes envoyés par le client : relus, donnée non fiable", () => {
    const item = criteriaItemOf({
      id: "a",
      titre: "a",
      allergens: { present: ["gluten", 3], complete: "oui" },
    });
    assert.deepEqual(item.allergens, { present: ["gluten"], complete: false });
    assert.equal(criteriaItemOf({ id: "b", titre: "b" }).allergens, null);
  });
});

describe("effet sur la génération", () => {
  const recipes: PlanningRecipeSummary[] = [
    { id: "p1", titre: "Rôti de porc", mealRole: "plat", mainProtein: "porc" },
    {
      id: "p2",
      titre: "Poulet rôti",
      mealRole: "plat",
      mainProtein: "volaille",
      prepTime: 70,
      allergens: { present: [], complete: true },
    },
    {
      id: "d1",
      titre: "Tarte aux noix",
      mealRole: "dessert",
      allergens: { present: ["fruits_a_coque"], complete: true },
    },
  ];

  test("prompt : les critères vérifiés cités, le reste du texte transmis", () => {
    const input = inputWith(recipes, { global: "Pas de porc, pas trop gras" });
    const known = understood([
      ["Pas de porc, pas trop gras", { excluded_proteins: ["porc"] }, "pas trop gras"],
    ]);
    const rankings = preselect({
      input,
      candidates: recipes,
      recentExcluded: [],
      lastServed: new Map(),
      ratings: new Map(),
      historyAvailable: false,
      policy: DEFAULT_PLANNING_POLICY,
      today: "2026-10-10",
      rng: seededRng(1),
      criteriaBySlot: slotCriteriaOf(input, known),
    });
    const { prompt } = buildPlanningPrompt({
      input,
      rankings,
      sentSlots: new Set([0]),
      corpusById: new Map(recipes.map((r) => [r.id, r])),
      rng: seededRng(1),
      understood: known,
    });
    assert.ok(prompt.includes("=== CRITÈRES VÉRIFIÉS (déjà appliqués aux candidats) ==="));
    assert.ok(prompt.includes("sans porc en protéine principale"));
    assert.ok(prompt.includes("=== PRÉFÉRENCES GÉNÉRALES ===\npas trop gras"));
    assert.ok(!prompt.includes("Pas de porc, pas trop gras"));
    assert.ok(!prompt.includes("p1 |"), "le plat au porc n'est pas candidat");
  });

  test("texte non compris : transmis tel quel, comme avant", () => {
    const input = inputWith(recipes, { global: "Pas de porc" });
    const { prompt } = buildPlanningPrompt({
      input,
      rankings: [],
      sentSlots: new Set(),
      corpusById: new Map(),
      rng: seededRng(1),
    });
    assert.ok(prompt.includes("=== PRÉFÉRENCES GÉNÉRALES ===\nPas de porc"));
    assert.ok(!prompt.includes("CRITÈRES VÉRIFIÉS"));
  });

  test("le repas rendu porte ses écarts : durée relâchée, dessert vidé par une exclusion", () => {
    const input = inputWith(recipes, { notes: "sans noix, 45 min max", format: "plat_dessert" });
    const known = understood([
      [
        "sans noix, 45 min max",
        { excluded_allergens: ["fruits_a_coque"], excluded_proteins: ["porc"], max_duration: 45 },
        "",
      ],
    ]);
    const rankings = preselect({
      input,
      candidates: recipes,
      recentExcluded: [],
      lastServed: new Map(),
      ratings: new Map(),
      historyAvailable: false,
      policy: DEFAULT_PLANNING_POLICY,
      today: "2026-10-10",
      rng: seededRng(1),
      criteriaBySlot: slotCriteriaOf(input, known),
    });
    assert.deepEqual(rankings[0].relaxed, ["in_cycle", "variety_window", "max_duration"]);
    const { slots } = validateModelChoices({
      raw: null,
      rankings,
      input,
      corpusById: new Map(recipes.map((r) => [r.id, r])),
      sentSlots: new Set(),
    });
    assert.equal(slots[0].recipeId, "p2");
    assert.equal(slots[0].dessertId, undefined);
    assert.deepEqual(
      (slots[0].unmet ?? []).map((u) => [u.service, u.key, u.status, u.detail]),
      [
        [
          "plat",
          "max_duration",
          "relaxed",
          "1 h 10, au-delà des 45 min demandées : peu d'autres choix",
        ],
        ["dessert", "excluded_allergens", "empty", "Aucun dessert sans fruits à coque."],
      ],
    );
  });
});
