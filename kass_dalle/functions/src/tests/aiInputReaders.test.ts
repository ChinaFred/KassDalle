/**
 * Lecture en liste blanche des entrées structurées (refine, search, planning,
 * planning_concept).
 *
 * Verrouille deux constats de la relecture sécurité de la v0.23.11 :
 * `currentPortions` et `batchCookingDay` partaient au prompt sans contrôle,
 * et l'objet du client était transmis entier au générateur.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { HttpsError } from "firebase-functions/v2/https";

import {
  PORTIONS_MAX,
  readConceptInput,
  readPlanningInput,
  readRefineInput,
  readSearchInput,
} from "../callable/_aiInputReaders";
import { AiInputSizes, requireBoundedNumber } from "../callable/_inputBounds";

function assertInvalid(fn: () => unknown, pattern: RegExp): void {
  assert.throws(fn, (err: unknown) => {
    assert.ok(err instanceof HttpsError, "HttpsError attendue");
    assert.equal(err.code, "invalid-argument");
    assert.match(err.message, pattern);
    return true;
  });
}

const refineBase = {
  instruction: "moins salé",
  currentCooklang: "Saler @sel{1%pincée}.",
  currentTitre: "Soupe",
  currentIngredients: [{ name: "sel", qty: "1", unit: "pincée" }],
  currentTags: { cuisines: ["française"] },
  currentPortions: 4,
};

const planningBase = {
  slotDates: ["2026-10-12", "2026-10-13"],
  recipes: [{ id: "r1", titre: "Soupe" }],
  globalConstraints: "sans porc",
  dailyConstraints: { "1": { maxPrepMinutes: 30 } },
};

describe("requireBoundedNumber", () => {
  test("bornes incluses, hors bornes refusé", () => {
    const opts = { field: "n", min: 1, max: 7, integer: true };
    assert.equal(requireBoundedNumber(1, opts), 1);
    assert.equal(requireBoundedNumber(7, opts), 7);
    assertInvalid(() => requireBoundedNumber(0, opts), /« n » doit être compris entre 1 et 7/);
    assertInvalid(() => requireBoundedNumber(8, opts), /entre 1 et 7/);
  });

  test("texte, NaN, infini et décimal (si entier exigé) refusés", () => {
    const opts = { field: "n", min: 1, max: 7, integer: true };
    assertInvalid(() => requireBoundedNumber("3", opts), /doit être un nombre entier/);
    assertInvalid(() => requireBoundedNumber(Number.NaN, opts), /nombre entier/);
    assertInvalid(() => requireBoundedNumber(Infinity, opts), /nombre entier/);
    assertInvalid(() => requireBoundedNumber(2.5, opts), /nombre entier/);
  });

  test("absent : undefined, ou refusé si requis", () => {
    assert.equal(requireBoundedNumber(null, { field: "n", min: 0, max: 1 }), undefined);
    assertInvalid(
      () => requireBoundedNumber(undefined, { field: "n", min: 0, max: 1, required: true }),
      /est requis/,
    );
  });
});

describe("readRefineInput", () => {
  test("currentPortions de 10 000 caractères : refusé", () => {
    assertInvalid(
      () =>
        readRefineInput({ ...refineBase, currentPortions: "x".repeat(10_000) }, new AiInputSizes()),
      /« currentPortions » doit être un nombre/,
    );
  });

  test("currentPortions hors bornes refusé, absent rendu null", () => {
    assertInvalid(
      () =>
        readRefineInput({ ...refineBase, currentPortions: PORTIONS_MAX + 1 }, new AiInputSizes()),
      /currentPortions/,
    );
    const { currentPortions: _omitted, ...withoutPortions } = refineBase;
    assert.equal(readRefineInput(withoutPortions, new AiInputSizes()).currentPortions, null);
  });

  test("un champ inconnu n'arrive pas dans l'objet transmis", () => {
    const inputs = new AiInputSizes();
    const out = readRefineInput({ ...refineBase, injected: "x".repeat(1_000) }, inputs);
    assert.deepEqual(Object.keys(out).sort(), [
      "currentCooklang",
      "currentIngredients",
      "currentPortions",
      "currentTags",
      "currentTitre",
      "instruction",
    ]);
    assert.equal(out.currentPortions, 4);
    assert.equal(inputs.sizes.currentPortions, 1);
    assert.equal(inputs.sizes.injected, undefined);
  });
});

describe("readPlanningInput", () => {
  test("batchCookingDay de 10 000 caractères : refusé", () => {
    assertInvalid(
      () =>
        readPlanningInput(
          { ...planningBase, batchCookingDay: "x".repeat(10_000) },
          new AiInputSizes(),
        ),
      /« batchCookingDay » doit être un nombre entier/,
    );
  });

  test("batchCookingDay = 3 : accepté et transmis", () => {
    const inputs = new AiInputSizes();
    const out = readPlanningInput({ ...planningBase, batchCookingDay: 3 }, inputs);
    assert.equal(out.batchCookingDay, 3);
    assert.equal(inputs.sizes.batchCookingDay, 1);
  });

  test("batchCookingDay hors de 1 à 7 refusé, absent non transmis", () => {
    for (const day of [0, 8, 2.5]) {
      assertInvalid(
        () => readPlanningInput({ ...planningBase, batchCookingDay: day }, new AiInputSizes()),
        /batchCookingDay/,
      );
    }
    const out = readPlanningInput({ ...planningBase, batchCookingDay: null }, new AiInputSizes());
    assert.ok(!("batchCookingDay" in out));
  });

  test("un champ inconnu n'arrive pas dans l'objet transmis", () => {
    const out = readPlanningInput(
      { ...planningBase, alreadyAssigned: [], injected: "x".repeat(1_000) },
      new AiInputSizes(),
    );
    assert.deepEqual(Object.keys(out).sort(), [
      "alreadyAssigned",
      "dailyConstraints",
      "globalConstraints",
      "recipes",
      "slotDates",
    ]);
  });
});

describe("readSearchInput et readConceptInput", () => {
  test("search : un champ inconnu n'arrive pas, listes absentes rendues vides", () => {
    const out = readSearchInput({ query: "soupe", injected: "x" }, new AiInputSizes());
    assert.deepEqual(out, { query: "soupe", recipes: [], ratedRecipes: [] });
  });

  test("planning_concept : un champ inconnu n'arrive pas", () => {
    const out = readConceptInput(
      {
        slotDate: "2026-10-12",
        globalConstraints: "sans porc",
        requestedDish: { titre: "Soupe" },
        injected: "x",
      },
      new AiInputSizes(),
    );
    assert.deepEqual(out, {
      slotDate: "2026-10-12",
      globalConstraints: "sans porc",
      requestedDish: { titre: "Soupe" },
    });
  });
});
