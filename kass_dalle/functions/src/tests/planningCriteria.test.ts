/**
 * Critères structurés du planning — lecture, réunion et prédicat.
 *
 * Un écart ici ne lève aucune erreur : un allergène mal lu laisse passer un
 * dessert aux noisettes, une donnée absente comptée comme vérifiée fait dire
 * « sans gluten » d'un plat qui en contient peut-être. La fixture
 * `planning_criteria.json` est rejouée par le client
 * (`test/planning_criteria_test.dart`) pour la lecture, la réunion et les
 * exclusions ; les préférences sont serveur seul.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import {
  CRITERION_REGIMES,
  MAX_DURATION_MAX,
  MAX_DURATION_MIN,
  checkExclusions,
  checkPreferences,
  describeCriteria,
  emptyServiceDetail,
  formatMinutes,
  mergeCriteria,
  planningCriteriaToMap,
  readPlanningCriteria,
  unmetDetail,
  type CriteriaItem,
} from "../gemini/planningCriteria";

interface FixtureItem {
  allergens?: { present: string[]; complete: boolean } | null;
  main_protein?: string;
  main_starch?: string;
  prep_minutes?: number;
  light?: boolean;
}

interface CheckCase {
  name: string;
  criteria: Record<string, unknown>;
  item: FixtureItem;
  expected: Array<{ key: string; verdict: string; values: string[] }>;
}

interface Fixture {
  criteria: Array<{ key: string; regime: string }>;
  max_duration_bounds: { min: number; max: number };
  read_cases: Array<{ name: string; raw: unknown; expected: Record<string, unknown> }>;
  merge_cases: Array<{
    name: string;
    parts: Record<string, unknown>[];
    expected: Record<string, unknown>;
  }>;
  exclusion_cases: CheckCase[];
  preference_cases: CheckCase[];
}

const FIXTURE = path.join(__dirname, "..", "..", "..", "test-fixtures", "planning_criteria.json");
const fixture = JSON.parse(readFileSync(FIXTURE, "utf8")) as Fixture;

function itemOf(raw: FixtureItem): CriteriaItem {
  return {
    allergens: raw.allergens ?? null,
    mainProtein: raw.main_protein ?? null,
    mainStarch: raw.main_starch ?? null,
    prepMinutes: raw.prep_minutes ?? null,
    light: raw.light ?? null,
  };
}

describe("vocabulaire partagé avec le client", () => {
  test("mêmes clés, même ordre, mêmes régimes", () => {
    assert.deepEqual(
      Object.keys(CRITERION_REGIMES),
      fixture.criteria.map((c) => c.key),
    );
    for (const c of fixture.criteria) {
      assert.equal(CRITERION_REGIMES[c.key as keyof typeof CRITERION_REGIMES], c.regime, c.key);
    }
  });

  test("bornes de la durée", () => {
    assert.equal(MAX_DURATION_MIN, fixture.max_duration_bounds.min);
    assert.equal(MAX_DURATION_MAX, fixture.max_duration_bounds.max);
  });
});

describe("lecture d'un objet de critères", () => {
  for (const c of fixture.read_cases) {
    test(c.name, () => {
      assert.deepEqual(planningCriteriaToMap(readPlanningCriteria(c.raw)), c.expected);
    });
  }
});

describe("réunion des critères d'un créneau", () => {
  for (const c of fixture.merge_cases) {
    test(c.name, () => {
      const merged = mergeCriteria(c.parts.map(readPlanningCriteria));
      assert.deepEqual(planningCriteriaToMap(merged), c.expected);
    });
  }
});

describe("prédicat d'exclusion", () => {
  for (const c of fixture.exclusion_cases) {
    test(c.name, () => {
      const results = checkExclusions(readPlanningCriteria(c.criteria), itemOf(c.item));
      assert.deepEqual(
        results.map((r) => ({ key: r.key, verdict: r.verdict, values: r.values })),
        c.expected,
      );
      for (const r of results) assert.equal(r.regime, "exclusion");
    });
  }
});

describe("prédicat des préférences (serveur seul)", () => {
  for (const c of fixture.preference_cases) {
    test(c.name, () => {
      const results = checkPreferences(readPlanningCriteria(c.criteria), itemOf(c.item));
      assert.deepEqual(
        results.map((r) => ({ key: r.key, verdict: r.verdict, values: r.values })),
        c.expected,
      );
      for (const r of results) assert.equal(r.regime, "preference");
    });
  }
});

describe("phrases", () => {
  test("durées", () => {
    assert.equal(formatMinutes(45), "45 min");
    assert.equal(formatMinutes(70), "1 h 10");
    assert.equal(formatMinutes(120), "2 h");
  });

  test("durée relâchée : la valeur retenue et la valeur demandée", () => {
    const c = readPlanningCriteria({ max_duration: 45 });
    const item = itemOf({ prep_minutes: 70 });
    const [r] = checkPreferences(c, item);
    assert.equal(
      unmetDetail(r, c, item),
      "1 h 10, au-delà des 45 min demandées : peu d'autres choix",
    );
  });

  test("service vide par une exclusion", () => {
    const c = readPlanningCriteria({ excluded_allergens: ["fruits_a_coque"] });
    assert.equal(emptyServiceDetail("dessert", c), "Aucun dessert sans fruits à coque.");
    assert.equal(emptyServiceDetail("entree", c), "Aucune entrée sans fruits à coque.");
  });

  test("allergènes non vérifiés", () => {
    const c = readPlanningCriteria({ excluded_allergens: ["gluten"] });
    const item = itemOf({ allergens: null });
    const [r] = checkExclusions(c, item);
    assert.equal(unmetDetail(r, c, item), "Allergènes non vérifiés : gluten");
  });

  test("critères en clair pour le prompt", () => {
    const c = readPlanningCriteria({
      excluded_proteins: ["porc"],
      excluded_allergens: ["gluten"],
      max_duration: 30,
    });
    assert.equal(
      describeCriteria(c),
      "sans porc en protéine principale · sans gluten (allergènes) · 30 min de préparation au plus",
    );
  });
});
