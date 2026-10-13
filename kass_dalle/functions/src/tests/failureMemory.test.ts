/**
 * Mémoire des échecs des backfills récurrents.
 *
 * Ce que ces tests verrouillent : un élément qui échoue trois fois n'est plus
 * soumis au modèle par un passage ordinaire ; « Réessayer aussi les éléments
 * en échec » le reprend ; une valeur illisible n'exclut personne ; la raison
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

  test("« Réessayer aussi les éléments en échec » lève l'exclusion", () => {
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
    assert.equal(EXCLUDED_AFTER_FAILURES_REASON, "Exclu après 3 échecs");
    assert.equal(failureReason("Pas de réponse de l'IA", nextFailure(0)), "Pas de réponse de l'IA");
    assert.equal(
      failureReason("Pas de réponse de l'IA", nextFailure(2)),
      "Pas de réponse de l'IA — exclu après 3 échecs",
    );
  });
});
