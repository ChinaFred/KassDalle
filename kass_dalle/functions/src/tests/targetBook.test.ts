/**
 * Livre cible d'un import : seulement un livre de l'importateur, ou n'importe
 * lequel pour un administrateur (décision v0.23.8). Logique pure.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import { TargetBookNotOwned, assertJobTargetBook, targetBookDenial } from "../pipeline/targetBook";

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

// Ticket #163, point 11 : un `book_id` présent qui n'est pas une chaîne non
// vide passait pour « sans livre ». Il est refusé, sans lecture Firestore, et
// le job part en `foreign_book` (`TargetBookNotOwned`).
describe("assertJobTargetBook — forme du book_id", () => {
  test("absent ou nul : le job passe sans livre", async () => {
    await assertJobTargetBook(undefined, "moi");
    await assertJobTargetBook(null, "moi");
  });

  const invalid: ReadonlyArray<[string, unknown]> = [
    ["chaîne vide", ""],
    ["nombre", 42],
    ["booléen", true],
    ["liste", ["b1"]],
    ["objet", { id: "b1" }],
  ];
  for (const [label, value] of invalid) {
    test(`${label} : refusé en foreign_book`, async () => {
      await assert.rejects(assertJobTargetBook(value, "moi"), TargetBookNotOwned);
    });
  }
});
