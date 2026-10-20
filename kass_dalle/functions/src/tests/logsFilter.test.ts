/**
 * Filtre de sévérité de `queryLogsFn` : liste blanche (audit #151, ticket #163).
 *
 * La valeur reçue était recopiée dans le filtre Cloud Logging : une chaîne
 * choisie par l'appelant y ajoutait une clause de son choix.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { HttpsError } from "firebase-functions/v2/https";

import { severityClause } from "../callable/logsCallable";

describe("severityClause", () => {
  test("les quatre valeurs de l'écran Admin › Journaux", () => {
    assert.equal(severityClause("DEBUG"), "severity=DEBUG");
    assert.equal(severityClause("INFO"), "severity>=INFO");
    assert.equal(severityClause("WARNING"), "severity>=WARNING");
    assert.equal(severityClause("ERROR"), "severity>=ERROR");
  });

  test("absente, nulle ou vide : aucun filtre", () => {
    assert.equal(severityClause(undefined), null);
    assert.equal(severityClause(null), null);
    assert.equal(severityClause(""), null);
  });

  test("toute autre valeur lève invalid-argument", () => {
    for (const value of [
      "INFO OR logName:x",
      'INFO AND labels.userId="u"',
      "info",
      "CRITICAL",
      "DEFAULT",
      " INFO",
      3,
      true,
      ["INFO"],
      { level: "INFO" },
    ]) {
      assert.throws(
        () => severityClause(value),
        (err: unknown) => err instanceof HttpsError && err.code === "invalid-argument",
        JSON.stringify(value),
      );
    }
  });
});
