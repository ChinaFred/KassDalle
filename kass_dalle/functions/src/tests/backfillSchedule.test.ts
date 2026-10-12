/**
 * Programmation des backfills récurrents et état d'un passage.
 *
 * Ce que ces tests verrouillent : un passage programmé part au jour et à
 * l'heure de Paris, une seule fois par créneau ; un passage incomplet reprend
 * l'heure suivante, sauf arrêt par plafond de dépense ; un verrou expiré se
 * reprend ; un ponctuel n'est marqué terminé que sans aucun reste.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  BACKFILL_LOCK_TTL_MS,
  DEFAULT_BACKFILL_SCHEDULES,
  dueReason,
  effectiveSchedule,
  lockExpired,
  parisSlot,
  parseSchedule,
  passStatus,
  repriseDueAfter,
  sanitizeAppVersion,
  shouldAutoMarkDone,
  type BackfillSchedule,
  type PassSummary,
  type RunStateForDue,
} from "../backfills/schedule";
import { BACKFILLS, backfillDefinition, recurrentKeys } from "../backfills/registry";
import { validateScheduleRequest } from "../callable/backfillAdminCallable";

const IDLE: RunStateForDue = {
  enCours: false,
  enCoursDepuisMs: null,
  repriseDue: false,
  dernierCreneau: null,
};

const SUNDAY_3H: BackfillSchedule = {
  enabled: true,
  days: [7],
  hour: 3,
  programmeParUid: "admin1",
};

// Dimanche 11 octobre 2026 : heure d'été, Paris = UTC+2.
const SUN_0300_PARIS = new Date("2026-10-11T01:00:00Z");
const SUN_0400_PARIS = new Date("2026-10-11T02:00:00Z");
// Dimanche 1er novembre 2026 : heure d'hiver, Paris = UTC+1.
const SUN_0300_PARIS_WINTER = new Date("2026-11-01T02:00:00Z");

describe("heure de Paris", () => {
  test("jour ISO, heure et créneau, heure d'été", () => {
    assert.deepEqual(parisSlot(SUN_0300_PARIS), {
      isoDay: 7,
      hour: 3,
      slot: "2026-10-11T03",
    });
  });
  test("heure d'hiver : le décalage change, pas le créneau lu", () => {
    const p = parisSlot(SUN_0300_PARIS_WINTER);
    assert.equal(p.isoDay, 7);
    assert.equal(p.hour, 3);
  });
  test("minuit à Paris est encore la veille en UTC", () => {
    // Lundi 12 octobre 0 h à Paris = dimanche 22 h UTC.
    const p = parisSlot(new Date("2026-10-11T22:00:00Z"));
    assert.equal(p.isoDay, 1);
    assert.equal(p.hour, 0);
  });
});

describe("échu", () => {
  test("jour et heure programmés : créneau", () => {
    assert.equal(dueReason(SUNDAY_3H, IDLE, SUN_0300_PARIS), "creneau");
  });
  test("autre heure ou autre jour : rien", () => {
    assert.equal(dueReason(SUNDAY_3H, IDLE, SUN_0400_PARIS), null);
    assert.equal(dueReason(SUNDAY_3H, IDLE, new Date("2026-10-12T01:00:00Z")), null);
  });
  test("le même créneau ne part pas deux fois", () => {
    const run = { ...IDLE, dernierCreneau: "2026-10-11T03" };
    assert.equal(dueReason(SUNDAY_3H, run, SUN_0300_PARIS), null);
  });
  test("non programmé ou désactivé : rien", () => {
    assert.equal(dueReason(null, IDLE, SUN_0300_PARIS), null);
    assert.equal(dueReason({ ...SUNDAY_3H, enabled: false }, IDLE, SUN_0300_PARIS), null);
    assert.equal(dueReason({ ...SUNDAY_3H, days: [] }, IDLE, SUN_0300_PARIS), null);
  });
  test("incomplet programmé : reprise à l'heure suivante, même hors des jours programmés", () => {
    const run = { ...IDLE, repriseDue: true, dernierCreneau: "2026-10-11T03" };
    assert.equal(dueReason(SUNDAY_3H, run, SUN_0400_PARIS), "reprise");
    assert.equal(dueReason(SUNDAY_3H, run, new Date("2026-10-12T05:00:00Z")), "reprise");
  });
  test("passage en cours : rien, ni créneau ni reprise", () => {
    const nowMs = SUN_0300_PARIS.getTime();
    const run = { ...IDLE, enCours: true, enCoursDepuisMs: nowMs - 60_000, repriseDue: true };
    assert.equal(dueReason(SUNDAY_3H, run, SUN_0300_PARIS), null);
  });
  test("verrou expiré : le créneau part quand même", () => {
    const nowMs = SUN_0300_PARIS.getTime();
    const run = {
      ...IDLE,
      enCours: true,
      enCoursDepuisMs: nowMs - BACKFILL_LOCK_TTL_MS - 1,
    };
    assert.equal(dueReason(SUNDAY_3H, run, SUN_0300_PARIS), "creneau");
  });
});

describe("verrou", () => {
  test("plus vieux que dix minutes : expiré", () => {
    assert.equal(lockExpired(0, BACKFILL_LOCK_TTL_MS + 1), true);
    assert.equal(lockExpired(0, BACKFILL_LOCK_TTL_MS - 1), false);
  });
  test("sans date de pose : expiré", () => {
    assert.equal(lockExpired(null, 0), true);
  });
});

const COMPLETE: PassSummary = { complete: true, remaining: 0, toReview: 0, spendCapHit: false };
const PARTIAL: PassSummary = { complete: false, remaining: 23, toReview: 0, spendCapHit: false };
const CAPPED: PassSummary = { complete: false, remaining: null, toReview: 0, spendCapHit: true };

describe("après un passage", () => {
  test("statut", () => {
    assert.equal(passStatus(COMPLETE), "termine");
    assert.equal(passStatus(PARTIAL), "incomplet");
  });
  test("programmé incomplet : reprise l'heure suivante", () => {
    assert.equal(repriseDueAfter("programme", PARTIAL, false), true);
  });
  test("arrêt par plafond : pas de reprise avant le prochain créneau", () => {
    assert.equal(repriseDueAfter("programme", CAPPED, true), false);
  });
  test("terminé : plus de reprise, quelle que soit l'origine", () => {
    assert.equal(repriseDueAfter("programme", COMPLETE, true), false);
    assert.equal(repriseDueAfter("manuel", COMPLETE, true), false);
  });
  test("manuel incomplet : la reprise due reste ce qu'elle était", () => {
    assert.equal(repriseDueAfter("manuel", PARTIAL, true), true);
    assert.equal(repriseDueAfter("manuel", PARTIAL, false), false);
  });
});

describe("terminé automatiquement", () => {
  test("ponctuel sans aucun reste : oui", () => {
    assert.equal(shouldAutoMarkDone("ponctuel", COMPLETE), true);
  });
  test("ponctuel avec éléments à revoir, reste ou décompte inconnu : non", () => {
    assert.equal(shouldAutoMarkDone("ponctuel", { ...COMPLETE, toReview: 3 }), false);
    assert.equal(shouldAutoMarkDone("ponctuel", { ...COMPLETE, remaining: 4 }), false);
    assert.equal(shouldAutoMarkDone("ponctuel", { ...COMPLETE, remaining: null }), false);
    assert.equal(shouldAutoMarkDone("ponctuel", PARTIAL), false);
  });
  test("récurrent : jamais", () => {
    assert.equal(shouldAutoMarkDone("recurrent", COMPLETE), false);
  });
});

describe("programmation stockée", () => {
  test("nutrition sans réglage : tous les jours à 5 h", () => {
    assert.deepEqual(
      effectiveSchedule("nutrition", undefined),
      DEFAULT_BACKFILL_SCHEDULES.nutrition,
    );
    assert.deepEqual(effectiveSchedule("nutrition", {})?.days, [1, 2, 3, 4, 5, 6, 7]);
    assert.equal(effectiveSchedule("nutrition", {})?.hour, 5);
  });
  test("nutrition désactivée par un réglage : le défaut ne revient pas", () => {
    const s = effectiveSchedule("nutrition", {
      nutrition: { enabled: false, days: [1], hour: 5 },
    });
    assert.equal(s?.enabled, false);
  });
  test("autres récurrents sans réglage : non programmés", () => {
    assert.equal(effectiveSchedule("recipe_roles", {}), null);
  });
  test("lecture tolérante : jours triés, dédoublonnés, hors plage écartés", () => {
    const s = parseSchedule({
      enabled: true,
      days: [7, 3, 3, 9, "1"],
      hour: 3,
      programme_par_uid: " a1 ",
    });
    assert.deepEqual(s, { enabled: true, days: [1, 3, 7], hour: 3, programmeParUid: "a1" });
  });
  test("mal formée : null", () => {
    assert.equal(parseSchedule({ enabled: true, days: [1], hour: 24 }), null);
    assert.equal(parseSchedule({ enabled: true, hour: 3 }), null);
    assert.equal(parseSchedule("x"), null);
  });
});

describe("registre et validation", () => {
  test("cinq récurrents, quatre ponctuels, clés uniques", () => {
    assert.deepEqual(recurrentKeys(), [
      "nutrition",
      "enrich_referentials",
      "allergens",
      "recipe_roles",
      "shopping_products",
    ]);
    assert.equal(BACKFILLS.filter((b) => b.kind === "ponctuel").length, 4);
    assert.equal(new Set(BACKFILLS.map((b) => b.key)).size, BACKFILLS.length);
    assert.equal(backfillDefinition("inconnu"), null);
  });
  test("programmer un ponctuel est refusé", () => {
    assert.throws(
      () => validateScheduleRequest({ key: "estimated_times", enabled: true, days: [1], hour: 3 }),
      /ponctuel/,
    );
  });
  test("aucun jour coché : refusé si actif, admis si désactivé", () => {
    assert.throws(
      () => validateScheduleRequest({ key: "recipe_roles", enabled: true, days: [], hour: 3 }),
      /au moins un jour/,
    );
    assert.deepEqual(
      validateScheduleRequest({ key: "recipe_roles", enabled: false, days: [], hour: 3 }),
      { key: "recipe_roles", enabled: false, days: [], hour: 3 },
    );
  });
  test("heure hors plage : refusée", () => {
    assert.throws(
      () => validateScheduleRequest({ key: "recipe_roles", enabled: true, days: [1], hour: 24 }),
      /Heure/,
    );
  });
  test("version de l'application : seulement x.y.z", () => {
    assert.equal(sanitizeAppVersion("0.23.43"), "0.23.43");
    assert.equal(sanitizeAppVersion("0.23.43+390"), null);
    assert.equal(sanitizeAppVersion("..."), null);
    assert.equal(sanitizeAppVersion(42), null);
  });
});
