/**
 * Règles de créneau du planning — serveur seul.
 *
 * Le serveur les applique pour composer le prompt et lire la réponse du
 * modèle : le format d'un créneau (entrée ? dessert ? repas léger ?), le rôle
 * sous lequel une recette est proposée, la nature du créneau, le jour de
 * préparation, la fenêtre de variété.
 *
 * Un écart ne casse aucun écran et ne lève aucune erreur : il laisse passer un
 * dessert en plat, ou décale d'une semaine un jour de préparation. Les cas
 * viennent donc de la fixture `planning_slot_rules.json`.
 *
 * Logique pure : ni Firestore, ni réseau, ni appel de modèle.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import {
  isDessertBag,
  slotKind,
  computePrepDate,
  applyRecentlyServed,
  mealFormatOf,
  planningRoleOf,
  partitionByRole,
  type PlanningRecipeSummary,
} from "../gemini/planning";

const FIXTURE = path.join(__dirname, "..", "..", "..", "test-fixtures", "planning_slot_rules.json");

interface Fixture {
  meal_format: Array<{
    key: string | null;
    expected: { wantsStarter: boolean; wantsDessert: boolean; light: boolean };
    why: string;
  }>;
  planning_role: Array<{
    meal_role: string | null;
    attributes: string[];
    expected: string;
    why: string;
  }>;
  is_dessert: Array<{ attributes: string[]; expected: boolean; why: string }>;
  slot_kind: Array<{
    slot_weekday: number;
    is_reheat_constraint: boolean;
    batch_cooking_day: number | null;
    expected: string;
    why: string;
  }>;
  prep_date: Array<{
    slot_date: string;
    batch_weekday: number;
    expected: string;
    why: string;
  }>;
  recently_served: Array<{
    corpus: string[];
    served: Array<{ recipe_id: string; date: string }>;
    slots_to_fill: number;
    expected_candidates: string[];
    expected_excluded: string[];
    expected_kept: string[];
    why: string;
  }>;
}

const fixture = JSON.parse(readFileSync(FIXTURE, "utf8")) as Fixture;

describe("format d'un créneau", () => {
  test("la fixture partagée est non vide", () => {
    assert.ok(fixture.meal_format.length > 0);
  });

  for (const c of fixture.meal_format) {
    test(`${c.key === null ? "(absent)" : `« ${c.key} »`} (${c.why})`, () => {
      const spec = mealFormatOf(c.key);
      assert.deepEqual(
        { wantsStarter: spec.wantsStarter, wantsDessert: spec.wantsDessert, light: spec.light },
        c.expected,
      );
    });
  }
});

/** Une recette de la fixture : le titre d'abord, les types de plat ensuite. */
function recipeOf(c: { meal_role: string | null; attributes: string[] }): PlanningRecipeSummary {
  return {
    id: "x",
    titre: c.attributes[0] ?? "",
    dishTypes: c.attributes.slice(1),
    mealRole: c.meal_role,
  };
}

describe("rôle sous lequel une recette est proposée", () => {
  test("la fixture partagée est non vide", () => {
    assert.ok(fixture.planning_role.length > 0);
  });

  for (const c of fixture.planning_role) {
    test(`${c.meal_role ?? "(sans rôle)"} · ${c.attributes.join(" · ")} (${c.why})`, () => {
      assert.equal(planningRoleOf(recipeOf(c)), c.expected);
    });
  }

  test("les listes du prompt : plats, entrées, desserts, en-cas — jamais un accompagnement", () => {
    const out = partitionByRole(
      fixture.planning_role.map((c, i) => ({ ...recipeOf(c), id: `r${i}` })),
    );
    const roles = (list: PlanningRecipeSummary[]) => list.map((r) => planningRoleOf(r));
    assert.ok(roles(out.plats).every((r) => r === "plat"));
    assert.ok(roles(out.entrees).every((r) => r === "entree"));
    assert.ok(roles(out.desserts).every((r) => r === "dessert"));
    assert.ok(roles(out.encas).every((r) => r === "snack"));
    const listed = out.plats.length + out.entrees.length + out.desserts.length + out.encas.length;
    const accompagnements = fixture.planning_role.filter(
      (c) => c.expected === "accompagnement",
    ).length;
    assert.equal(listed, fixture.planning_role.length - accompagnements);
  });
});

describe("recette sucrée", () => {
  test("la fixture partagée est non vide", () => {
    assert.ok(fixture.is_dessert.length > 0);
  });

  for (const c of fixture.is_dessert) {
    test(`${c.attributes.join(" · ")} (${c.why})`, () => {
      assert.equal(isDessertBag(c.attributes), c.expected);
    });
  }
});

describe("nature du créneau", () => {
  test("la fixture partagée est non vide", () => {
    assert.ok(fixture.slot_kind.length > 0);
  });

  for (const c of fixture.slot_kind) {
    test(`jour ${c.slot_weekday} (${c.why})`, () => {
      assert.equal(
        slotKind(c.slot_weekday, c.is_reheat_constraint, c.batch_cooking_day),
        c.expected,
      );
    });
  }
});

describe("jour de préparation à l'avance", () => {
  test("la fixture partagée est non vide", () => {
    assert.ok(fixture.prep_date.length > 0);
  });

  for (const c of fixture.prep_date) {
    test(`${c.slot_date} depuis le jour ${c.batch_weekday} (${c.why})`, () => {
      assert.equal(computePrepDate(c.slot_date, c.batch_weekday), c.expected);
    });
  }
});

describe("fenêtre de variété : recettes servies avant le cycle", () => {
  test("la fixture partagée est non vide", () => {
    assert.ok(fixture.recently_served.length > 0);
  });

  for (const c of fixture.recently_served) {
    test(`${c.corpus.join(",")} moins ${c.served.map((s) => s.recipe_id).join(",")} (${c.why})`, () => {
      const corpus: PlanningRecipeSummary[] = c.corpus.map((id) => ({
        id,
        titre: `Recette ${id}`,
      }));
      const served = c.served.map((s) => ({ recipeId: s.recipe_id, date: s.date }));
      const out = applyRecentlyServed(corpus, served, c.slots_to_fill);
      assert.deepEqual(
        out.candidates.map((r) => r.id),
        c.expected_candidates,
      );
      assert.deepEqual(out.excludedIds, c.expected_excluded);
      assert.deepEqual(out.keptRecentIds, c.expected_kept);
    });
  }

  test("le corpus d'origine n'est pas modifié", () => {
    const corpus: PlanningRecipeSummary[] = [
      { id: "a", titre: "A" },
      { id: "b", titre: "B" },
    ];
    applyRecentlyServed(corpus, [{ recipeId: "a", date: "2026-09-01" }], 1);
    assert.deepEqual(
      corpus.map((r) => r.id),
      ["a", "b"],
    );
  });
});
