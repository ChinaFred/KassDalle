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
// `nutrition_ingredients`. Un lecteur ne l'appelle que pour l'une de ses
// recettes ; l'éditeur, toujours.
describe("referentialNormalizationDenial", () => {
  const own = { created_by: "lecteur", is_private: false };

  test("éditeur et administrateur normalisent, avec ou sans recette", () => {
    for (const recipeId of [undefined, "r1"]) {
      assert.equal(
        referentialNormalizationDenial({
          callerIsEditor: true,
          recipeId,
          recipeData: undefined,
          callerUid: "editeur",
        }),
        null,
      );
    }
  });

  test("un lecteur normalise sa propre recette", () => {
    assert.equal(
      referentialNormalizationDenial({
        callerIsEditor: false,
        recipeId: "r1",
        recipeData: own,
        callerUid: "lecteur",
      }),
      null,
    );
  });

  test("un lecteur est refusé sans recette, sur une recette absente ou d'un autre", () => {
    const cases = [
      { recipeId: undefined, recipeData: undefined },
      { recipeId: "absente", recipeData: undefined },
      { recipeId: "r2", recipeData: { created_by: "auteur", is_private: false } },
      { recipeId: "r3", recipeData: { created_by: "", is_private: false } },
    ];
    for (const c of cases) {
      assert.notEqual(
        referentialNormalizationDenial({ callerIsEditor: false, callerUid: "lecteur", ...c }),
        null,
      );
    }
  });
});
