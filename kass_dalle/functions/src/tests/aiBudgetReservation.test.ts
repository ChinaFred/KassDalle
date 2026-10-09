/**
 * Réservation du plafond avant l'appel (audit sécurité, faille 8) : les appels
 * en cours comptent comme dépensés, une rafale ne passe plus tout entière, et
 * aucun prix n'est inventé. Logique pure.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import {
  DEFAULT_AI_BUDGET_POLICY,
  EMPTY_DAILY_SPEND,
  MAX_CONCURRENT_AI_CALLS_PER_USER,
  RESERVATION_TTL_MS,
  estimatedCallCostUsd,
  parseReservations,
  reservationDecision,
  type AiBudgetPolicy,
  type DailySpend,
  type SpendReservation,
} from "../ai/budget";

const NOW = 1_800_000_000_000;

function policy(over: Partial<AiBudgetPolicy> = {}): AiBudgetPolicy {
  return { ...DEFAULT_AI_BUDGET_POLICY, ...over };
}

function inFlight(n: number, usd = 0, atMs = NOW - 1_000): Record<string, SpendReservation> {
  const out: Record<string, SpendReservation> = {};
  for (let i = 0; i < n; i++) out[`r${i}`] = { atMs, usd };
  return out;
}

describe("estimatedCallCostUsd", () => {
  test("moyenne des appels chiffrés du jour", () => {
    const spend: DailySpend = { costUsd: 0.3, calls: 4, unpricedCalls: 1 };
    assert.ok(Math.abs(estimatedCallCostUsd(spend) - 0.1) < 1e-12);
  });

  test("aucun appel chiffré, ou grille en panne : zéro, jamais un prix inventé", () => {
    assert.equal(estimatedCallCostUsd(EMPTY_DAILY_SPEND), 0);
    assert.equal(estimatedCallCostUsd({ costUsd: 0, calls: 5, unpricedCalls: 5 }), 0);
  });
});

describe("parseReservations", () => {
  test("ignore les entrées illisibles, borne un montant négatif à zéro", () => {
    const parsed = parseReservations({
      a: { at_ms: NOW, usd: 0.02 },
      b: { at_ms: "x" },
      c: "n'importe quoi",
      d: { at_ms: NOW, usd: -3 },
    });
    assert.deepEqual(parsed, { a: { atMs: NOW, usd: 0.02 }, d: { atMs: NOW, usd: 0 } });
    assert.deepEqual(parseReservations(undefined), {});
  });
});

describe("reservationDecision", () => {
  const base = { policy: policy(), usdToEur: 0.9, nowMs: NOW, interactive: true };

  test("rien en cours, rien dépensé : la place est donnée", () => {
    const d = reservationDecision({ ...base, spend: EMPTY_DAILY_SPEND, reservations: {} });
    assert.equal(d.denial, null);
    assert.equal(d.concurrencyFull, false);
    assert.equal(d.estimateUsd, 0);
  });

  test("rafale : les appels en cours comptent pour le plafond d'appels", () => {
    const p = policy({ dailyCallsPerUser: 10 });
    const spend: DailySpend = { costUsd: 0, calls: 7, unpricedCalls: 7 };
    // 7 enregistrés + 3 en cours = 10 : le onzième est refusé, alors que le
    // compteur seul (7) l'aurait laissé passer.
    const d = reservationDecision({ ...base, policy: p, spend, reservations: inFlight(3) });
    assert.equal(d.denial?.reason, "calls");
    const before = reservationDecision({ ...base, policy: p, spend, reservations: inFlight(2) });
    assert.equal(before.denial, null);
  });

  test("rafale : la dépense estimée des appels en cours compte pour le plafond en euros", () => {
    // Plafond 2 € à 0,9 → 2,22 $. Déjà dépensé 2,0 $ ; trois appels en cours
    // à 0,1 $ estimés chacun → 2,3 $ : refusé.
    const spend: DailySpend = { costUsd: 2.0, calls: 20, unpricedCalls: 0 };
    const d = reservationDecision({ ...base, spend, reservations: inFlight(3, 0.1) });
    assert.equal(d.denial?.reason, "cost");
    const ok = reservationDecision({ ...base, spend, reservations: inFlight(1, 0.1) });
    assert.equal(ok.denial, null);
    assert.equal(ok.estimateUsd, 0.1);
  });

  test("toutes les places prises : attendre, pas refuser pour la journée", () => {
    const d = reservationDecision({
      ...base,
      spend: EMPTY_DAILY_SPEND,
      reservations: inFlight(MAX_CONCURRENT_AI_CALLS_PER_USER),
    });
    assert.equal(d.denial, null);
    assert.equal(d.concurrencyFull, true);
  });

  test("appel du serveur (pipeline, déclencheur) : jamais limité en simultanéité", () => {
    const d = reservationDecision({
      ...base,
      interactive: false,
      spend: EMPTY_DAILY_SPEND,
      reservations: inFlight(MAX_CONCURRENT_AI_CALLS_PER_USER * 5),
    });
    assert.equal(d.concurrencyFull, false);
    assert.equal(d.denial, null);
  });

  test("appel du serveur : ses réservations comptent quand même dans les plafonds", () => {
    const p = policy({ dailyCallsPerUser: 10 });
    const spend: DailySpend = { costUsd: 0, calls: 7, unpricedCalls: 7 };
    const d = reservationDecision({
      ...base,
      interactive: false,
      policy: p,
      spend,
      reservations: inFlight(3),
    });
    assert.equal(d.denial?.reason, "calls");
  });

  test("les réservations du serveur occupent les places d'un appel d'utilisateur", () => {
    // Un import en cours (dix appels serveur) : un appel lancé à la main par le
    // même compte attend une place.
    const d = reservationDecision({
      ...base,
      spend: EMPTY_DAILY_SPEND,
      reservations: inFlight(MAX_CONCURRENT_AI_CALLS_PER_USER),
    });
    assert.equal(d.concurrencyFull, true);
  });

  test("le multiplicateur du fondateur s'applique aussi à la concurrence", () => {
    const d = reservationDecision({
      ...base,
      spend: EMPTY_DAILY_SPEND,
      reservations: inFlight(MAX_CONCURRENT_AI_CALLS_PER_USER),
      multiplier: 100,
    });
    assert.equal(d.concurrencyFull, false);
  });

  test("une réservation expirée ne compte plus et se retire", () => {
    const old = inFlight(MAX_CONCURRENT_AI_CALLS_PER_USER, 5, NOW - RESERVATION_TTL_MS - 1);
    const d = reservationDecision({ ...base, spend: EMPTY_DAILY_SPEND, reservations: old });
    assert.equal(d.concurrencyFull, false);
    assert.equal(d.denial, null);
    assert.equal(d.stale.length, MAX_CONCURRENT_AI_CALLS_PER_USER);
    assert.equal(d.inFlight, 0);
  });

  test("plafonds coupés : ni refus, ni limite de concurrence", () => {
    const d = reservationDecision({
      ...base,
      policy: policy({ enabled: false }),
      spend: { costUsd: 1_000, calls: 1_000_000, unpricedCalls: 0 },
      reservations: inFlight(100),
    });
    assert.equal(d.denial, null);
    assert.equal(d.concurrencyFull, false);
  });

  test("sans taux de change : seul le plafond d'appels décide", () => {
    const spend: DailySpend = { costUsd: 1_000, calls: 1, unpricedCalls: 0 };
    const d = reservationDecision({ ...base, usdToEur: null, spend, reservations: {} });
    assert.equal(d.denial, null);
  });
});
