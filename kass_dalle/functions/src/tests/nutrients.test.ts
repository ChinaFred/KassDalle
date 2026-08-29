/**
 * Normalisation des nutriments — et le double comptage du sel.
 *
 * Cette fonction n'avait aucun test, et c'est par là qu'est passé le défaut le
 * plus coûteux du référentiel : le sel de TOUS les ingrédients valait le double
 * du vrai, sans qu'aucune erreur ne se lève. Le sel pur pesait 200 g pour
 * 100 g, la sauce soja 11 g de sodium au lieu de 5,5, et une portion d'ailes de
 * poulet annonçait 10,3 g de sel — deux jours d'apport recommandé.
 *
 * Le mécanisme tenait en deux lignes : le schéma d'enrichissement réclame
 * `sodium_mg` ET `salt_g`, le modèle répond les deux, et le code ajoutait la
 * conversion du sel au sodium déjà fourni. La formule suivante reconstruisait
 * ensuite un sel cohérent avec ce sodium faux — d'où le silence.
 *
 * Le test d'idempotence est le plus important : `recipeNutrition` renormalise à
 * la lecture ce que l'enrichissement a déjà normalisé à l'écriture. Une
 * normalisation qui n'est pas un point fixe double à chaque passage.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { normalizeNutrients } from "../nutrition/nutrients";

/** 1 g de sel = 393,4 mg de sodium. */
const SALT_TO_SODIUM = 393.4;

function assertClose(actual: number | undefined, expected: number, message: string) {
  assert.ok(actual != null, `${message} : valeur absente`);
  assert.ok(
    Math.abs(actual - expected) < Math.max(1e-6, Math.abs(expected) * 1e-9),
    `${message} : attendu ${expected}, obtenu ${actual}`,
  );
}

describe("normalizeNutrients — sel et sodium", () => {
  test("le sodium seul dérive le sel", () => {
    const out = normalizeNutrients({ sodium_mg: 39340 });
    assertClose(out.sodium_mg, 39340, "sodium");
    assertClose(out.salt_g, 100, "sel dérivé");
  });

  test("le sel seul dérive le sodium", () => {
    const out = normalizeNutrients({ salt_g: 100 });
    assertClose(out.sodium_mg, 39340, "sodium dérivé");
    assertClose(out.salt_g, 100, "sel");
  });

  test("les deux fournis ne s'additionnent pas — le scénario du bug", () => {
    // Ce que le modèle répond réellement pour le sel de table : les deux
    // champs, cohérents entre eux. L'ancien code rendait 78 680 mg et 200 g.
    const out = normalizeNutrients({ sodium_mg: 39340, salt_g: 100 });
    assertClose(out.sodium_mg, 39340, "sodium");
    assertClose(out.salt_g, 100, "sel");
  });

  test("les deux fournis en désaccord : le sodium fait foi", () => {
    // C'est la mesure des tables de composition ; le sel n'en est qu'une
    // conversion. Trancher est plus honnête que faire la somme des deux.
    const out = normalizeNutrients({ sodium_mg: 1000, salt_g: 50 });
    assertClose(out.sodium_mg, 1000, "sodium");
    assertClose(out.salt_g, 1000 / SALT_TO_SODIUM, "sel recalculé depuis le sodium");
  });

  test("la normalisation est un point fixe", () => {
    // `recipeNutrition` renormalise à la lecture ce qui a déjà été normalisé à
    // l'écriture. Sans cette propriété, chaque lecture doublait encore le sel.
    const once = normalizeNutrients({ sodium_mg: 39340, salt_g: 100 });
    const twice = normalizeNutrients(once);
    const thrice = normalizeNutrients(twice);
    assert.deepEqual(twice, once, "deuxième passage");
    assert.deepEqual(thrice, once, "troisième passage");
  });

  test("un profil sans sel ni sodium n'en invente pas", () => {
    const out = normalizeNutrients({ kcal: 251, protein_g: 10.4 });
    assert.equal(out.sodium_mg, undefined);
    assert.equal(out.salt_g, undefined);
  });
});

describe("normalizeNutrients — alias", () => {
  test("deux écritures du même nutriment ne s'additionnent pas", () => {
    const out = normalizeNutrients({ kcal: 251, calories: 251 });
    assertClose(out.kcal, 251, "calories");
  });

  test("la forme canonique gagne, quel que soit son rang", () => {
    assertClose(
      normalizeNutrients({ proteines: 5, protein_g: 10 }).protein_g,
      10,
      "canonique après",
    );
    assertClose(
      normalizeNutrients({ protein_g: 10, proteines: 5 }).protein_g,
      10,
      "canonique avant",
    );
  });

  test("entre deux alias non canoniques, le premier gagne", () => {
    assertClose(normalizeNutrients({ proteines: 5, protein: 9 }).protein_g, 5, "premier alias");
  });

  test("les libellés accentués et espacés se rattachent quand même", () => {
    assertClose(normalizeNutrients({ Énergie: 251 }).kcal, 251, "énergie → kcal");
  });
});

describe("normalizeNutrients — valeurs rejetées", () => {
  test("zéro et négatif sont écartés", () => {
    const out = normalizeNutrients({ kcal: 0, protein_g: -3, fat_g: 2 });
    assert.equal(out.kcal, undefined);
    assert.equal(out.protein_g, undefined);
    assertClose(out.fat_g, 2, "lipides");
  });

  test("une chaîne numérique est lue, une chaîne quelconque est écartée", () => {
    const out = normalizeNutrients({ kcal: "251", protein_g: "10,4", fat_g: "beaucoup" });
    assertClose(out.kcal, 251, "kcal en chaîne");
    assertClose(out.protein_g, 10.4, "virgule décimale");
    assert.equal(out.fat_g, undefined);
  });
});
