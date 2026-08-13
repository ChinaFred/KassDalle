/**
 * Périodes de facturation.
 *
 * La réconciliation planifiée choisit sa période toute seule. Un décalage d'un
 * mois — le passage de janvier à décembre de l'année précédente, typiquement —
 * produirait un rapport parfaitement crédible et parfaitement faux : il
 * comparerait le traçage d'un mois à la facturation d'un autre, et l'écart
 * obtenu serait présenté comme une anomalie de coûts.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { nowPeriod, previousPeriod, periodBounds } from "../billing/periods";

describe("nowPeriod", () => {
  test("rend le mois en cours sur deux chiffres", () => {
    assert.equal(nowPeriod(new Date(Date.UTC(2026, 7, 11))), "2026-08");
  });

  test("garde le zéro de tête en janvier", () => {
    assert.equal(nowPeriod(new Date(Date.UTC(2026, 0, 1))), "2026-01");
  });
});

describe("previousPeriod", () => {
  test("rend le mois précédent", () => {
    assert.equal(previousPeriod(new Date(Date.UTC(2026, 7, 4))), "2026-07");
  });

  test("garde le zéro de tête", () => {
    assert.equal(previousPeriod(new Date(Date.UTC(2026, 5, 4))), "2026-05");
  });

  test("recule d'une année au passage de janvier", () => {
    assert.equal(previousPeriod(new Date(Date.UTC(2026, 0, 4))), "2025-12");
  });

  test("le premier jour du mois compte déjà pour le mois précédent", () => {
    assert.equal(previousPeriod(new Date(Date.UTC(2026, 2, 1))), "2026-02");
  });

  test("le dernier instant du mois n'a pas encore basculé", () => {
    assert.equal(previousPeriod(new Date(Date.UTC(2026, 2, 31, 23, 59, 59))), "2026-02");
  });
});

describe("periodBounds", () => {
  test("début inclus, fin exclue", () => {
    const bounds = periodBounds("2026-02");
    assert.ok(bounds);
    assert.equal(bounds.start.toISOString(), "2026-02-01T00:00:00.000Z");
    assert.equal(bounds.end.toISOString(), "2026-03-01T00:00:00.000Z");
  });

  test("passe l'année sur décembre", () => {
    const bounds = periodBounds("2025-12");
    assert.ok(bounds);
    assert.equal(bounds.start.toISOString(), "2025-12-01T00:00:00.000Z");
    assert.equal(bounds.end.toISOString(), "2026-01-01T00:00:00.000Z");
  });

  test("février bissextile va bien jusqu'au 1er mars", () => {
    const bounds = periodBounds("2028-02");
    assert.ok(bounds);
    assert.equal(bounds.end.toISOString(), "2028-03-01T00:00:00.000Z");
  });

  for (const invalid of ["2026-13", "2026-00", "2026", "26-01", "", "abcd-ef"]) {
    test(`« ${invalid} » est refusé plutôt qu'interprété`, () => {
      assert.equal(periodBounds(invalid), null);
    });
  }
});
