/**
 * Lecture d'une politique de routage et configurations enregistrées.
 *
 * Deux pannes possibles, et aucune ne lève d'erreur d'elle-même.
 *
 * La première : une configuration enregistrée en juillet nomme un poste retiré
 * depuis. Refusée en bloc, elle devient inchargeable sans qu'aucun message ne
 * dise lequel des quarante-trois postes bloque.
 *
 * La seconde : un aller-retour Firestore qui perd un champ. La configuration
 * « Haute performance » porte l'état réglé à la main avant que cet écran ne
 * sache l'enregistrer ; un plafond de raisonnement égaré à l'écriture ne se
 * voit qu'à la facture du mois suivant.
 *
 * Logique pure : ni Firestore, ni réseau.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { DEFAULT_AI_ROUTING_POLICY, type AiRoutingPolicy } from "../ai/router";
import {
  buildRoutingCatalog,
  normalizePresetName,
  presetNameKey,
  presetPolicyFromMap,
  presetPolicyToMap,
  readRoutingPolicy,
  RoutingPolicyError,
  PRESET_NAME_MAX_LENGTH,
} from "../ai/routingPresets";

const CATALOG = buildRoutingCatalog({
  providers: ["gemini", "anthropic"],
  features: [
    { id: "transcription_page" },
    { id: "generate" },
    // Le poste verrouillé sur Cloud Vision : un seul fournisseur admis.
    { id: "image_moderation", providers: ["vision"] },
  ],
  models: [{ id: "claude-opus-5" }, { id: "claude-sonnet-5" }, { id: "claude-haiku-4-5" }],
});

describe("readRoutingPolicy — écriture de la politique en vigueur", () => {
  test("un poste inconnu refuse la politique entière", () => {
    assert.throws(
      () =>
        readRoutingPolicy({ features: { poste_disparu: "anthropic" } }, CATALOG, {
          onUnknown: "reject",
        }),
      RoutingPolicyError,
    );
  });

  test("un fournisseur hors de la liste d'un poste est refusé", () => {
    // « Tout Claude » écrivait `anthropic` sur la modération, servie par Cloud
    // Vision : c'est la politique ENTIÈRE qui était alors rejetée.
    assert.throws(
      () =>
        readRoutingPolicy({ features: { image_moderation: "anthropic" } }, CATALOG, {
          onUnknown: "reject",
        }),
      RoutingPolicyError,
    );
  });

  test("un modèle Claude hors grille est refusé", () => {
    assert.throws(
      () =>
        readRoutingPolicy({ anthropicModels: { generate: "claude-opus-4" } }, CATALOG, {
          onUnknown: "reject",
        }),
      RoutingPolicyError,
    );
  });

  test("un poste réglé sur le modèle par défaut n'écrit aucune exception", () => {
    const { policy } = readRoutingPolicy(
      { anthropicModel: "claude-sonnet-5", anthropicModels: { generate: "claude-sonnet-5" } },
      CATALOG,
      { onUnknown: "reject" },
    );
    assert.deepEqual(policy.anthropicModels, {});
  });

  test("un plafond de raisonnement hors bornes est refusé", () => {
    assert.throws(
      () => readRoutingPolicy({ thinkingBudget: 999999 }, CATALOG, { onUnknown: "reject" }),
      RoutingPolicyError,
    );
    assert.throws(
      () => readRoutingPolicy({ thinkingBudget: -1 }, CATALOG, { onUnknown: "reject" }),
      RoutingPolicyError,
    );
  });

  test("une politique vide vaut la politique par défaut", () => {
    const { policy } = readRoutingPolicy({}, CATALOG, { onUnknown: "reject" });
    assert.equal(policy.defaultProvider, DEFAULT_AI_ROUTING_POLICY.defaultProvider);
    assert.equal(policy.fallbackEnabled, true);
    assert.equal(policy.thinkingBudget, null);
  });
});

describe("readRoutingPolicy — relecture d'une configuration enregistrée", () => {
  test("un poste disparu est écarté, les autres arrivent intacts", () => {
    const { policy, stale } = readRoutingPolicy(
      {
        features: {
          transcription_page: "anthropic",
          detect_duplicate_ingredients: "anthropic",
          generate: "gemini",
        },
      },
      CATALOG,
      { onUnknown: "drop" },
    );

    assert.deepEqual(policy.features, {
      transcription_page: "anthropic",
      generate: "gemini",
    });
    assert.equal(stale.length, 1);
    assert.match(stale[0], /detect_duplicate_ingredients/);
  });

  test("un modèle Claude sorti de la grille rend le poste au modèle par défaut", () => {
    const { policy, stale } = readRoutingPolicy(
      { anthropicModel: "claude-sonnet-5", anthropicModels: { generate: "claude-opus-4" } },
      CATALOG,
      { onUnknown: "drop" },
    );

    assert.deepEqual(policy.anthropicModels, {});
    assert.equal(policy.anthropicModel, "claude-sonnet-5");
    assert.equal(stale.length, 1);
  });

  test("un poste verrouillé écarte la valeur sans emporter la configuration", () => {
    const { policy, stale } = readRoutingPolicy(
      { features: { image_moderation: "anthropic", generate: "anthropic" } },
      CATALOG,
      { onUnknown: "drop" },
    );

    assert.deepEqual(policy.features, { generate: "anthropic" });
    assert.equal(stale.length, 1);
  });

  test("une relecture sans anomalie ne signale rien", () => {
    const { stale } = readRoutingPolicy({ features: { generate: "anthropic" } }, CATALOG, {
      onUnknown: "drop",
    });
    assert.deepEqual(stale, []);
  });
});

describe("aller-retour Firestore d'une configuration", () => {
  test("les sept réglages survivent à l'écriture puis à la relecture", () => {
    // C'est ce que subit « Haute performance » : la politique en vigueur est
    // écrite telle quelle, puis relue à chaque ouverture de l'écran. Un champ
    // égaré ici ne se verrait qu'à la facture.
    const source: AiRoutingPolicy = {
      defaultProvider: "anthropic",
      features: { transcription_page: "anthropic", generate: "gemini" },
      anthropicModel: "claude-opus-5",
      anthropicModels: { generate: "claude-haiku-4-5" },
      fallbackEnabled: false,
      thinkingBudget: 2048,
      thinkingBudgets: { generate: 0 },
    };

    const { policy, stale } = readRoutingPolicy(
      presetPolicyFromMap(presetPolicyToMap(source)),
      CATALOG,
      { onUnknown: "drop" },
    );

    assert.deepEqual(stale, []);
    assert.deepEqual(policy, source);
  });

  test("un plafond coupé ne se confond pas avec un plafond absent", () => {
    // `0` coupe le raisonnement, `null` laisse le modèle décider. Les deux se
    // ressemblent à la lecture d'un document et ne coûtent pas la même chose.
    const coupe = presetPolicyToMap({ ...DEFAULT_AI_ROUTING_POLICY, thinkingBudget: 0 });
    const absent = presetPolicyToMap({ ...DEFAULT_AI_ROUTING_POLICY, thinkingBudget: null });

    assert.equal(
      readRoutingPolicy(presetPolicyFromMap(coupe), CATALOG, { onUnknown: "drop" }).policy
        .thinkingBudget,
      0,
    );
    assert.equal(
      readRoutingPolicy(presetPolicyFromMap(absent), CATALOG, { onUnknown: "drop" }).policy
        .thinkingBudget,
      null,
    );
  });

  test("un document vide relit la politique par défaut plutôt que d'échouer", () => {
    const { policy } = readRoutingPolicy(presetPolicyFromMap(undefined), CATALOG, {
      onUnknown: "drop",
    });
    assert.deepEqual(policy, DEFAULT_AI_ROUTING_POLICY);
  });
});

describe("nom d'une configuration", () => {
  test("les espaces sont réduits, les bords supprimés", () => {
    assert.equal(normalizePresetName("  Haute   performance "), "Haute performance");
  });

  test("un nom vide est refusé", () => {
    assert.throws(() => normalizePresetName("   "), RoutingPolicyError);
    assert.throws(() => normalizePresetName(null), RoutingPolicyError);
  });

  test("un nom trop long est refusé", () => {
    assert.throws(
      () => normalizePresetName("x".repeat(PRESET_NAME_MAX_LENGTH + 1)),
      RoutingPolicyError,
    );
  });

  test("deux noms qui ne diffèrent que par la casse sont le même nom", () => {
    assert.equal(presetNameKey("Haute Performance"), presetNameKey("haute performance"));
  });
});
