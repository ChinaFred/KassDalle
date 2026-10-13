/**
 * Mémoire des échecs des backfills récurrents.
 *
 * Ce que ces tests verrouillent : un élément qui échoue trois fois n'est plus
 * soumis au modèle par un passage ordinaire ; « Réessayer aussi les éléments
 * exclus après 3 échecs » le reprend ; une valeur illisible n'exclut personne ; la raison
 * « à revoir » dit l'exclusion au moment où elle a lieu.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  BACKFILL_FAILURE_LIMIT,
  EXCLUDED_AFTER_FAILURES_REASON,
  failureReason,
  isExcludedAfterFailures,
  nextFailure,
  readFailureCount,
} from "../backfills/failureMemory";
import { ingredientEnrichmentAllowed, unitWeightRequestAllowed } from "../nutrition/aiEnrichment";

describe("compteur d'échecs", () => {
  test("une valeur illisible vaut zéro", () => {
    for (const value of [undefined, null, "3", 2.5, -1, true, {}]) {
      assert.equal(readFailureCount(value), 0, String(value));
    }
    assert.equal(readFailureCount(2), 2);
  });

  test("exclu à trois échecs, pas avant", () => {
    assert.equal(BACKFILL_FAILURE_LIMIT, 3);
    assert.equal(isExcludedAfterFailures(undefined, false), false);
    assert.equal(isExcludedAfterFailures(2, false), false);
    assert.equal(isExcludedAfterFailures(3, false), true);
    assert.equal(isExcludedAfterFailures(7, false), true);
    // Une chaîne n'est pas un compteur : elle n'exclut pas.
    assert.equal(isExcludedAfterFailures("3", false), false);
  });

  test("« Réessayer aussi les éléments exclus après 3 échecs » lève l'exclusion", () => {
    assert.equal(isExcludedAfterFailures(3, true), false);
    assert.equal(isExcludedAfterFailures(12, true), false);
  });

  test("chaque échec ajoute un, le troisième exclut", () => {
    assert.deepEqual(nextFailure(undefined), { count: 1, excluded: false });
    assert.deepEqual(nextFailure(1), { count: 2, excluded: false });
    assert.deepEqual(nextFailure(2), { count: 3, excluded: true });
    // Repris de force et encore en échec : toujours exclu.
    assert.deepEqual(nextFailure(3), { count: 4, excluded: true });
  });

  test("la raison dit l'exclusion quand elle a lieu", () => {
    assert.equal(EXCLUDED_AFTER_FAILURES_REASON, "Plus redemandé à l'IA après 3 échecs");
    assert.equal(failureReason("Pas de réponse de l'IA", nextFailure(0)), "Pas de réponse de l'IA");
    assert.equal(
      failureReason("Pas de réponse de l'IA", nextFailure(2)),
      "Pas de réponse de l'IA — plus redemandé à l'IA après 3 échecs",
    );
  });
});

describe("l'enrichissement des déclencheurs et du rattrapage respecte l'exclusion", () => {
  const maintenant = 1_800_000_000_000;
  const vieux = maintenant - 2 * 24 * 3_600_000;

  test("ingrédient sans valeurs : demandé, sauf après trois échecs du backfill", () => {
    assert.equal(ingredientEnrichmentAllowed({ per100g: {} }, maintenant), true);
    assert.equal(
      ingredientEnrichmentAllowed(
        { per100g: {}, enrichment_failure_count: 2, last_enrichment_attempt_at: vieux },
        maintenant,
      ),
      true,
    );
    assert.equal(
      ingredientEnrichmentAllowed(
        { per100g: {}, enrichment_failure_count: 3, last_enrichment_attempt_at: vieux },
        maintenant,
      ),
      false,
    );
    assert.equal(
      ingredientEnrichmentAllowed(
        { per100g: {}, last_enrichment_attempt_at: maintenant },
        maintenant,
      ),
      false,
      "demandé il y a moins de vingt heures",
    );
  });

  test("unité sans poids : demandée, sauf après trois échecs, sauf la case cochée", () => {
    assert.equal(unitWeightRequestAllowed({}, maintenant, false), true);
    assert.equal(unitWeightRequestAllowed({ grams_per_unit: 5 }, maintenant, false), false);
    const exclue = { ai_weight_failure_count: 3, ai_weight_attempt_at: vieux };
    assert.equal(unitWeightRequestAllowed(exclue, maintenant, false), false);
    assert.equal(unitWeightRequestAllowed(exclue, maintenant, true), true);
  });
});
