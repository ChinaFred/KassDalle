/**
 * Franchise mensuelle : ce qu'un fournisseur offre, et comment on le déduit.
 *
 * La règle vit côté serveur seul. Le client lit la grille pour annoncer ce
 * qu'un appel VA coûter, et une franchise ne change pas ce prix-là : elle
 * s'applique au mois, une fois les unités comptées. L'écrire en double côté
 * Dart ajouterait une divergence possible sans rien rendre.
 *
 * Logique pure : ni Firestore, ni réseau.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { freeTierCredits, type AiModelPricing } from "../ai/pricing";

const VISION: AiModelPricing = {
  inputPerMillion: 0,
  outputPerMillion: 0,
  imageOutputPerUnit: 0,
  analyzedImagePerUnit: 0.0015,
  freeUnitsPerMonth: 1000,
};

const FLASH: AiModelPricing = {
  inputPerMillion: 0.3,
  outputPerMillion: 2.5,
  imageOutputPerUnit: 0,
};

const TABLE = { "cloud-vision-safesearch": VISION, "gemini-2.5-flash": FLASH };
const AT = new Date("2026-09-15T12:00:00Z");

/** Un mois qui a consommé `units` unités pour `costUsd` dollars. */
function month(units: number, costUsd: number) {
  return {
    table: TABLE,
    at: AT,
    unitsFor: (m: string) => (m === "cloud-vision-safesearch" ? units : 0),
    costFor: (m: string) => (m === "cloud-vision-safesearch" ? costUsd : 0),
  };
}

describe("franchise mensuelle", () => {
  test("sous la franchise, tout est offert", () => {
    const credits = freeTierCredits(month(138, 0.207));
    assert.equal(credits.length, 1);
    assert.equal(credits[0].model, "cloud-vision-safesearch");
    assert.equal(credits[0].units, 138);
    assert.equal(credits[0].coveredUnits, 138);
    assert.ok(Math.abs(credits[0].creditUsd - 0.207) < 1e-9);
  });

  test("au-delà, seules les unités offertes le sont", () => {
    // 2 400 unités consommées, 1 000 offertes : l'avoir plafonne à 1,50 $ et
    // n'augmente plus. C'est le point où la franchise cesse de compter.
    const credits = freeTierCredits(month(2400, 3.6));
    assert.equal(credits[0].coveredUnits, 1000);
    assert.ok(Math.abs(credits[0].creditUsd - 1.5) < 1e-9);
  });

  test("exactement la franchise : tout est offert, rien de plus", () => {
    const credits = freeTierCredits(month(1000, 1.5));
    assert.equal(credits[0].coveredUnits, 1000);
    assert.ok(Math.abs(credits[0].creditUsd - 1.5) < 1e-9);
  });

  test("un mois sans unités comptées ne reçoit aucun avoir", () => {
    // Le cas des mois antérieurs au comptage : on ne SAIT PAS combien
    // d'unités ils ont consommé. Une franchise devinée ferait afficher un
    // mois moins cher qu'il ne l'a été.
    assert.deepEqual(freeTierCredits(month(0, 0)), []);
  });

  test("l'avoir ne dépasse jamais ce qui a été compté", () => {
    // Un tarif corrigé en cours de mois peut rendre l'avoir théorique
    // supérieur à la dépense enregistrée. Sans borne, le mois s'afficherait
    // en négatif — un montant que personne n'a reçu.
    const credits = freeTierCredits(month(800, 0.4));
    assert.ok(Math.abs(credits[0].creditUsd - 0.4) < 1e-9);
  });

  test("un modèle sans franchise n'apparaît pas", () => {
    const credits = freeTierCredits({
      table: TABLE,
      at: AT,
      unitsFor: () => 500,
      costFor: () => 10,
    });
    assert.equal(credits.length, 1);
    assert.equal(credits[0].model, "cloud-vision-safesearch");
  });

  test("une grille sans tarif à l'unité n'offre rien", () => {
    // Une franchise déclarée sur un prix nul offrirait zéro dollar : la ligne
    // n'a rien à faire à l'écran, elle ferait croire à une remise.
    const credits = freeTierCredits({
      table: { m: { inputPerMillion: 1, outputPerMillion: 2, freeUnitsPerMonth: 1000 } },
      at: AT,
      unitsFor: () => 500,
      costFor: () => 10,
    });
    assert.deepEqual(credits, []);
  });

  test("des unités négatives ne créent pas d'avoir", () => {
    const credits = freeTierCredits(month(-50, 1));
    assert.deepEqual(credits, []);
  });

  test("les avoirs sortent du plus lourd au plus léger", () => {
    const table = {
      a: {
        inputPerMillion: 0,
        outputPerMillion: 0,
        analyzedImagePerUnit: 0.01,
        freeUnitsPerMonth: 100,
      },
      b: {
        inputPerMillion: 0,
        outputPerMillion: 0,
        analyzedImagePerUnit: 0.1,
        freeUnitsPerMonth: 100,
      },
    };
    const credits = freeTierCredits({
      table,
      at: AT,
      unitsFor: () => 100,
      costFor: () => 100,
    });
    assert.deepEqual(
      credits.map((c) => c.model),
      ["b", "a"],
    );
  });
});
