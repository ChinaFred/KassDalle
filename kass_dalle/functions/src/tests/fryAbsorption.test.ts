/**
 * Huile absorbée à la friture.
 *
 * Deux pièces se testent sans moteur d'IA : le portier qui décide s'il vaut la
 * peine d'appeler, et l'arithmétique qui transforme un taux en grammes. Le
 * reste — quels ingrédients passent au bain — demande de lire la recette.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  computeAbsorbedOilGrams,
  FAILED_FRY_ABSORPTION,
  fryFieldsToPersist,
  fryingSignature,
  NO_FRY_ABSORPTION,
  looksFried,
  MAX_FRY_ABSORPTION_RATIO,
} from "../nutrition/fryAbsorption";

describe("looksFried", () => {
  test("une étape qui parle de frire déclenche le portier", () => {
    assert.equal(looksFried({ rawCooklang: "Faire frire les escalopes 4 min." }), true);
    assert.equal(looksFried({ rawCooklang: "Plonger dans un bain d'huile à 170 °C." }), true);
    assert.equal(looksFried({ rawCooklang: "Servir avec des frites maison." }), true);
    assert.equal(looksFried({ rawCooklang: "Préparer des beignets de courgette." }), true);
  });

  test("un bain nommé dans les ingrédients suffit", () => {
    assert.equal(
      looksFried({ rawCooklang: "Cuire 12 min.", ingredientNames: ["huile de friture"] }),
      true,
    );
  });

  test("les accents et la casse ne masquent pas la cuisson", () => {
    assert.equal(looksFried({ rawCooklang: "POULET FRIT à la poêle" }), true);
  });

  test("un mot qui contient « frit » sans frire ne déclenche rien", () => {
    // Le piège de la recherche par sous-chaîne : une frittata est une omelette.
    assert.equal(looksFried({ rawCooklang: "Préparer une frittata aux herbes." }), false);
    assert.equal(looksFried({ rawCooklang: "Napper de confiture d'abricot." }), false);
  });

  test("une panure seule ne suppose pas un bain — le four existe", () => {
    assert.equal(
      looksFried({
        rawCooklang: "Paner au panko puis enfourner 25 min à 200 °C.",
        ingredientNames: ["chapelure panko", "escalope de poulet"],
      }),
      false,
    );
  });

  test("une recette vide ne déclenche rien", () => {
    assert.equal(looksFried({}), false);
    assert.equal(looksFried({ rawCooklang: "   " }), false);
  });
});

describe("computeAbsorbedOilGrams", () => {
  test("un poulet pané absorbe le dixième de son poids", () => {
    const result = computeAbsorbedOilGrams({
      friedWeightGrams: 600,
      absorptionRatio: 0.1,
    });
    assert.equal(result.grams, 60);
    assert.equal(result.capped, false);
  });

  test("l'absorption ne dépasse pas le bain déclaré", () => {
    const result = computeAbsorbedOilGrams({
      friedWeightGrams: 600,
      absorptionRatio: 0.1,
      declaredOilGrams: 25,
    });
    assert.equal(result.grams, 25);
    assert.equal(result.capped, true);
  });

  test("un bain généreux ne plafonne rien", () => {
    const result = computeAbsorbedOilGrams({
      friedWeightGrams: 600,
      absorptionRatio: 0.1,
      declaredOilGrams: 920,
    });
    assert.equal(result.grams, 60);
    assert.equal(result.capped, false);
  });

  test("un bain sans quantité exploitable laisse l'estimation sans borne", () => {
    const result = computeAbsorbedOilGrams({
      friedWeightGrams: 600,
      absorptionRatio: 0.1,
      declaredOilGrams: null,
    });
    assert.equal(result.grams, 60);
  });

  test("un taux aberrant est borné plutôt que cru", () => {
    const result = computeAbsorbedOilGrams({
      friedWeightGrams: 100,
      absorptionRatio: 0.8,
    });
    assert.equal(result.grams, 100 * MAX_FRY_ABSORPTION_RATIO);
  });

  test("sans poids frit ni taux, il n'y a rien à ajouter", () => {
    assert.equal(computeAbsorbedOilGrams({ friedWeightGrams: 0, absorptionRatio: 0.1 }).grams, 0);
    assert.equal(computeAbsorbedOilGrams({ friedWeightGrams: 600, absorptionRatio: 0 }).grams, 0);
    assert.equal(
      computeAbsorbedOilGrams({ friedWeightGrams: Number.NaN, absorptionRatio: 0.1 }).grams,
      0,
    );
  });
});

describe("fryingSignature", () => {
  test("deux calculs de la même recette réutilisent le verdict", () => {
    const first = fryingSignature({
      ingredientsKey: "poulet|1|piece",
      rawCooklang: "Faire frire.",
    });
    const second = fryingSignature({
      ingredientsKey: "poulet|1|piece",
      rawCooklang: "Faire frire.",
    });
    assert.equal(first, second);
  });

  test("changer la cuisson redemande un verdict", () => {
    const fried = fryingSignature({
      ingredientsKey: "poulet|1|piece",
      rawCooklang: "Faire frire.",
    });
    const baked = fryingSignature({ ingredientsKey: "poulet|1|piece", rawCooklang: "Enfourner." });
    assert.notEqual(fried, baked);
  });

  test("changer la liste d'ingrédients redemande un verdict", () => {
    const withoutOil = fryingSignature({ ingredientsKey: "poulet|1|piece", rawCooklang: "Frire." });
    const withOil = fryingSignature({
      ingredientsKey: "poulet|1|piece~huile|1|l",
      rawCooklang: "Frire.",
    });
    assert.notEqual(withoutOil, withOil);
  });
});

describe("fryFieldsToPersist", () => {
  const signature = fryingSignature({ ingredientsKey: "poulet|panko", rawCooklang: "Frire." });

  test("un verdict en échec ne mémorise pas la signature : le calcul suivant rappelle", () => {
    const fields = fryFieldsToPersist(FAILED_FRY_ABSORPTION, signature);
    assert.deepEqual(fields, { fry_verdict: null, fry_signature: "" });
    // Une signature réelle n'est jamais vide : la comparaison du calcul
    // suivant échoue donc toujours, et l'appel est refait.
    assert.notEqual(fields.fry_signature, signature);
    assert.ok(signature.length > 0);
  });

  test("un échec reste un échec même s'il porte des indices", () => {
    const fields = fryFieldsToPersist(
      { friedIndices: [0], absorptionRatio: 0.1, failed: true },
      signature,
    );
    assert.deepEqual(fields, { fry_verdict: null, fry_signature: "" });
  });

  test("« rien n'est frit » réussi mémorise la signature, sans verdict", () => {
    assert.deepEqual(fryFieldsToPersist(NO_FRY_ABSORPTION, signature), {
      fry_verdict: null,
      fry_signature: signature,
    });
  });

  test("un verdict réussi mémorise la signature et le verdict", () => {
    assert.deepEqual(
      fryFieldsToPersist({ friedIndices: [0, 1], absorptionRatio: 0.1 }, signature),
      {
        fry_verdict: { fried_indices: [0, 1], absorption_ratio: 0.1 },
        fry_signature: signature,
      },
    );
  });
});
