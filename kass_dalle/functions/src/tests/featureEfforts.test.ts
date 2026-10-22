/**
 * L'effort de réflexion que le code de chaque poste demande a une seule source,
 * `ai/featureEfforts.ts`.
 *
 * L'écran Admin › Moteur d'IA l'affiche (« Selon le poste (haute) ») et
 * l'écrit sur les postes qu'il fige avant de changer l'effort par défaut. Une
 * valeur recopiée ailleurs que dans la table ferait afficher un effort que le
 * poste ne reçoit pas.
 *
 * Logique pure : ni Firestore, ni réseau.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { CODE_EFFORTS, DEFAULT_CODE_EFFORT, codeEffortFor } from "../ai/featureEfforts";
import { requestShapeFor } from "../ai/anthropic";
import { ROUTABLE_FEATURES, routableFeaturesForScreen } from "../callable/aiRoutingCallable";
import { TAGGING_EFFORT } from "../gemini/tagging";

describe("effort du code, par poste", () => {
  test("chaque poste de la table est un poste routable", () => {
    const ids = new Set(ROUTABLE_FEATURES.map((f) => f.id));
    for (const feature of Object.keys(CODE_EFFORTS)) {
      assert.ok(ids.has(feature), `« ${feature} » n'est pas dans ROUTABLE_FEATURES`);
    }
  });

  test("un poste absent de la table demande l'effort par défaut", () => {
    assert.equal(codeEffortFor("nutrition_ingredients_enrichment"), DEFAULT_CODE_EFFORT);
    assert.equal(codeEffortFor("constructor"), DEFAULT_CODE_EFFORT);
  });

  test("l'effort par défaut du code est celui de requestShapeFor sans effort", () => {
    assert.equal(requestShapeFor("claude-sonnet-5").effort, DEFAULT_CODE_EFFORT);
  });

  test("les postes de lecture et de détection demandent « high »", () => {
    for (const feature of [
      "transcription_page",
      "text_extraction",
      "url_import_fallback",
      "detect_illustrations",
      "page_illustrations_precheck",
      "page_illustrations_frame",
      "page_illustrations_orientation",
      "page_illustrations_regions",
    ]) {
      assert.equal(codeEffortFor(feature), "high", feature);
    }
    assert.equal(codeEffortFor("recipe_translation"), "medium");
  });

  test("le balisage demande l'effort de ses deux postes", () => {
    // `gemini/tagging.ts` garde sa constante pour sa logique de reprise :
    // elle doit valoir ce que l'écran annonce pour ses postes.
    assert.equal(TAGGING_EFFORT, codeEffortFor("recipe_tagging"));
    assert.equal(TAGGING_EFFORT, codeEffortFor("url_import"));
  });

  test("l'écran reçoit l'effort du code de chaque poste", () => {
    const view = routableFeaturesForScreen();
    assert.equal(view.length, ROUTABLE_FEATURES.length);
    for (const feature of view) {
      assert.equal(feature.codeEffort, codeEffortFor(feature.id), feature.id);
    }
  });
});
