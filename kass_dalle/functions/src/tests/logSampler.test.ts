/**
 * Échantillonnage des journaux répétés (`utils/logSampler.ts`) : refus de
 * signature du webhook des tickets, refus d'accès d'`ensureAdminWithAudit`
 * (ticket #163).
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { KeyedLogSampler, LogSampler } from "../utils/logSampler";

describe("LogSampler", () => {
  test("un relevé par intervalle, avec le compte", () => {
    const log = new LogSampler(60_000);
    assert.equal(log.record(0), 1);
    assert.equal(log.record(10_000), null);
    assert.equal(log.record(59_999), null);
    assert.equal(log.record(60_000), 3);
    assert.equal(log.record(60_001), null);
    assert.equal(log.record(200_000), 2);
  });
});

describe("KeyedLogSampler", () => {
  test("une clé ne tait pas les refus d'une autre", () => {
    const log = new KeyedLogSampler(60_000);
    assert.equal(log.record("op|a", 0), 1);
    assert.equal(log.record("op|b", 1), 1);
    assert.equal(log.record("op|a", 2), null);
    assert.equal(log.record("op|a", 60_000), 2);
    assert.equal(log.record("op|b", 30_000), null);
  });

  test("au-delà de maxKeys, la clé la plus ancienne sort seule", () => {
    const log = new KeyedLogSampler(60_000, 2);
    assert.equal(log.record("a", 0), 1);
    assert.equal(log.record("b", 0), 1);
    assert.equal(log.record("a", 1), null);
    // Troisième clé : « a », la plus ancienne, sort ; « b » garde son état.
    assert.equal(log.record("c", 2), 1);
    assert.equal(log.record("b", 3), null);
    // « a » repart d'un compteur neuf : son premier refus s'écrit.
    assert.equal(log.record("a", 4), 1);
  });
});
