/**
 * Le modèle Claude se choisit POSTE PAR POSTE.
 *
 * Ce que ces tests verrouillent : basculer un poste sur Claude n'impose plus le
 * même modèle à tous les autres. Les postes n'ont pas les mêmes exigences —
 * transcrire une page de livre demande de la précision et se paie à la page,
 * estimer les calories d'une carotte est un rappel de connaissances répété
 * quinze fois par recette. Un seul modèle pour les deux, c'était soit payer
 * Opus pour la carotte, soit lire le livre avec Haiku.
 *
 * Et le mauvais choix ne se voit ni dans un sens ni dans l'autre : un modèle
 * trop petit rend une page abîmée qui a l'air correcte, un modèle trop grand
 * rend une facture qui a l'air normale.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  DEFAULT_AI_ROUTING_POLICY,
  resolveAnthropicEffort,
  resolveAnthropicModel,
  type AiRoutingPolicy,
} from "../ai/router";
import { ANTHROPIC_EFFORT_CHOICES, ANTHROPIC_MODEL_CHOICES } from "../callable/aiRoutingCallable";
import { builtinPricingTable } from "../ai/pricing";
import { requestShapeFor } from "../ai/anthropic";

function policy(over: Partial<AiRoutingPolicy> = {}): AiRoutingPolicy {
  return { ...DEFAULT_AI_ROUTING_POLICY, ...over };
}

describe("modèle Claude par poste", () => {
  test("un poste sans exception suit le modèle général", () => {
    const p = policy({ anthropicModel: "claude-sonnet-5" });
    assert.equal(resolveAnthropicModel(p, "transcription_page"), "claude-sonnet-5");
  });

  test("un poste avec exception l'emporte", () => {
    const p = policy({
      anthropicModel: "claude-sonnet-5",
      anthropicModels: { transcription_page: "claude-opus-5" },
    });
    assert.equal(resolveAnthropicModel(p, "transcription_page"), "claude-opus-5");
    // Et n'entraîne pas ses voisins.
    assert.equal(resolveAnthropicModel(p, "recipe_tagging"), "claude-sonnet-5");
  });

  test("une exception vide ne remplace rien", () => {
    // Une chaîne vide en base ne doit pas produire un appel sans modèle.
    const p = policy({
      anthropicModel: "claude-sonnet-5",
      anthropicModels: { transcription_page: "   " },
    });
    assert.equal(resolveAnthropicModel(p, "transcription_page"), "claude-sonnet-5");
  });

  test("la politique par défaut n'impose aucune exception", () => {
    assert.deepEqual(DEFAULT_AI_ROUTING_POLICY.anthropicModels, {});
  });
});

describe("effort de réflexion Claude par poste", () => {
  test("un poste sans réglage n'a pas d'effort imposé", () => {
    // `null`, pas un effort par défaut : la mesure du 27 septembre 2026 a
    // montré que la lecture de page et le balisage ne veulent pas du même
    // soin — aucun effort commun ne serait honnête ici.
    assert.equal(resolveAnthropicEffort(policy(), "transcription_page"), null);
  });

  test("un réglage l'emporte, et n'entraîne pas ses voisins", () => {
    const p = policy({ anthropicEfforts: { transcription_page: "medium" } });
    assert.equal(resolveAnthropicEffort(p, "transcription_page"), "medium");
    assert.equal(resolveAnthropicEffort(p, "recipe_tagging"), null);
  });

  test("une valeur hors des trois efforts admis n'est pas retenue", () => {
    const p = policy({
      anthropicEfforts: { transcription_page: "xhigh" as unknown as "high" },
    });
    assert.equal(resolveAnthropicEffort(p, "transcription_page"), null);
  });

  test("la politique par défaut n'impose aucun effort", () => {
    assert.deepEqual(DEFAULT_AI_ROUTING_POLICY.anthropicEfforts, {});
    assert.equal(DEFAULT_AI_ROUTING_POLICY.anthropicEffort, null);
  });

  test("l'effort par défaut sert les postes sans réglage propre", () => {
    const p = policy({ anthropicEffort: "medium" });
    assert.equal(resolveAnthropicEffort(p, "transcription_page"), "medium");
    assert.equal(resolveAnthropicEffort(p, "recipe_tagging"), "medium");
  });

  test("le réglage du poste l'emporte sur l'effort par défaut", () => {
    const p = policy({
      anthropicEffort: "low",
      anthropicEfforts: { transcription_page: "high" },
    });
    assert.equal(resolveAnthropicEffort(p, "transcription_page"), "high");
    assert.equal(resolveAnthropicEffort(p, "recipe_tagging"), "low");
  });

  test("un effort par défaut illisible ne s'applique pas", () => {
    const p = policy({ anthropicEffort: "xhigh" as unknown as "high" });
    assert.equal(resolveAnthropicEffort(p, "transcription_page"), null);
  });
});

describe("les efforts proposés sont bien formés", () => {
  test("chacun porte un libellé et une indication d'usage", () => {
    for (const choice of ANTHROPIC_EFFORT_CHOICES) {
      assert.ok(choice.label.trim().length > 0, choice.id);
      assert.ok(choice.hint.trim().length > 0, choice.id);
    }
  });

  test("les trois niveaux admis sont proposés, ni plus ni moins", () => {
    assert.deepEqual(ANTHROPIC_EFFORT_CHOICES.map((c) => c.id).sort(), ["high", "low", "medium"]);
  });
});

describe("les modèles proposés sont facturables", () => {
  test("chacun figure dans la grille tarifaire", () => {
    // Un identifiant hors grille se facturerait sans montant et gonflerait
    // `total_unpriced_calls` : un coût invisible, ce que ce projet refuse.
    const grille = builtinPricingTable();
    for (const choice of ANTHROPIC_MODEL_CHOICES) {
      assert.ok(
        grille[choice.id],
        `« ${choice.id} » n'a pas de tarif : son coût ne serait pas compté.`,
      );
    }
  });

  test("chacun porte un libellé et une indication d'usage", () => {
    // Le choix ne se devine pas depuis un identifiant technique.
    for (const choice of ANTHROPIC_MODEL_CHOICES) {
      assert.ok(choice.label.trim().length > 0, choice.id);
      assert.ok(choice.hint.trim().length > 0, choice.id);
    }
  });

  test("supportsEffort suit la forme de la requête", () => {
    // L'écran remplace les puces de réflexion par « Pas de réflexion avec … »
    // sur un modèle qui ne reçoit pas l'effort : les deux doivent s'accorder.
    for (const choice of ANTHROPIC_MODEL_CHOICES) {
      assert.equal(
        choice.supportsEffort,
        requestShapeFor(choice.id, "high").effort !== null,
        choice.id,
      );
    }
    assert.equal(
      ANTHROPIC_MODEL_CHOICES.find((c) => c.id === "claude-haiku-4-5")?.supportsEffort,
      false,
    );
  });

  test("le modèle par défaut du projet figure dans la liste", () => {
    // Sans quoi l'écran afficherait trois choix dont aucun n'est celui en
    // vigueur, et le premier clic changerait le comportement sans le dire.
    assert.ok(
      ANTHROPIC_MODEL_CHOICES.some((c) => c.id === DEFAULT_AI_ROUTING_POLICY.anthropicModel),
    );
  });
});
