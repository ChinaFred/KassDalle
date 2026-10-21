/**
 * « Reprendre le sel des ingrédients » (`refresh_sodium`) : sélection des
 * cibles, marque écrite sur un ingrédient réparé, fin de parcours.
 *
 * Logique pure : aucun appel de modèle, aucune lecture Firestore.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { FieldValue } from "firebase-admin/firestore";

import {
  enrichPassCompleted,
  enrichedIngredientPayload,
  isSodiumRepairTarget,
  summarizeEnrichReferentials,
  type BackfillEnrichReferentialsResponse,
} from "../callable/billingCallable";
import { passStatus, shouldAutoMarkDone } from "../backfills/schedule";

describe("sélection des ingrédients à réparer", () => {
  test("porte du sodium, jamais réparé : cible", () => {
    assert.equal(isSodiumRepairTarget({ per100g: { sodium_mg: 400 } }), true);
    assert.equal(isSodiumRepairTarget({ per100g: { salt_g: "1,2" } }), true);
  });
  test("déjà réparé : plus cible, même s'il porte toujours du sodium", () => {
    assert.equal(
      isSodiumRepairTarget({ per100g: { sodium_mg: 400 }, sodium_repaired_at: new Date() }),
      false,
    );
  });
  test("marque nulle : toujours cible", () => {
    assert.equal(
      isSodiumRepairTarget({ per100g: { sodium_mg: 400 }, sodium_repaired_at: null }),
      true,
    );
  });
  test("sans sodium, profil absent ou document absent : pas cible", () => {
    assert.equal(isSodiumRepairTarget({ per100g: { sodium_mg: 0, salt_g: 0 } }), false);
    assert.equal(isSodiumRepairTarget({ per100g: { kcal: 364 } }), false);
    assert.equal(isSodiumRepairTarget({}), false);
    assert.equal(isSodiumRepairTarget(undefined), false);
  });
});

describe("écriture d'un ingrédient estimé", () => {
  test("mode sel : la marque part avec le profil", () => {
    const payload = enrichedIngredientPayload({
      per100g: { sodium_mg: 200 },
      refreshSodium: true,
      storedFailures: 0,
    });
    assert.deepEqual(payload.per100g, { sodium_mg: 200 });
    assert.ok(
      (payload.sodium_repaired_at as FieldValue).isEqual(FieldValue.serverTimestamp()),
      "sodium_repaired_at : horodatage serveur",
    );
    assert.equal("enrichment_failure_count" in payload, false);
  });
  test("mode courant : ni marque, compteur d'échecs remis à zéro après un échec", () => {
    const payload = enrichedIngredientPayload({
      per100g: { kcal: 100 },
      refreshSodium: false,
      storedFailures: 2,
    });
    assert.equal("sodium_repaired_at" in payload, false);
    assert.equal(payload.enrichment_failure_count, 0);
    assert.equal(
      "enrichment_failure_count" in
        enrichedIngredientPayload({ per100g: {}, refreshSodium: false, storedFailures: 0 }),
      false,
    );
  });
});

describe("fin de parcours", () => {
  const base: BackfillEnrichReferentialsResponse = {
    scannedUnits: 0,
    enrichedUnits: 0,
    scannedIngredients: 500,
    enrichedIngredients: 0,
    failedIngredients: 0,
    remainingUnitsWithoutWeight: 0,
    completed: true,
    stoppedByDeadline: false,
    refreshedIngredients: 0,
    excludedUnits: 0,
    excludedIngredients: 0,
    unresolvedFailures: 0,
    aRevoir: { items: [], total: 0 },
  };

  test("mode sel, parcours repris à mi-chemin : incomplet, jamais marqué terminé", () => {
    const completed = enrichPassCompleted({
      refreshSodium: true,
      stoppedByDeadline: false,
      startedFromBeginning: false,
    });
    assert.equal(completed, false);
    const summary = summarizeEnrichReferentials({ ...base, completed });
    assert.equal(passStatus(summary), "incomplet");
    assert.equal(shouldAutoMarkDone("ponctuel", summary), false);
  });

  test("mode sel, parcours entier sans échec : terminé", () => {
    const completed = enrichPassCompleted({
      refreshSodium: true,
      stoppedByDeadline: false,
      startedFromBeginning: true,
    });
    assert.equal(completed, true);
    const summary = summarizeEnrichReferentials({ ...base, completed, refreshedIngredients: 12 });
    assert.equal(passStatus(summary), "termine");
    assert.equal(shouldAutoMarkDone("ponctuel", summary), true);
  });

  test("mode sel, parcours entier avec échecs : incomplet, non marqué", () => {
    const summary = summarizeEnrichReferentials({
      ...base,
      completed: true,
      failedIngredients: 2,
      unresolvedFailures: 2,
      aRevoir: {
        items: [
          {
            kind: "ingredient",
            id: "a",
            label: "a",
            reason: "Valeurs nutritionnelles introuvables",
          },
          {
            kind: "ingredient",
            id: "b",
            label: "b",
            reason: "Valeurs nutritionnelles introuvables",
          },
        ],
        total: 2,
      },
    });
    assert.equal(passStatus(summary), "incomplet");
    assert.equal(shouldAutoMarkDone("ponctuel", summary), false);
  });

  test("échéance atteinte : incomplet dans les deux modes", () => {
    for (const refreshSodium of [true, false]) {
      assert.equal(
        enrichPassCompleted({ refreshSodium, stoppedByDeadline: true, startedFromBeginning: true }),
        false,
      );
    }
  });

  test("mode courant : inchangé, fini dès qu'il n'a pas buté sur l'échéance", () => {
    assert.equal(
      enrichPassCompleted({
        refreshSodium: false,
        stoppedByDeadline: false,
        startedFromBeginning: false,
      }),
      true,
    );
  });
});
