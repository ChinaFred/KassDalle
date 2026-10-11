/**
 * Allergènes — vocabulaire, lecture de la réponse du modèle, union sur une
 * recette.
 *
 * Une erreur ici ne casse aucun écran : une clé mal lue fait disparaître un
 * allergène de la fiche, un ingrédient non examiné compté comme « aucun » fait
 * afficher « Aucun allergène majeur détecté ». Ces tests verrouillent ce qui
 * passe, ce qui est écarté, et quand le résultat est dit incomplet.
 *
 * Logique pure : ni Firestore, ni réseau, ni appel de modèle.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import {
  ALLERGEN_EXAMPLES,
  ALLERGEN_KEYS,
  ALLERGEN_LABELS,
  allergensFromReferential,
  computeRecipeAllergens,
  isAllergenKey,
  parseAllergenBatchAnswer,
  recipeAllergensSignature,
  sanitizeAllergenList,
  type AllergenKey,
} from "../nutrition/allergens";
import {
  buildAllergenPrompt,
  recipeAllergensFromDocs,
  recipeIngredientNames,
} from "../nutrition/allergenExamination";
import { recipeAllergensMissing } from "../triggers/recipeAllergensSync";

describe("fixture partagée avec le client", () => {
  const fixturePath = path.join(__dirname, "..", "..", "..", "test-fixtures", "allergens.json");
  const fixture = JSON.parse(readFileSync(fixturePath, "utf8")) as {
    allergens: { key: string; label: string }[];
  };

  test("mêmes clés, dans l'ordre du règlement", () => {
    assert.deepEqual(
      [...ALLERGEN_KEYS],
      fixture.allergens.map((a) => a.key),
    );
  });

  test("mêmes libellés", () => {
    for (const { key, label } of fixture.allergens) {
      assert.equal(ALLERGEN_LABELS[key as AllergenKey], label, key);
    }
  });

  test("quatorze clés, chacune avec ses exemples pour le prompt", () => {
    assert.equal(ALLERGEN_KEYS.length, 14);
    for (const key of ALLERGEN_KEYS) assert.ok(ALLERGEN_EXAMPLES[key].length > 0, key);
  });
});

describe("clés reconnues", () => {
  test("une clé de la liste passe, une autre non", () => {
    assert.equal(isAllergenKey("lait"), true);
    assert.equal(isAllergenKey("fruits_a_coque"), true);
    assert.equal(isAllergenKey("noix"), false);
    assert.equal(isAllergenKey(""), false);
    assert.equal(isAllergenKey(42), false);
  });

  test("les noms de propriétés héritées ne sont pas des clés", () => {
    for (const key of ["__proto__", "constructor", "toString", "hasOwnProperty"]) {
      assert.equal(isAllergenKey(key), false, key);
    }
  });

  test("liste triée dans l'ordre du règlement, sans doublon, hors liste écartée", () => {
    assert.deepEqual(sanitizeAllergenList(["lait", "gluten", " Lait ", "traces", 3]), {
      keys: ["gluten", "lait"],
      rejected: ["traces", "3"],
    });
  });

  test("absent ne se confond pas avec vide", () => {
    assert.equal(sanitizeAllergenList(undefined), null);
    assert.equal(sanitizeAllergenList("lait"), null);
    assert.deepEqual(sanitizeAllergenList([]), { keys: [], rejected: [] });
  });
});

describe("réponse du modèle", () => {
  test("une réponse bien formée donne une entrée par ingrédient", () => {
    const answers = parseAllergenBatchAnswer(
      {
        ingredients: [
          { id: "0", allergens: ["lait"] },
          { id: "1", allergens: [] },
          { id: 2, allergens: ["soja", "gluten"] },
        ],
      },
      3,
    );
    assert.deepEqual(answers, [
      { index: 0, keys: ["lait"], rejected: [] },
      { index: 1, keys: [], rejected: [] },
      { index: 2, keys: ["gluten", "soja"], rejected: [] },
    ]);
  });

  test("une forme inattendue fait échouer le lot entier", () => {
    assert.equal(parseAllergenBatchAnswer(null, 2), null);
    assert.equal(parseAllergenBatchAnswer({}, 2), null);
    assert.equal(parseAllergenBatchAnswer({ ingredients: "lait" }, 2), null);
  });

  test("une entrée illisible est sautée : l'ingrédient reste à examiner", () => {
    const answers = parseAllergenBatchAnswer(
      {
        ingredients: [
          { id: "5", allergens: ["lait"] },
          { id: "-1", allergens: ["lait"] },
          { id: "1.5", allergens: ["lait"] },
          { id: "0" },
          { id: "1", allergens: "lait" },
          "lait",
        ],
      },
      2,
    );
    assert.deepEqual(answers, []);
  });

  test("une clé hors liste est écartée et rendue pour le journal", () => {
    const answers = parseAllergenBatchAnswer(
      { ingredients: [{ id: "0", allergens: ["lait", "lactose"] }] },
      1,
    );
    assert.deepEqual(answers, [{ index: 0, keys: ["lait"], rejected: ["lactose"] }]);
  });

  test("un identifiant répété garde sa première réponse", () => {
    const answers = parseAllergenBatchAnswer(
      {
        ingredients: [
          { id: "0", allergens: ["lait"] },
          { id: "0", allergens: ["oeuf"] },
        ],
      },
      1,
    );
    assert.deepEqual(answers, [{ index: 0, keys: ["lait"], rejected: [] }]);
  });
});

describe("union sur une recette", () => {
  const known: Record<string, AllergenKey[]> = {
    beurre: ["lait"],
    farine: ["gluten"],
    "pâte feuilletée": ["gluten", "lait"],
    sel: [],
  };
  const lookup = (name: string) => known[name] ?? null;

  test("clés dans l'ordre du règlement, ingrédients en cause par clé", () => {
    assert.deepEqual(computeRecipeAllergens(["pâte feuilletée", "beurre", "sel"], lookup), {
      present: ["gluten", "lait"],
      complete: true,
      by_ingredient: { gluten: ["pâte feuilletée"], lait: ["pâte feuilletée", "beurre"] },
    });
  });

  test("tout examiné et rien trouvé : complet et vide", () => {
    assert.deepEqual(computeRecipeAllergens(["sel"], lookup), {
      present: [],
      complete: true,
      by_ingredient: {},
    });
  });

  test("un ingrédient jamais examiné rend le résultat incomplet", () => {
    const result = computeRecipeAllergens(["beurre", "safran"], lookup);
    assert.equal(result.complete, false);
    assert.deepEqual(result.present, ["lait"]);
  });

  test("une recette sans ingrédient n'est pas « sans allergène »", () => {
    assert.deepEqual(computeRecipeAllergens([], lookup), {
      present: [],
      complete: false,
      by_ingredient: {},
    });
    assert.equal(computeRecipeAllergens(["  ", ""], lookup).complete, false);
  });

  test("un nom répété n'apparaît qu'une fois", () => {
    const result = computeRecipeAllergens(["beurre", "beurre ", "beurre"], lookup);
    assert.deepEqual(result.by_ingredient, { lait: ["beurre"] });
  });
});

describe("lecture du référentiel", () => {
  test("le premier document qui porte le champ décide, même vide", () => {
    const docs = new Map<string, Record<string, unknown>>([
      ["beurre_doux", { allergens: [] }],
      ["beurre", { allergens: ["lait"] }],
    ]);
    // « beurre doux » : l'identifiant strict porte le champ, vide.
    assert.deepEqual(allergensFromReferential("beurre doux", docs), []);
  });

  test("un document sans le champ laisse la main au suivant", () => {
    const docs = new Map<string, Record<string, unknown>>([
      ["oignons_haches", { canonical_name: "oignons haches" }],
      ["oignons", { allergens: [] }],
    ]);
    assert.deepEqual(allergensFromReferential("oignons hachés", docs), []);
  });

  test("aucun document ne porte le champ : jamais examiné", () => {
    const docs = new Map<string, Record<string, unknown>>([["safran", { per100g: {} }]]);
    assert.equal(allergensFromReferential("safran", docs), null);
    assert.equal(allergensFromReferential("inconnu", docs), null);
  });

  test("une clé hors liste posée dans le référentiel est ignorée", () => {
    const docs = new Map<string, Record<string, unknown>>([
      ["beurre", { allergens: ["lait", "lactose"] }],
    ]);
    assert.deepEqual(allergensFromReferential("beurre", docs), ["lait"]);
  });

  test("calcul d'une recette stockée", () => {
    const docs = new Map<string, Record<string, unknown>>([
      ["beurre", { allergens: ["lait"] }],
      ["oeuf", { allergens: ["oeuf"] }],
    ]);
    const recipe = {
      ingredients: [
        { name: "beurre", qty: "100", unit: "g" },
        { name: "œuf", qty: "2" },
        { qty: "1" },
        "texte",
      ],
    };
    assert.deepEqual(recipeIngredientNames(recipe), ["beurre", "œuf"]);
    assert.deepEqual(recipeAllergensFromDocs(recipe, docs), {
      present: ["oeuf", "lait"],
      complete: true,
      by_ingredient: { oeuf: ["œuf"], lait: ["beurre"] },
    });
  });
});

describe("écriture sur la recette", () => {
  test("même résultat, même signature : la recette n'est pas réécrite", () => {
    const a = { present: ["lait"], complete: true, by_ingredient: { lait: ["beurre"] } };
    const b = { ...a, computed_at: "2026-10-11" };
    assert.equal(recipeAllergensSignature(a), recipeAllergensSignature(b));
  });

  test("un changement d'état ou d'ingrédient change la signature", () => {
    const a = { present: ["lait"], complete: true, by_ingredient: { lait: ["beurre"] } };
    assert.notEqual(
      recipeAllergensSignature(a),
      recipeAllergensSignature({ ...a, complete: false }),
    );
    assert.notEqual(
      recipeAllergensSignature(a),
      recipeAllergensSignature({ ...a, by_ingredient: { lait: ["crème"] } }),
    );
  });

  test("champ absent ou mal formé : à calculer", () => {
    assert.equal(recipeAllergensMissing({}), true);
    assert.equal(recipeAllergensMissing(undefined), true);
    assert.equal(recipeAllergensMissing({ allergens: ["lait"] }), true);
    assert.equal(recipeAllergensMissing({ allergens: null }), true);
    assert.equal(
      recipeAllergensMissing({ allergens: { present: [], complete: false, by_ingredient: {} } }),
      false,
    );
  });
});

describe("prompt", () => {
  test("cite les quatorze clés et numérote les ingrédients", () => {
    const prompt = buildAllergenPrompt([
      { id: "beurre", name: "beurre" },
      { id: "pate_feuilletee", name: "pâte feuilletée" },
    ]);
    for (const key of ALLERGEN_KEYS) assert.ok(prompt.includes(`- ${key} (`), key);
    assert.ok(prompt.includes(`- "0" : beurre`));
    assert.ok(prompt.includes(`- "1" : pâte feuilletée`));
    assert.ok(prompt.includes("En cas de doute, signale"));
  });
});
