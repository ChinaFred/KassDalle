/**
 * Le repli de liste d'ingrédients, quand le livre écrit sa recette en prose.
 *
 * Le balisage part des lignes recopiées par la transcription. Sans liste sur la
 * page, il rend une liste vide alors que le CookLang nomme tous les aliments :
 * la recette s'enregistrait sans ingrédients, donc sans liste de courses, sans
 * planification et sans nutrition.
 *
 * Logique pure : aucun Firestore, aucun modèle.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { ingredientsFromCooklang } from "../pipeline/ingredientsFromCooklang";

describe("ingredientsFromCooklang", () => {
  test("un texte balisé rend ses aliments, quantités comprises", () => {
    const cooklang = [
      ">> titre: Poulet aux oignons",
      "Faites revenir @oignon{2%pièce} avec @ail{2%gousse} dans @huile d'olive{}.",
      "Ajoutez @blanc de poulet{4%pièce} et laissez cuire ~{20%minutes}.",
    ].join("\n");

    assert.deepEqual(ingredientsFromCooklang(cooklang), [
      { name: "oignon", qty: "2", unit: "pièce" },
      { name: "ail", qty: "2", unit: "gousse" },
      { name: "huile d'olive", qty: "", unit: "" },
      { name: "blanc de poulet", qty: "4", unit: "pièce" },
    ]);
  });

  test("les sections d'étapes deviennent des catégories", () => {
    const cooklang = [
      "== Pour la marinade ==",
      "Mélangez @sauce soja{3%c. à soupe} et @miel{1%c. à soupe}.",
      "== Pour la cuisson ==",
      "Saisissez @magret{2%pièce}.",
    ].join("\n");

    assert.deepEqual(ingredientsFromCooklang(cooklang), [
      { name: "sauce soja", qty: "3", unit: "c. à soupe", category: "Pour la marinade" },
      { name: "miel", qty: "1", unit: "c. à soupe", category: "Pour la marinade" },
      { name: "magret", qty: "2", unit: "pièce", category: "Pour la cuisson" },
    ]);
  });

  test("un aliment cité deux fois ne compte qu'une entrée", () => {
    const cooklang = [
      "Faites fondre @beurre{50%g} dans la poêle.",
      "Terminez avec le reste de @beurre{}.",
    ].join("\n");

    assert.deepEqual(ingredientsFromCooklang(cooklang), [{ name: "beurre", qty: "50", unit: "g" }]);
  });

  test("un texte sans balise ne rend rien, plutôt qu'une liste inventée", () => {
    const cooklang = [
      ">> titre: Note de placard",
      "Rangez les épices à l'abri de la lumière.",
    ].join("\n");

    assert.deepEqual(ingredientsFromCooklang(cooklang), []);
  });

  test("les températures ne sont pas des ingrédients", () => {
    const cooklang = "Enfournez à @180°c{} avec @thym{2%branche}.";

    assert.deepEqual(ingredientsFromCooklang(cooklang), [
      { name: "thym", qty: "2", unit: "branche" },
    ]);
  });
});
