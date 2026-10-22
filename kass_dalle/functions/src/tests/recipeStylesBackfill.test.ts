/**
 * Backfill « Style des recettes » — ce qu'un passage fait d'une recette sans
 * appeler le modèle (`styleBackfillSkip`).
 *
 * Ce que ces tests verrouillent : une recette examinée n'est pas refacturée,
 * un style corrigé à la main n'est jamais soumis au modèle, même en reprise
 * forcée, et une page qui n'est pas une recette est sautée.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  styleBackfillMarksPage,
  styleBackfillSkip,
} from "../callable/recipeStylesBackfillCallable";

describe("style des recettes — recettes sautées", () => {
  test("jamais examinée : soumise au modèle", () => {
    assert.equal(styleBackfillSkip({ titre: "Burger", tags: { meal_role: "plat" } }, false), null);
  });

  test("examinée, même sans style : sautée", () => {
    const data = { tags: { styles: [], styles_checked_at: { seconds: 1 } } };
    assert.equal(styleBackfillSkip(data, false), "deja_examinee");
  });

  test("examinée, reprise forcée : resoumise", () => {
    const data = { tags: { styles: ["terroir"], styles_checked_at: { seconds: 1 } } };
    assert.equal(styleBackfillSkip(data, true), null);
  });

  test("corrigée à la main : jamais soumise, même en reprise forcée", () => {
    const data = { tags: { styles: ["street_food"], styles_manual: true } };
    assert.equal(styleBackfillSkip(data, false), "manuelle");
    assert.equal(styleBackfillSkip(data, true), "manuelle");
  });

  test("marqueur manuel en chaîne : pas une correction", () => {
    assert.equal(styleBackfillSkip({ tags: { styles_manual: "true" } }, false), null);
  });

  test("page qui n'est pas une recette : sautée", () => {
    assert.equal(styleBackfillSkip({ page_type: "index", tags: {} }, false), "hors_recette");
    assert.equal(
      styleBackfillSkip({ raw_cooklang: ">> page_type: intro\n" }, false),
      "hors_recette",
    );
  });

  test("page hors recette par l'en-tête seul : marquée, pour sortir des restantes", () => {
    // Le champ `page_type` manque : l'agrégat « hors recette » ne la voit pas.
    assert.equal(styleBackfillMarksPage({ raw_cooklang: ">> page_type: intro\n" }), true);
    assert.equal(
      styleBackfillMarksPage({ page_type: null, raw_cooklang: ">> page_type: intro\n" }),
      true,
    );
    // Déjà marquée : rien à écrire.
    assert.equal(
      styleBackfillMarksPage({
        raw_cooklang: ">> page_type: intro\n",
        tags: { styles_checked_at: { seconds: 1 } },
      }),
      false,
    );
    // Champ `page_type` posé : l'agrégat la décompte déjà.
    assert.equal(styleBackfillMarksPage({ page_type: "index" }), false);
    // Une recette n'est jamais marquée sans appel.
    assert.equal(styleBackfillMarksPage({ titre: "Burger" }), false);
    assert.equal(styleBackfillMarksPage({ raw_cooklang: ">> page_type: recipe\n" }), false);
  });
});
