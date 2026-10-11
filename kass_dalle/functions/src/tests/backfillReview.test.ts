/**
 * Liste « à revoir » des backfills : le collecteur commun, et son
 * branchement sur le backfill des allergènes — ingrédients sans réponse ou
 * d'un lot en échec, recettes incomplètes.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  BACKFILL_REVIEW_LIMIT,
  BackfillReview,
  namesList,
  recipeReviewLabel,
  shortErrorMessage,
} from "../callable/_backfillReview";
import {
  allergenIssueReviewItem,
  incompleteRecipeReason,
} from "../callable/allergensBackfillCallable";
import { nutritionReviewItem } from "../callable/nutritionBackfillCallable";
import {
  examineAllergenCandidates,
  unexaminedIngredientNames,
  type AllergenCandidate,
} from "../nutrition/allergenExamination";

describe("collecteur « à revoir »", () => {
  test("garde l'ordre de traitement", () => {
    const review = new BackfillReview();
    review.add({ kind: "recipe", id: "b", label: "Tarte", reason: "x" });
    review.add({ kind: "ingredient", id: "a", label: "Beurre", reason: "y" });
    assert.deepEqual(review.toJSON(), {
      items: [
        { kind: "recipe", id: "b", label: "Tarte", reason: "x" },
        { kind: "ingredient", id: "a", label: "Beurre", reason: "y" },
      ],
      total: 2,
    });
  });

  test("plafonné à cent entrées, total compté au-delà", () => {
    const review = new BackfillReview();
    for (let i = 0; i < 240; i++) {
      review.add({ kind: "recipe", id: `r${i}`, label: `R${i}`, reason: "x" });
    }
    const out = review.toJSON();
    assert.equal(BACKFILL_REVIEW_LIMIT, 100);
    assert.equal(out.items.length, 100);
    assert.equal(out.total, 240);
    assert.equal(out.items[0].id, "r0");
    assert.equal(out.items[99].id, "r99");
  });

  test("vide : aucune entrée, total zéro", () => {
    assert.deepEqual(new BackfillReview().toJSON(), { items: [], total: 0 });
  });

  test("nom absent : l'identifiant le remplace ; textes resserrés et bornés", () => {
    const review = new BackfillReview();
    review.add({ kind: "recipe", id: " r1 ", label: "  ", reason: "a\n  b" });
    review.add({ kind: "recipe", id: "r2", label: "x".repeat(500), reason: "ok" });
    const [first, second] = review.toJSON().items;
    assert.equal(first.id, "r1");
    assert.equal(first.label, "r1");
    assert.equal(first.reason, "a b");
    assert.equal(second.label.length, 200);
  });

  test("la sortie est un objet simple, écrivable dans Firestore", () => {
    const out = new BackfillReview().toJSON();
    assert.equal(Object.getPrototypeOf(out), Object.prototype);
  });

  test("message d'erreur court, jamais vide", () => {
    assert.equal(shortErrorMessage(new Error("délai dépassé")), "délai dépassé");
    assert.equal(shortErrorMessage(""), "erreur inconnue");
    assert.ok(shortErrorMessage("z".repeat(500)).length <= 120);
  });

  test("titre de la recette, à défaut son identifiant", () => {
    assert.equal(recipeReviewLabel("r1", { titre: " Tarte " }), "Tarte");
    assert.equal(recipeReviewLabel("r1", {}), "r1");
  });

  test("liste de noms bornée à cinq", () => {
    assert.equal(namesList(["a", "b"]), "a, b");
    assert.equal(namesList(["a", "b", "c", "d", "e", "f", "g"]), "a, b, c, d, e et 2 autres");
    assert.equal(namesList(["a", "b", "c", "d", "e", "f"]), "a, b, c, d, e et 1 autre");
  });
});

describe("allergènes — ingrédients à revoir", () => {
  const candidates: AllergenCandidate[] = [
    { id: "beurre", name: "beurre" },
    { id: "farine", name: "farine" },
    { id: "sel", name: "sel" },
  ];
  const ctx = { correlationId: "test", feature: "backfill_allergens" };

  function recorder() {
    const warns: { message: string; extra?: Record<string, unknown> }[] = [];
    const errors: { message: string }[] = [];
    return {
      warns,
      errors,
      deps: {
        logWarn: async (entry: unknown) => {
          warns.push(entry as { message: string; extra?: Record<string, unknown> });
        },
        logError: async (entry: unknown) => {
          errors.push(entry as { message: string });
        },
      },
    };
  }

  test("ingrédient sans réponse : nommé dans le rapport et dans un logWarn", async () => {
    const { warns, errors, deps } = recorder();
    const report = await examineAllergenCandidates({
      candidates,
      ctx,
      deps: {
        ...deps,
        // Le modèle répond pour beurre et sel, pas pour farine.
        examine: async () => [
          { index: 0, keys: ["lait"], rejected: [] },
          { index: 2, keys: [], rejected: [] },
        ],
        write: async (_batch, answers) => answers.length,
      },
    });
    assert.equal(report.examined, 2);
    assert.equal(report.unanswered, 1);
    assert.deepEqual(report.issues, [{ id: "farine", name: "farine", problem: "unanswered" }]);
    assert.equal(errors.length, 0);
    assert.equal(warns.length, 1);
    assert.deepEqual(warns[0].extra?.sansReponse, [{ id: "farine", name: "farine" }]);

    assert.deepEqual(allergenIssueReviewItem(report.issues[0]), {
      kind: "ingredient",
      id: "farine",
      label: "farine",
      reason: "Pas de réponse de l'IA",
    });
  });

  test("lot en échec : chaque ingrédient nommé, avec le message court", async () => {
    const { warns, errors, deps } = recorder();
    const report = await examineAllergenCandidates({
      candidates,
      ctx,
      deps: {
        ...deps,
        examine: async () => {
          throw new Error("délai dépassé");
        },
        write: async () => 0,
      },
    });
    assert.equal(report.failed, 3);
    assert.equal(report.issues.length, 3);
    assert.equal(errors.length, 1);
    assert.equal(warns.length, 0);
    assert.deepEqual(
      report.issues.map((i) => allergenIssueReviewItem(i)),
      candidates.map((c) => ({
        kind: "ingredient",
        id: c.id,
        label: c.name,
        reason: "Lot en échec : délai dépassé",
      })),
    );
  });

  test("tout répondu : aucune entrée, aucun logWarn", async () => {
    const { warns, deps } = recorder();
    const report = await examineAllergenCandidates({
      candidates,
      ctx,
      deps: {
        ...deps,
        examine: async (batch) => batch.map((_, index) => ({ index, keys: [], rejected: [] })),
        write: async (_batch, answers) => answers.length,
      },
    });
    assert.deepEqual(report.issues, []);
    assert.equal(warns.length, 0);
  });
});

describe("allergènes — recettes incomplètes à revoir", () => {
  const docs = new Map<string, Record<string, unknown>>([
    ["beurre", { allergens: ["lait"] }],
    ["sel", { allergens: [] }],
    ["farine", {}],
  ]);

  test("les ingrédients jamais examinés, dans l'ordre de la recette, sans doublon", () => {
    const data = {
      ingredients: [{ name: "farine" }, { name: "beurre" }, { name: "œuf" }, { name: "farine" }],
    };
    assert.deepEqual(unexaminedIngredientNames(data, docs), ["farine", "œuf"]);
  });

  test("raison au singulier, au pluriel, et sans ingrédient", () => {
    assert.equal(incompleteRecipeReason(["farine"]), "Recette incomplète : farine non examiné");
    assert.equal(
      incompleteRecipeReason(["beurre", "farine"]),
      "Recette incomplète : beurre, farine non examinés",
    );
    assert.equal(incompleteRecipeReason([]), "Recette incomplète : aucun ingrédient nommé");
  });
});

describe("nutrition — recettes à revoir", () => {
  const data = { titre: "Quiche" };

  test("ingrédients sans valeurs nommés", () => {
    assert.deepEqual(
      nutritionReviewItem({
        id: "r1",
        data,
        nutrition: { coverage_state: "partial", missing_ingredients: ["lardons", "crème"] },
        error: null,
      }),
      {
        kind: "recipe",
        id: "r1",
        label: "Quiche",
        reason: "Valeurs nutritionnelles introuvables : lardons, crème",
      },
    );
  });

  test("erreur de la reprise, calcul en échec, instantané absent", () => {
    assert.equal(
      nutritionReviewItem({ id: "r1", data, nutrition: null, error: "quota" }).reason,
      "Reprise en échec : quota",
    );
    assert.equal(
      nutritionReviewItem({ id: "r1", data, nutrition: { coverage_state: "failed" }, error: null })
        .reason,
      "Calcul de nutrition en échec",
    );
    assert.equal(
      nutritionReviewItem({ id: "r1", data, nutrition: null, error: null }).reason,
      "Nutrition non calculée",
    );
  });
});
