/**
 * Règles de créneau du planning côté serveur.
 *
 * Ces décisions existent en double, ici et dans
 * `lib/features/planning/domain/planning_slot_rules.dart`. Le serveur les
 * applique pour composer le prompt et dédoublonner la réponse du modèle, le
 * client les rejoue quand un créneau revient vide.
 *
 * Un écart ne casse aucun écran et ne lève aucune erreur : il laisse passer un
 * dessert d'un côté, ou décale d'une semaine un jour de préparation de l'autre.
 * Les cas viennent donc de la fixture partagée, rejouée par les deux suites.
 *
 * Logique pure : ni Firestore, ni réseau, ni appel de modèle.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import {
  asksForDessert,
  isDessertBag,
  slotKind,
  computePrepDate,
  applyRecentlyServed,
  type PlanningRecipeSummary,
} from "../gemini/planning";

const FIXTURE = path.join(__dirname, "..", "..", "..", "test-fixtures", "planning_slot_rules.json");

interface Fixture {
  asks_for_dessert: Array<{ global: string; notes: string; expected: boolean; why: string }>;
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

describe("demande explicite de sucré", () => {
  test("la fixture partagée est non vide", () => {
    assert.ok(fixture.asks_for_dessert.length > 0);
  });

  for (const c of fixture.asks_for_dessert) {
    test(`« ${c.global} » / « ${c.notes} » (${c.why})`, () => {
      assert.equal(asksForDessert(c.global, c.notes), c.expected);
    });
  }
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
