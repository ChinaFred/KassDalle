/**
 * Livre cible d'un import : seulement un livre de l'importateur, ou n'importe
 * lequel pour un administrateur (décision v0.23.8). Logique pure.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import { targetBookDenial } from "../pipeline/targetBook";

describe("targetBookDenial", () => {
  const base = { bookId: "b1", bookExists: true, ownerUid: "moi", ownerIsAdmin: false };

  test("son propre livre : permis", () => {
    assert.equal(targetBookDenial({ ...base, bookCreatedBy: "moi" }), null);
  });

  test("le livre d'un autre : refusé", () => {
    assert.notEqual(targetBookDenial({ ...base, bookCreatedBy: "autre" }), null);
  });

  test("un administrateur range partout", () => {
    assert.equal(targetBookDenial({ ...base, bookCreatedBy: "autre", ownerIsAdmin: true }), null);
  });

  test("livre inexistant ou identifiant invalide : refusé", () => {
    assert.notEqual(
      targetBookDenial({ ...base, bookExists: false, bookCreatedBy: undefined }),
      null,
    );
    assert.notEqual(targetBookDenial({ ...base, bookId: "a/b", bookCreatedBy: "moi" }), null);
  });

  test("created_by vide n'appartient à personne", () => {
    assert.notEqual(targetBookDenial({ ...base, ownerUid: "", bookCreatedBy: "" }), null);
  });
});
