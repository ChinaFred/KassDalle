/**
 * Lecture d'une recette par une callable, et confidentialité d'une recette
 * sans livre. Logique pure.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import { privateRecipeReadDenial } from "../callable/_recipeAccess";
import { privacyWithoutBook } from "../triggers/recipePrivacy";

describe("privateRecipeReadDenial", () => {
  const priv = { is_private: true, created_by: "auteur" };

  test("recette privée d'un autre : refusée", () => {
    assert.notEqual(
      privateRecipeReadDenial({ data: priv, callerUid: "lecteur", callerIsAdmin: false }),
      null,
    );
  });

  test("le créateur et l'administrateur lisent", () => {
    assert.equal(
      privateRecipeReadDenial({ data: priv, callerUid: "auteur", callerIsAdmin: false }),
      null,
    );
    assert.equal(
      privateRecipeReadDenial({ data: priv, callerUid: "x", callerIsAdmin: true }),
      null,
    );
  });

  test("recette partagée ou sans champ : lue par tous", () => {
    for (const data of [{ is_private: false, created_by: "a" }, { created_by: "a" }, undefined]) {
      assert.equal(privateRecipeReadDenial({ data, callerUid: "x", callerIsAdmin: false }), null);
    }
  });

  test("created_by vide ne donne aucun droit", () => {
    assert.notEqual(
      privateRecipeReadDenial({
        data: { is_private: true, created_by: "" },
        callerUid: "",
        callerIsAdmin: false,
      }),
      null,
    );
  });
});

// Détacher une page d'un livre privé la rendait publique : une recette sans
// livre retombait à `false`.
describe("privacyWithoutBook", () => {
  test("une recette libre déjà privée reste privée", () => {
    assert.equal(privacyWithoutBook(true), true);
  });

  test("sinon partagée", () => {
    assert.equal(privacyWithoutBook(false), false);
    assert.equal(privacyWithoutBook(undefined), false);
  });
});
