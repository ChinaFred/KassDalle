/**
 * Nommage d'un traitement dans les journaux.
 *
 * Ce que ces tests verrouillent : le deux-points reste la frontière entre le
 * nom d'une étape et la précision qui distingue ce départ-là des autres. Si un
 * détail libre pouvait y glisser un second deux-points, ou des caractères que
 * l'écran ne sait pas recouper, le titre du groupe redeviendrait illisible —
 * sans qu'aucune erreur ne soit levée.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { newCorrelationId, qualify } from "../logging";

describe("qualify", () => {
  test("sans détail utilisable, le nom reste seul", () => {
    // Un suffixe vide serait pire que pas de suffixe : « … — » ne dit rien.
    assert.equal(qualify("generation_recette", undefined), "generation_recette");
    assert.equal(qualify("generation_recette", null), "generation_recette");
    assert.equal(qualify("generation_recette", 3), "generation_recette");
    assert.equal(qualify("generation_recette", "   "), "generation_recette");
    assert.equal(qualify("generation_recette", "!!!"), "generation_recette");
  });

  test("le détail est mis en slug : accents, espaces, casse", () => {
    assert.equal(qualify("generation_recette", "Créative"), "generation_recette:creative");
    assert.equal(
      qualify("ecriture_recette", "Ingrédients modifiés"),
      "ecriture_recette:ingredients-modifies",
    );
  });

  test("un détail hostile ne casse pas la frontière", () => {
    // Un second deux-points ferait mentir le découpage côté écran.
    const out = qualify("etape", "a:b/c d");
    assert.equal(out.split(":").length, 2);
    assert.equal(out, "etape:a-b-c-d");
  });

  test("un détail interminable est borné", () => {
    const out = qualify("etape", "x".repeat(200));
    assert.ok(out.length < 60, `trop long : ${out.length}`);
  });
});

describe("newCorrelationId", () => {
  test("la racine survit à l'horodatage et à l'aléa", () => {
    // C'est cette racine que l'écran retire pour retrouver le nom du
    // traitement : le motif doit rester `nom_chiffres_alea`.
    const id = newCorrelationId("import_recette");
    assert.match(id, /^import_recette_\d{10,}_[a-z0-9]+$/);
  });

  test("une racine qualifiée reste reconnaissable", () => {
    const id = newCorrelationId(qualify("ecriture_recette", "sans changement"));
    assert.match(id, /^ecriture_recette:sans-changement_\d{10,}_[a-z0-9]+$/);
  });

  test("deux appels ne se confondent pas", () => {
    assert.notEqual(newCorrelationId("a"), newCorrelationId("a"));
  });
});
