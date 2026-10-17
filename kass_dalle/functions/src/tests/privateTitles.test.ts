/**
 * Titres des recettes privées proposés à la suggestion : qui est interrogé,
 * ce qui est retenu, et les seuls champs qui sortent.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import {
  PRIVATE_TITLES_MAX_OWNERS,
  collectPrivateTitles,
  ownersToQuery,
  privateTitleOf,
} from "../gemini/privateTitles";

const base = {
  review_status: "validated",
  is_private: true,
  titre: "Gâteau cadeau",
  book_titre: "Livre secret",
  created_by: "uidA",
};

describe("ownersToQuery", () => {
  test("retire le demandeur, les doublons et les valeurs invalides", () => {
    assert.deepEqual(ownersToQuery(["me", "a", "a", 3, "", "b"], "me"), ["a", "b"]);
  });

  test("portée absente ou mal formée : personne", () => {
    assert.deepEqual(ownersToQuery(undefined, "me"), []);
    assert.deepEqual(ownersToQuery("a", "me"), []);
  });

  test("borne à 30 comptes", () => {
    const many = Array.from({ length: 50 }, (_, i) => `u${i}`);
    assert.equal(ownersToQuery(many, "me").length, PRIVATE_TITLES_MAX_OWNERS);
  });
});

describe("privateTitleOf", () => {
  test("une recette validée privée sort avec quatre champs seulement", () => {
    const t = privateTitleOf("r1", { ...base, raw_cooklang: "secret", image_urls: ["x"] });
    assert.deepEqual(t, {
      id: "r1",
      titre: "Gâteau cadeau",
      bookTitre: "Livre secret",
      createdBy: "uidA",
    });
  });

  test("brouillon, en révision ou non privée : écartée", () => {
    assert.equal(privateTitleOf("r", { ...base, review_status: "draft" }), null);
    assert.equal(privateTitleOf("r", { ...base, review_status: "inReview" }), null);
    assert.equal(privateTitleOf("r", { ...base, is_private: false }), null);
    assert.equal(privateTitleOf("r", { ...base, is_private: undefined }), null);
  });

  test("page d'un autre type écartée, page sans type retenue", () => {
    assert.equal(privateTitleOf("r", { ...base, page_type: "technique" }), null);
    assert.notEqual(privateTitleOf("r", { ...base, page_type: "recipe" }), null);
    assert.notEqual(privateTitleOf("r", base), null);
  });

  test("titre vide ou auteur absent : écartée ; livre absent : null", () => {
    assert.equal(privateTitleOf("r", { ...base, titre: "  " }), null);
    assert.equal(privateTitleOf("r", { ...base, created_by: undefined }), null);
    assert.equal(privateTitleOf("r", { ...base, book_titre: undefined })?.bookTitre, null);
  });
});

describe("collectPrivateTitles", () => {
  test("trie par titre sans tenir compte de la casse", () => {
    const out = collectPrivateTitles([
      { id: "1", data: { ...base, titre: "tarte" } },
      { id: "2", data: { ...base, titre: "Blanquette" } },
      { id: "3", data: { ...base, is_private: false } },
    ]);
    assert.deepEqual(
      out.map((t) => t.id),
      ["2", "1"],
    );
  });
});
