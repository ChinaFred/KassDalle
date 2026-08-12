/**
 * Choix du fournisseur pour un poste fonctionnel.
 *
 * La règle a l'air triviale, mais elle porte la garantie qui rend la bascule
 * sans risque : router un poste vers un moteur dont la clé n'est pas posée ne
 * doit jamais priver l'utilisateur du service. C'est exactement l'état du
 * projet entre le déploiement du code et la création du secret.
 *
 * Logique pure : ni Firestore, ni réseau.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { resolveProvider, DEFAULT_AI_ROUTING_POLICY, type AiRoutingPolicy } from "../ai/router";
import { getPricingForModel } from "../ai/pricing";

function policy(overrides: Partial<AiRoutingPolicy> = {}): AiRoutingPolicy {
  return { ...DEFAULT_AI_ROUTING_POLICY, ...overrides };
}

describe("resolveProvider", () => {
  test("sans politique, tout reste sur Gemini", () => {
    assert.equal(resolveProvider(policy(), "n_importe_quel_poste", true), "gemini");
  });

  test("un poste explicitement routé gagne sur le défaut", () => {
    const p = policy({ features: { nutrition_batch: "anthropic" } });
    assert.equal(resolveProvider(p, "nutrition_batch", true), "anthropic");
    assert.equal(resolveProvider(p, "autre_poste", true), "gemini");
  });

  test("le défaut s'applique aux postes non listés", () => {
    const p = policy({ defaultProvider: "anthropic" });
    assert.equal(resolveProvider(p, "poste_inconnu", true), "anthropic");
  });

  test("sans clé Claude, un poste routé vers Claude est servi par Gemini", () => {
    // L'état normal entre le déploiement et la création du secret : la bascule
    // est enregistrée, mais elle ne prend effet qu'une fois la clé posée.
    const p = policy({ features: { nutrition_batch: "anthropic" } });
    assert.equal(resolveProvider(p, "nutrition_batch", false), "gemini");
  });

  test("l'absence de clé ne dévie jamais un poste resté sur Gemini", () => {
    assert.equal(resolveProvider(policy(), "nutrition_batch", false), "gemini");
  });
});

describe("tarification multi-fournisseur", () => {
  test("un identifiant Claude n'est pas facturé au tarif Gemini", () => {
    const claude = getPricingForModel("claude-sonnet-5");
    const gemini = getPricingForModel("gemini-2.5-flash");
    assert.notEqual(claude.inputPerMillion, gemini.inputPerMillion);
    assert.equal(claude.inputPerMillion, 3.0);
    assert.equal(claude.outputPerMillion, 15.0);
  });

  test("une révision datée d'un modèle Claude retombe sur son préfixe", () => {
    const dated = getPricingForModel("claude-sonnet-5-20260501");
    assert.equal(dated.inputPerMillion, 3.0);
    assert.equal(dated.outputPerMillion, 15.0);
  });
});
