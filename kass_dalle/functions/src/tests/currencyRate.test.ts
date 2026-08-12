/**
 * Validation du taux de change relevé dans l'export de facturation.
 *
 * Ce taux décide de tous les montants affichés en euros. Un taux aberrant accepté
 * ne casse rien et ne lève rien : il change silencieusement l'échelle de l'écran
 * Comptabilité. C'est exactement le genre d'erreur que le projet cherche à rendre
 * impossible — d'où des bornes de vraisemblance, et des tests dessus.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { validateCurrencyRate } from "../billing/currencyRate";

describe("validateCurrencyRate", () => {
  test("un taux plausible passe, avec sa devise", () => {
    const result = validateCurrencyRate({ rate: 0.856, currency: "EUR" });
    assert.equal(result.ok, true);
    if (!result.ok) return;
    assert.equal(result.reading.rate, 0.856);
    assert.equal(result.reading.currency, "EUR");
  });

  test("un taux rendu sous forme de chaîne par BigQuery est accepté", () => {
    const result = validateCurrencyRate({ rate: "0.91", currency: "EUR" });
    assert.equal(result.ok, true);
    if (!result.ok) return;
    assert.equal(result.reading.rate, 0.91);
  });

  test("la devise est débarrassée de ses espaces", () => {
    const result = validateCurrencyRate({ rate: 1, currency: "  USD " });
    assert.equal(result.ok, true);
    if (!result.ok) return;
    assert.equal(result.reading.currency, "USD");
  });

  test("une période sans aucune ligne ne rend pas de taux", () => {
    const result = validateCurrencyRate({ rate: null, currency: "EUR" });
    assert.equal(result.ok, false);
    if (result.ok) return;
    assert.match(result.reason, /aucun taux/);
  });

  test("un taux nul est refusé plutôt qu'écrit", () => {
    const result = validateCurrencyRate({ rate: 0, currency: "EUR" });
    assert.equal(result.ok, false);
  });

  test("un taux d'un facteur mille est refusé", () => {
    const result = validateCurrencyRate({ rate: 920, currency: "EUR" });
    assert.equal(result.ok, false);
    if (result.ok) return;
    assert.match(result.reason, /vraisemblance/);
  });

  test("un taux négatif est refusé", () => {
    assert.equal(validateCurrencyRate({ rate: -0.92, currency: "EUR" }).ok, false);
  });

  test("un taux sans devise est refusé : un nombre seul ne se convertit pas", () => {
    const result = validateCurrencyRate({ rate: 0.86, currency: "" });
    assert.equal(result.ok, false);
    if (result.ok) return;
    assert.match(result.reason, /devise/);
  });

  test("les bornes elles-mêmes sont acceptées", () => {
    assert.equal(validateCurrencyRate({ rate: 0.1, currency: "EUR" }).ok, true);
    assert.equal(validateCurrencyRate({ rate: 10, currency: "EUR" }).ok, true);
  });
});
