/**
 * Doublons à l'import : même livre, même titre normalisé, pages compatibles.
 *
 * Une page scannée deux fois de suite doit être reconnue avant que le premier
 * brouillon existe : l'import plus ancien encore en cours sert de référence.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  jobTitleKeyFields,
  pagesCompatible,
  pickDuplicate,
  titleKey,
  type InFlightJob,
} from "../pipeline/duplicateDetection";
import { onlyTitleKeyChanged, titleKeyUpdate } from "../triggers/recipeTitleKey";
import { pickExistingBook, type LibraryBook } from "../books/existingBook";

describe("titleKey", () => {
  test("casse, accents, ponctuation et espaces", () => {
    assert.equal(titleKey("  Tarte  Tatin, à l'ancienne !"), "tarte tatin a l ancienne");
    assert.equal(titleKey("Œufs en meurette"), "oeufs en meurette");
    assert.equal(titleKey("Crème brûlée"), titleKey("CREME BRULEE"));
  });

  test("un titre vide ou absent rend une clé vide", () => {
    assert.equal(titleKey(""), "");
    assert.equal(titleKey("  ... "), "");
    assert.equal(titleKey(null), "");
  });
});

describe("pagesCompatible", () => {
  test("deux numéros connus et différents écartent le doublon", () => {
    assert.equal(pagesCompatible(12, 48), false);
    assert.equal(pagesCompatible(12, 12), true);
  });

  test("un numéro absent d'un côté ne l'écarte pas", () => {
    assert.equal(pagesCompatible(null, 12), true);
    assert.equal(pagesCompatible(12, undefined), true);
  });
});

const self = {
  jobId: "job-b",
  createdAtMs: 2_000,
  createdRecipeIds: [] as string[],
  ownerUid: "owner",
};

function job(overrides: Partial<InFlightJob>): InFlightJob {
  return {
    id: "job-a",
    status: "processing",
    createdAtMs: 1_000,
    titreKeys: ["pate brisee"],
    titreKeyPages: [12],
    titres: ["Pâte brisée"],
    checked: false,
    createdBy: "owner",
    ...overrides,
  };
}

describe("pickDuplicate", () => {
  test("une recette du livre au même titre est la référence", () => {
    const match = pickDuplicate({
      candidate: { titre: "Pâte Brisée", page: 12 },
      recipes: [{ id: "r1", titre: "Pâte brisée", page: 12 }],
      jobs: [job({})],
      self,
    });
    assert.deepEqual(match, {
      titre: "Pâte Brisée",
      existingTitre: "Pâte brisée",
      existingPage: 12,
      recipeId: "r1",
      jobId: null,
    });
  });

  test("deux homonymes à des pages différentes ne sont pas des doublons", () => {
    const match = pickDuplicate({
      candidate: { titre: "Pâte brisée", page: 48 },
      recipes: [{ id: "r1", titre: "Pâte brisée", page: 12 }],
      jobs: [],
      self,
    });
    assert.equal(match, null);
  });

  test("la même page scannée deux fois : l'import plus ancien en cours est la référence", () => {
    const match = pickDuplicate({
      candidate: { titre: "Pâte brisée", page: null },
      recipes: [],
      jobs: [job({})],
      self,
    });
    assert.equal(match?.jobId, "job-a");
    assert.equal(match?.recipeId, null);
  });

  test("un import plus récent n'est pas une référence : seul le second scan attend", () => {
    const match = pickDuplicate({
      candidate: { titre: "Pâte brisée", page: 12 },
      recipes: [],
      jobs: [job({ createdAtMs: 3_000 })],
      self,
    });
    assert.equal(match, null);
  });

  test("transcriptions finies dans l'ordre inverse : un import plus récent déjà vérifié est la référence", () => {
    const match = pickDuplicate({
      candidate: { titre: "Pâte brisée", page: 12 },
      recipes: [],
      jobs: [job({ createdAtMs: 3_000, checked: true })],
      self,
    });
    assert.equal(match?.jobId, "job-a");
  });

  test("un import d'un autre compte sur le même livre n'est pas une référence", () => {
    const match = pickDuplicate({
      candidate: { titre: "Pâte brisée", page: 12 },
      recipes: [],
      jobs: [job({ createdBy: "intrus", checked: true })],
      self,
    });
    assert.equal(match, null);
  });

  test("à date égale, l'identifiant départage", () => {
    const earlier = pickDuplicate({
      candidate: { titre: "Pâte brisée", page: 12 },
      recipes: [],
      jobs: [job({ createdAtMs: 2_000, id: "job-a" })],
      self,
    });
    assert.equal(earlier?.jobId, "job-a");
    const later = pickDuplicate({
      candidate: { titre: "Pâte brisée", page: 12 },
      recipes: [],
      jobs: [job({ createdAtMs: 2_000, id: "job-c" })],
      self,
    });
    assert.equal(later, null);
  });

  test("un import terminé, en erreur ou en attente n'est pas une référence", () => {
    for (const status of ["done", "error", "rejected", "duplicate"]) {
      const match = pickDuplicate({
        candidate: { titre: "Pâte brisée", page: 12 },
        recipes: [],
        jobs: [job({ status })],
        self,
      });
      assert.equal(match, null, status);
    }
  });

  test("les brouillons déjà créés par ce job ne comptent pas", () => {
    const match = pickDuplicate({
      candidate: { titre: "Pâte brisée", page: 12 },
      recipes: [{ id: "mine", titre: "Pâte brisée", page: 12 }],
      jobs: [],
      self: { ...self, createdRecipeIds: ["mine"] },
    });
    assert.equal(match, null);
  });

  test("un titre vide n'est jamais un doublon", () => {
    const match = pickDuplicate({
      candidate: { titre: "", page: null },
      recipes: [{ id: "r1", titre: "", page: null }],
      jobs: [],
      self,
    });
    assert.equal(match, null);
  });
});

describe("jobTitleKeyFields", () => {
  test("clés, pages et titres dans le même ordre, sans titre vide", () => {
    assert.deepEqual(
      jobTitleKeyFields([
        { titre: "Pâte brisée", page: 12 },
        { titre: " ", page: 13 },
        { titre: "Crème anglaise", page: null },
      ]),
      {
        titre_keys: ["pate brisee", "creme anglaise"],
        titre_key_pages: [12, null],
        titre_key_titres: ["Pâte brisée", "Crème anglaise"],
      },
    );
  });
});

describe("titleKeyUpdate", () => {
  test("rend la clé quand elle manque ou ne suit plus le titre", () => {
    assert.equal(titleKeyUpdate({ titre: "Gratin" }), "gratin");
    assert.equal(
      titleKeyUpdate({ titre: "Gratin dauphinois", titre_key: "gratin" }),
      "gratin dauphinois",
    );
  });

  test("rend null quand la clé est à jour : l'écho du déclencheur ne réécrit rien", () => {
    assert.equal(titleKeyUpdate({ titre: "Gratin", titre_key: "gratin" }), null);
  });
});

describe("pickExistingBook", () => {
  const books: LibraryBook[] = [
    { id: "b1", titre: "5 ingrédients", auteur: "Jamie Oliver", sha256: "aaa", createdAtMs: 0 },
    { id: "b2", titre: "Les Desserts", auteur: "Pierre Hermé", sha256: null, createdAtMs: 0 },
  ];

  test("même titre et même auteur", () => {
    const match = pickExistingBook({
      books,
      titre: "5 Ingredients",
      auteur: "jamie oliver",
      sha256: "zzz",
    });
    assert.equal(match?.id, "b1");
    assert.equal(match?.sameTitle, true);
    assert.equal(match?.sameFile, false);
  });

  test("un auteur inconnu d'un côté n'écarte pas le doublon", () => {
    assert.equal(
      pickExistingBook({ books, titre: "Les desserts", auteur: null, sha256: "zzz" })?.id,
      "b2",
    );
    assert.equal(
      pickExistingBook({ books, titre: "Les desserts", auteur: "Auteur inconnu", sha256: "zzz" })
        ?.id,
      "b2",
    );
  });

  test("deux auteurs connus et différents l'écartent", () => {
    assert.equal(
      pickExistingBook({
        books,
        titre: "Les desserts",
        auteur: "Christophe Michalak",
        sha256: "z",
      }),
      null,
    );
  });

  test("le même fichier se reconnaît sous un autre titre", () => {
    const match = pickExistingBook({ books, titre: null, auteur: null, sha256: "aaa" });
    assert.equal(match?.id, "b1");
    assert.equal(match?.sameFile, true);
    assert.equal(match?.importedAt, new Date(0).toISOString());
  });

  test("rien ne correspond", () => {
    assert.equal(pickExistingBook({ books, titre: "Autre", auteur: null, sha256: "z" }), null);
  });
});

describe("onlyTitleKeyChanged", () => {
  test("seule la clé change : vrai", () => {
    assert.equal(
      onlyTitleKeyChanged(
        { titre: "Gratin", tags: { a: 1 } },
        { titre: "Gratin", tags: { a: 1 }, titre_key: "gratin" },
      ),
      true,
    );
  });

  test("un autre champ change aussi : faux", () => {
    assert.equal(
      onlyTitleKeyChanged({ titre: "Gratin" }, { titre: "Gratin d", titre_key: "gratin d" }),
      false,
    );
  });

  test("création ou clé inchangée : faux", () => {
    assert.equal(onlyTitleKeyChanged(undefined, { titre_key: "gratin" }), false);
    assert.equal(onlyTitleKeyChanged({ titre_key: "a", x: 1 }, { titre_key: "a", x: 2 }), false);
  });
});
