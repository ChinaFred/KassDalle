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

import { asksForDessert, isDessertBag, slotKind, computePrepDate } from "../gemini/planning";

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
