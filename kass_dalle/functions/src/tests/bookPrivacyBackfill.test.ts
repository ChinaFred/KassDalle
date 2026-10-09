/**
 * Reprise de la confidentialité des livres : la valeur posée sur un livre qui
 * ne porte pas `is_private`. Logique pure.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import { bookPrivacyToSet } from "../callable/bookPrivacyBackfillCallable";

describe("bookPrivacyToSet", () => {
  test("un livre déjà renseigné n'est pas touché", () => {
    assert.equal(bookPrivacyToSet({ is_private: false }), null);
    assert.equal(bookPrivacyToSet({ is_private: true, tags: [] }), null);
  });

  test("sans champ : partagé", () => {
    assert.equal(bookPrivacyToSet({ tags: ["__libres"] }), false);
    assert.equal(bookPrivacyToSet({}), false);
  });

  test("« Mes Recettes Secrètes » sans champ : privé", () => {
    assert.equal(bookPrivacyToSet({ tags: ["__secretes"] }), true);
  });

  test("une valeur qui n'est pas un booléen est remplacée", () => {
    assert.equal(bookPrivacyToSet({ is_private: "false" }), false);
  });
});
