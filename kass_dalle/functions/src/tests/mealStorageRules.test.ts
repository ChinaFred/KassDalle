/**
 * Règles de conservation d'un plat préparé à l'avance, côté serveur.
 *
 * Dupliquées dans `lib/features/planning/domain/meal_storage_rules.dart` : le
 * client les applique pour afficher la consigne dans le planning, le serveur
 * pour cadrer le prompt de conservation.
 *
 * Un écart ne casse aucun écran et ne lève aucune erreur — il fait seulement
 * dire à l'un qu'un plat tient au réfrigérateur quand l'autre le fait congeler.
 * C'est une règle d'hygiène alimentaire : elle ne se devine pas à la lecture.
 *
 * Logique pure : ni Firestore, ni réseau, ni appel de modèle.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import { mealStorageMode, MAX_FRIDGE_DAYS } from "../gemini/storageAdvice";

const FIXTURE = path.join(__dirname, "..", "..", "..", "test-fixtures", "meal_storage_rules.json");

interface Fixture {
  max_fridge_days: number;
  modes: Array<{ days_ahead: number; expected: string; why: string }>;
  days_ahead: Array<{ prep_date: string; meal_date: string; expected: number; why: string }>;
}

const fixture = JSON.parse(readFileSync(FIXTURE, "utf8")) as Fixture;

/** Jours calendaires entre deux dates ISO — le jumeau de `mealStorageDaysAhead`. */
function daysBetween(prepDate: string, mealDate: string): number {
  const from = Date.parse(`${prepDate}T00:00:00Z`);
  const to = Date.parse(`${mealDate}T00:00:00Z`);
  return Math.round((to - from) / 86_400_000);
}

test("la limite du réfrigérateur est la même des deux côtés", () => {
  assert.equal(MAX_FRIDGE_DAYS, fixture.max_fridge_days);
});

describe("mode de conservation", () => {
  test("la fixture partagée est non vide", () => {
    assert.ok(fixture.modes.length > 0);
  });

  for (const c of fixture.modes) {
    test(`${c.days_ahead} jours d'avance (${c.why})`, () => {
      assert.equal(mealStorageMode(c.days_ahead), c.expected);
    });
  }
});

describe("délai entre préparation et repas", () => {
  test("la fixture partagée est non vide", () => {
    assert.ok(fixture.days_ahead.length > 0);
  });

  for (const c of fixture.days_ahead) {
    test(`${c.prep_date} → ${c.meal_date} (${c.why})`, () => {
      assert.equal(daysBetween(c.prep_date, c.meal_date), c.expected);
    });
  }
});
