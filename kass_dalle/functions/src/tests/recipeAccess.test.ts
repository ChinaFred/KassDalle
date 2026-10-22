/**
 * Écriture sur une recette par une callable, et confidentialité d'une recette
 * sans livre. Logique pure.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import { recipeWriteDenial, referentialNormalizationDenial } from "../callable/_recipeAccess";
import { privacyWithoutBook } from "../triggers/recipePrivacy";

// Faille 5 de l'audit : un conseil ou un calcul écrit sur la recette ne se
// déclenche que par son créateur ou un administrateur.
describe("recipeWriteDenial", () => {
  test("le créateur écrit, sur une recette partagée comme privée", () => {
    for (const isPrivate of [false, true]) {
      assert.equal(
        recipeWriteDenial({
          data: { is_private: isPrivate, created_by: "auteur" },
          callerUid: "auteur",
          callerIsAdmin: false,
        }),
        null,
      );
    }
  });

  test("un autre compte est refusé, même sur une recette partagée", () => {
    assert.notEqual(
      recipeWriteDenial({
        data: { is_private: false, created_by: "auteur" },
        callerUid: "lecteur",
        callerIsAdmin: false,
      }),
      null,
    );
  });

  test("l'administrateur écrit partout", () => {
    assert.equal(
      recipeWriteDenial({ data: { created_by: "auteur" }, callerUid: "x", callerIsAdmin: true }),
      null,
    );
  });

  test("created_by absent, vide ou d'un autre type : personne sauf l'administrateur", () => {
    for (const data of [{}, { created_by: "" }, { created_by: 42 }, undefined]) {
      assert.notEqual(recipeWriteDenial({ data, callerUid: "", callerIsAdmin: false }), null);
      assert.notEqual(recipeWriteDenial({ data, callerUid: "x", callerIsAdmin: false }), null);
      assert.equal(recipeWriteDenial({ data, callerUid: "x", callerIsAdmin: true }), null);
    }
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

// Audit sécurité : la normalisation écrit dans le référentiel partagé
// `nutrition_ingredients` et appelle des modèles. Éditeur et administrateur
// seulement (v0.24.66, tickets #162 et #163) : le lecteur n'y passe plus, même
// pour sa propre recette.
describe("referentialNormalizationDenial", () => {
  test("éditeur et administrateur normalisent", () => {
    assert.equal(referentialNormalizationDenial({ callerIsEditor: true }), null);
  });

  test("un lecteur est refusé, même pour sa propre recette", () => {
    assert.notEqual(referentialNormalizationDenial({ callerIsEditor: false }), null);
  });
});
