/**
 * Surcouche tarifaire : lecture d'une entrée saisie depuis Admin.
 *
 * La grille en vigueur vit dans Firestore et recouvre celle du code. Une entrée
 * mal formée y arrive par une saisie humaine — c'est le seul endroit du projet
 * où un nombre de facturation est tapé à la main. L'accepter telle quelle
 * ferait facturer un modèle à zéro sans que rien ne bronche ; la refuser rend
 * le tarif du code, qui est au pire dépassé, jamais absurde.
 *
 * Logique pure : ni Firestore, ni réseau.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { parsePricingEntry, pricingEntryToMap, pricingForModelIn } from "../ai/pricing";

describe("lecture d'une entrée saisie", () => {
  test("une entrée complète est retenue", () => {
    const entry = parsePricingEntry({
      input_per_million: 3,
      output_per_million: 15,
      image_output_per_unit: 0.02,
    });
    assert.deepEqual(entry, {
      inputPerMillion: 3,
      outputPerMillion: 15,
      imageOutputPerUnit: 0.02,
      analyzedImagePerUnit: 0,
      freeUnitsPerMonth: 0,
    });
  });

  test("le coût image est facultatif et vaut zéro par défaut", () => {
    assert.equal(
      parsePricingEntry({ input_per_million: 1, output_per_million: 2 })?.imageOutputPerUnit,
      0,
    );
  });

  // Un tarif à l'unité absent doit valoir zéro et non « indéfini » : une
  // multiplication par `undefined` rendrait NaN, et un coût NaN s'affiche sans
  // lever d'erreur — exactement le genre de faux chiffre que la grille
  // Firestore existe pour éviter.
  test("le tarif à l'unité d'une image analysée vaut zéro par défaut", () => {
    const entry = parsePricingEntry({ input_per_million: 1, output_per_million: 2 });
    assert.equal(entry?.analyzedImagePerUnit, 0);
    assert.equal(entry?.freeUnitsPerMonth, 0);
  });

  test("un tarif manquant fait rejeter l'entrée entière", () => {
    // Retenir la moitié d'une entrée facturerait la sortie à zéro.
    assert.equal(parsePricingEntry({ input_per_million: 3 }), null);
    assert.equal(parsePricingEntry({ output_per_million: 15 }), null);
  });

  test("un tarif non numérique est rejeté", () => {
    assert.equal(parsePricingEntry({ input_per_million: "3", output_per_million: 15 }), null);
    assert.equal(parsePricingEntry({ input_per_million: 3, output_per_million: null }), null);
  });

  test("un tarif négatif est rejeté", () => {
    assert.equal(parsePricingEntry({ input_per_million: -1, output_per_million: 15 }), null);
  });

  test("une valeur non finie est rejetée", () => {
    assert.equal(
      parsePricingEntry({ input_per_million: Number.POSITIVE_INFINITY, output_per_million: 1 }),
      null,
    );
  });

  test("une promotion datée est retenue", () => {
    const entry = parsePricingEntry({
      input_per_million: 3,
      output_per_million: 15,
      introductory: {
        input_per_million: 2,
        output_per_million: 10,
        until_iso: "2026-09-01T00:00:00Z",
      },
    });
    assert.equal(entry?.introductory?.inputPerMillion, 2);
  });

  test("une promotion sans date lisible est ignorée, le catalogue reste", () => {
    // Sans borne, une remise devient un tarif permanent le jour où elle expire,
    // et le reporting sous-estime sans que rien ne le signale.
    const entry = parsePricingEntry({
      input_per_million: 3,
      output_per_million: 15,
      introductory: { input_per_million: 2, output_per_million: 10, until_iso: "bientôt" },
    });
    assert.equal(entry?.introductory, undefined);
    assert.equal(entry?.inputPerMillion, 3);
  });

  test("aller-retour Firestore : ce qui est écrit se relit à l'identique", () => {
    const source = {
      input_per_million: 5,
      output_per_million: 25,
      image_output_per_unit: 0.0336,
      introductory: {
        input_per_million: 4,
        output_per_million: 20,
        until_iso: "2026-12-01T00:00:00Z",
      },
    };
    const parsed = parsePricingEntry(source);
    assert.ok(parsed);
    assert.deepEqual(parsePricingEntry(pricingEntryToMap(parsed)), parsed);
  });
});

describe("résolution dans une grille recouverte", () => {
  test("une entrée saisie l'emporte sur celle du code", () => {
    const table = {
      "claude-sonnet-5": { inputPerMillion: 3, outputPerMillion: 15 },
    };
    const overridden = {
      ...table,
      "claude-sonnet-5": { inputPerMillion: 9, outputPerMillion: 40 },
    };
    assert.equal(pricingForModelIn(overridden, "claude-sonnet-5").inputPerMillion, 9);
  });

  test("le préfixe le plus long gagne, surcouche comprise", () => {
    // Le défaut historique : « gemini-2.5-flash » précédait
    // « gemini-2.5-flash-image », et une révision image se résolvait vers le
    // tarif texte — images facturées zéro, reporting crédible et faux.
    const table = {
      "gemini-2.5-flash": { inputPerMillion: 0.3, outputPerMillion: 2.5, imageOutputPerUnit: 0 },
      "gemini-2.5-flash-image": {
        inputPerMillion: 0.3,
        outputPerMillion: 2.5,
        imageOutputPerUnit: 0.04,
      },
    };
    assert.equal(
      pricingForModelIn(table, "gemini-2.5-flash-image-preview").imageOutputPerUnit,
      0.04,
    );
  });

  test("un modèle inconnu retombe sur le tarif par défaut, jamais sur zéro", () => {
    const pricing = pricingForModelIn({}, "modele-jamais-vu");
    assert.ok(pricing.inputPerMillion > 0);
    assert.ok(pricing.outputPerMillion > 0);
  });
});
