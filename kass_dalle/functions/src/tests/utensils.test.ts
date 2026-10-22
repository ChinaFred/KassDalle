/**
 * Ustensiles — liste fermée, reconnaissance d'un nom ou d'une ligne du livre,
 * réécriture du CookLang et retrait de la sortie d'un refine.
 *
 * La liste et la reconnaissance sont rejouées par le client
 * (`test/utensils_test.dart`) sur la même fixture. Logique pure : ni Firestore,
 * ni réseau, ni appel de modèle.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import { UTENSIL_NAMES, isUtensil, retagUtensils } from "../nutrition/utensils";
import { withoutUtensilsInGenerated } from "../gemini/refiner";

interface UtensilFixture {
  names: string[];
  cases: { input: string; utensil: boolean; why: string }[];
  retag_cases: { input: string; expected: string; why: string }[];
}

const fixture = JSON.parse(
  readFileSync(path.join(__dirname, "..", "..", "..", "test-fixtures", "utensils.json"), "utf8"),
) as UtensilFixture;

describe("utensils.json — fixture partagée avec le client", () => {
  test("même liste, dans le même ordre", () => {
    assert.deepEqual([...UTENSIL_NAMES], fixture.names);
  });

  test("chaque nom de la liste est reconnu", () => {
    for (const name of fixture.names) assert.equal(isUtensil(name), true, name);
  });

  for (const c of fixture.cases) {
    test(`« ${c.input} » → ${c.utensil ? "ustensile" : "ingrédient"} (${c.why})`, () => {
      assert.equal(isUtensil(c.input), c.utensil);
    });
  }
});

describe("utensils.json — réécriture du CookLang (serveur seul)", () => {
  for (const c of fixture.retag_cases) {
    test(c.why, () => {
      assert.equal(retagUtensils(c.input), c.expected);
    });
  }
});

describe("refine et génération", () => {
  test("l'ustensile sort du texte, de la liste et de l'index", () => {
    const out = withoutUtensilsInGenerated({
      titre: "Sablés",
      cooklang: "Tapisser de @papier sulfurisé{1%feuille}, ajouter la @farine{200%g}.",
      ingredients: [
        { name: "papier sulfurisé", qty: "1", unit: "feuille" },
        { name: "farine", qty: "200", unit: "g" },
      ],
      ingredients_index: ["papier sulfurisé", "farine"],
    });
    assert.equal(
      out.cooklang,
      "Tapisser de #papier sulfurisé{1%feuille}, ajouter la @farine{200%g}.",
    );
    assert.deepEqual(out.ingredients, [{ name: "farine", qty: "200", unit: "g" }]);
    assert.deepEqual(out.ingredients_index, ["farine"]);
    assert.equal(out.titre, "Sablés");
  });

  test("une réponse sans liste reste intacte", () => {
    const out = withoutUtensilsInGenerated({ cooklang: "Mélanger @sel{}." });
    assert.deepEqual(out, { cooklang: "Mélanger @sel{}." });
  });
});
