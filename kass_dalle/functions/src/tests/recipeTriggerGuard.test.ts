/**
 * La garde du déclencheur d'écriture de recette.
 *
 * Ce que ces tests verrouillent : le déclencheur écrit dans la collection qu'il
 * écoute, donc il se réveille lui-même. La seule garde qui tienne compare ce
 * dont il DÉPEND — pas ce qu'il produit.
 *
 * L'ancienne garde demandait « la nutrition existe-t-elle déjà ? ». Elle
 * répondait non pendant toute la durée du calcul, et pour toujours après un
 * échec : chaque écho repartait alors en chaîne complète, écrivait à son tour,
 * et en réveillait d'autres. En août, 499 réveils ont appelé le modèle pour 68
 * recettes, dont une salve de 108 en treize minutes.
 *
 * Un test suffit à empêcher le retour du défaut : si une écriture qui ne touche
 * que les SORTIES change l'empreinte, la boucle revient.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { recipeTriggerInputsFingerprint } from "../triggers/recipeIngredients";
import { ENRICHMENT_RETRY_AFTER_MS, enrichmentAttemptIsRecent } from "../nutrition/aiEnrichment";

/** Une recette telle qu'un utilisateur vient de l'écrire. */
function recette(): Record<string, unknown> {
  return {
    ingredients: [
      { name: "beurre", qty: "200", unit: "g" },
      { name: "farine", qty: "3", unit: "c.à.s." },
    ],
    portions: 4,
    page_type: "recipe",
    raw_cooklang: ">> titre: Sablés — Mélanger le @beurre{200%g}.",
    created_by: "uid-1",
  };
}

describe("empreinte des entrées du déclencheur", () => {
  test("les sorties du déclencheur ne comptent pas", () => {
    // C'est LE test. Ces quatre champs sont ce que le déclencheur écrit ;
    // s'ils entraient dans l'empreinte, chacune de ses écritures relancerait
    // une chaîne complète, et la salve d'août reviendrait.
    const avant = recette();
    const apres = {
      ...recette(),
      nutrition: { coverage: 0.8, totals: { kcal: 1200 } },
      shopping_products: [{ name: "beurre", qty: "200", unit: "g" }],
      nutrition_validation: { state: "ok" },
      shopping_products_updated_at: "2026-08-24T12:00:00Z",
    };
    assert.equal(recipeTriggerInputsFingerprint(avant), recipeTriggerInputsFingerprint(apres));
  });

  test("un ingrédient modifié change l'empreinte", () => {
    const apres = recette();
    (apres.ingredients as Array<Record<string, string>>)[0].qty = "250";
    assert.notEqual(
      recipeTriggerInputsFingerprint(recette()),
      recipeTriggerInputsFingerprint(apres),
    );
  });

  test("un ingrédient ajouté ou retiré change l'empreinte", () => {
    const ajout = recette();
    (ajout.ingredients as Array<Record<string, string>>).push({
      name: "sel",
      qty: "1",
      unit: "pincée",
    });
    assert.notEqual(
      recipeTriggerInputsFingerprint(recette()),
      recipeTriggerInputsFingerprint(ajout),
    );

    const retrait = recette();
    (retrait.ingredients as Array<Record<string, string>>).pop();
    assert.notEqual(
      recipeTriggerInputsFingerprint(recette()),
      recipeTriggerInputsFingerprint(retrait),
    );
  });

  test("les autres entrées comptent aussi", () => {
    for (const champ of ["portions", "page_type", "raw_cooklang"]) {
      const apres = recette();
      apres[champ] = champ === "portions" ? 6 : "autre";
      assert.notEqual(
        recipeTriggerInputsFingerprint(recette()),
        recipeTriggerInputsFingerprint(apres),
        `le champ ${champ} devrait compter`,
      );
    }
  });

  test("un champ absent ne se confond pas avec un champ vide", () => {
    // Sans séparateur sûr, « portions absent » et « portions = "" » se
    // ressembleraient, et une vraie modification passerait pour un écho.
    const sansPortions = recette();
    delete sansPortions.portions;
    const portionsVides = { ...recette(), portions: "" };
    assert.equal(
      recipeTriggerInputsFingerprint(sansPortions),
      recipeTriggerInputsFingerprint(portionsVides),
      "les deux valent la chaîne vide, c'est assumé",
    );

    // En revanche, déplacer un caractère d'un champ à l'autre doit se voir.
    const a = { ...recette(), page_type: "recipe", raw_cooklang: "x" };
    const b = { ...recette(), page_type: "recipex", raw_cooklang: "" };
    assert.notEqual(recipeTriggerInputsFingerprint(a), recipeTriggerInputsFingerprint(b));
  });

  test("un document absent rend une empreinte vide", () => {
    // Une création n'a pas de `before` : le déclencheur doit passer.
    assert.equal(recipeTriggerInputsFingerprint(undefined), "");
    assert.notEqual(recipeTriggerInputsFingerprint(recette()), "");
  });
});

describe("fenêtre de relance d'un enrichissement", () => {
  const maintenant = 1_800_000_000_000;

  test("jamais demandé : on demande", () => {
    assert.equal(enrichmentAttemptIsRecent(undefined, maintenant), false);
    assert.equal(enrichmentAttemptIsRecent(null, maintenant), false);
  });

  test("demandé à l'instant : on ne repose pas la question", () => {
    // C'est le cas de la salve : plusieurs chaînes concurrentes sur la même
    // recette, à quelques secondes d'intervalle.
    assert.equal(enrichmentAttemptIsRecent(maintenant - 2_000, maintenant), true);
  });

  test("demandé hier : on redemande", () => {
    assert.equal(
      enrichmentAttemptIsRecent(maintenant - ENRICHMENT_RETRY_AFTER_MS - 1, maintenant),
      false,
    );
  });

  test("un instant Firestore, une date et une chaîne ISO se lisent tous", () => {
    const recent = maintenant - 60_000;
    assert.equal(enrichmentAttemptIsRecent({ toMillis: () => recent }, maintenant), true);
    assert.equal(enrichmentAttemptIsRecent(new Date(recent), maintenant), true);
    assert.equal(enrichmentAttemptIsRecent(new Date(recent).toISOString(), maintenant), true);
  });

  test("une valeur illisible vaut « jamais demandé »", () => {
    // Le doute profite à l'enrichissement : une valeur manquante coûte plus
    // cher qu'un appel de trop.
    assert.equal(enrichmentAttemptIsRecent("pas une date", maintenant), false);
    assert.equal(enrichmentAttemptIsRecent({}, maintenant), false);
    assert.equal(enrichmentAttemptIsRecent({ toMillis: () => NaN }, maintenant), false);
  });
});
