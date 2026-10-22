/**
 * Programmation des backfills récurrents et état d'un passage.
 *
 * Ce que ces tests verrouillent : un passage programmé part au jour et à
 * l'heure de Paris, une seule fois par créneau ; un passage arrêté avant la
 * fin de son parcours reprend l'heure suivante, sauf arrêt par plafond de
 * dépense ; un parcours fini qui laisse des échecs est « incomplet » sans
 * reprise horaire ; un verrou expiré se
 * reprend ; un ponctuel n'est marqué terminé que sans aucun reste.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import {
  BACKFILL_LOCK_TTL_MS,
  DEFAULT_BACKFILL_SCHEDULES,
  dueReason,
  effectiveSchedule,
  PROGRAMMER_NOT_ADMIN_MESSAGE,
  lockExpired,
  missingDefaultSchedules,
  parisSlot,
  parseDays,
  parseHour,
  programmerBlocker,
  parseSchedule,
  passStatus,
  repriseDueAfter,
  sanitizeAppVersion,
  shouldAutoMarkDone,
  type BackfillSchedule,
  type PassSummary,
  type RunStateForDue,
} from "../backfills/schedule";
import { BACKFILLS, backfillDefinition, lockSiblings, recurrentKeys } from "../backfills/registry";
import { validateScheduleRequest } from "../callable/backfillAdminCallable";
import { UNATTRIBUTED, effectiveBudgetMultiplier } from "../ai/budget";
import { runWithBaseBudgetCap } from "../ai/callOrigin";
import { summarizeNutrition } from "../callable/nutritionBackfillCallable";
import { summarizeEnrichReferentials } from "../callable/billingCallable";
import { summarizeAllergens } from "../callable/allergensBackfillCallable";
import { summarizeRecipeRoles } from "../callable/recipeRolesBackfillCallable";

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

const COMPLETE: PassSummary = {
  complete: true,
  remaining: 0,
  toReview: 0,
  spendCapHit: false,
  unresolved: 0,
};
const PARTIAL: PassSummary = {
  complete: false,
  remaining: 23,
  toReview: 0,
  spendCapHit: false,
  unresolved: 0,
};
const CAPPED: PassSummary = {
  complete: false,
  remaining: null,
  toReview: 0,
  spendCapHit: true,
  unresolved: 0,
};
/** Parcours fini, mais des éléments traités restés en échec. */
const FAILED_LEFT: PassSummary = {
  complete: true,
  remaining: 0,
  toReview: 9,
  spendCapHit: false,
  unresolved: 9,
};

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
  test("parcours fini avec des échecs : incomplet, sans reprise à l'heure suivante", () => {
    // Neuf reprises, aucune complétée : « Terminé » était faux. Mais une
    // reprise une heure plus tard reposerait les mêmes questions au modèle,
    // et les facturerait de nouveau.
    assert.equal(passStatus(FAILED_LEFT), "incomplet");
    assert.equal(repriseDueAfter("programme", FAILED_LEFT, false), false);
    assert.equal(repriseDueAfter("programme", FAILED_LEFT, true), false);
    assert.equal(repriseDueAfter("manuel", FAILED_LEFT, true), false);
  });
});

describe("statut rendu par chaque backfill récurrent", () => {
  const review = (total: number) => ({ items: [], total });

  test("nutrition : reprises toujours incomplètes, incomplet sans reprise horaire", () => {
    const summary = summarizeNutrition({
      examinees: 120,
      reprises: 9,
      completees: 0,
      echouees: 9,
      laissees: 0,
      abandonnees: 2,
      nonReprenables: 4,
      collectionParcourue: true,
      stoppedByDeadline: false,
      stoppedByBudget: false,
      completed: true,
      aRevoir: review(15),
    });
    assert.equal(summary.unresolved, 9);
    assert.equal(passStatus(summary), "incomplet");
    assert.equal(repriseDueAfter("programme", summary, false), false);
  });

  test("nutrition : laissées faute de temps, reprise à l'heure suivante", () => {
    const summary = summarizeNutrition({
      examinees: 80,
      reprises: 20,
      completees: 20,
      echouees: 0,
      laissees: 7,
      abandonnees: 0,
      nonReprenables: 0,
      collectionParcourue: true,
      stoppedByDeadline: false,
      stoppedByBudget: false,
      completed: false,
      aRevoir: review(0),
    });
    assert.equal(passStatus(summary), "incomplet");
    assert.equal(repriseDueAfter("programme", summary, false), true);
  });

  test("nutrition : abandonnées et non reprenables seules, terminé et listées", () => {
    // Aucun passage automatique ne les reprendra : elles ne rendent pas le
    // passage incomplet, mais la liste « à revoir » les nomme.
    const summary = summarizeNutrition({
      examinees: 120,
      reprises: 0,
      completees: 0,
      echouees: 0,
      laissees: 0,
      abandonnees: 3,
      nonReprenables: 5,
      collectionParcourue: true,
      stoppedByDeadline: false,
      stoppedByBudget: false,
      completed: true,
      aRevoir: review(8),
    });
    assert.equal(passStatus(summary), "termine");
    assert.equal(summary.toReview, 8);
  });

  test("enrichir : des échecs non exclus rendent le passage incomplet, sans reprise", () => {
    const summary = summarizeEnrichReferentials({
      scannedUnits: 40,
      enrichedUnits: 1,
      scannedIngredients: 300,
      enrichedIngredients: 10,
      failedIngredients: 2,
      remainingUnitsWithoutWeight: 3,
      completed: true,
      stoppedByDeadline: false,
      refreshedIngredients: 0,
      excludedUnits: 1,
      excludedIngredients: 4,
      unresolvedFailures: 2,
      aRevoir: review(7),
    });
    assert.equal(passStatus(summary), "incomplet");
    assert.equal(repriseDueAfter("programme", summary, false), false);
    assert.equal(passStatus({ ...summary, unresolved: 0 }), "termine");
  });

  test("allergènes et rôles : même règle", () => {
    const allergens = summarizeAllergens({
      ingredientsLus: 300,
      ingredientsExamines: 38,
      ingredientsIgnores: 250,
      ingredientsEnErreur: 2,
      ingredientsExclus: 3,
      echecsNonExclus: 2,
      referentielParcouru: true,
      recettesExaminees: 10,
      recettesCalculees: 1,
      recettesIdentiques: 9,
      recettesIncompletes: 0,
      recettesHorsRecette: 0,
      recettesEchouees: 0,
      recettesParcourues: true,
      stoppedByDeadline: false,
      stoppedByBudget: false,
      stoppedByErrors: false,
      completed: true,
      aRevoir: review(5),
    });
    assert.equal(passStatus(allergens), "incomplet");
    assert.equal(repriseDueAfter("programme", allergens, false), false);

    const roles = summarizeRecipeRoles({
      examinees: 50,
      classees: 3,
      dejaClassees: 40,
      horsRecette: 2,
      sansRole: 1,
      echouees: 0,
      exclues: 4,
      echecsNonExclus: 0,
      restantes: 5,
      collectionParcourue: true,
      stoppedByDeadline: false,
      stoppedByBudget: false,
      stoppedByErrors: false,
      completed: true,
      aRevoir: review(5),
    });
    // La seule recette sans rôle vient d'atteindre trois échecs : exclue,
    // elle ne rend pas le passage incomplet.
    assert.equal(passStatus(roles), "termine");
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
    assert.equal(shouldAutoMarkDone("ponctuel", { ...FAILED_LEFT, toReview: 0 }), false);
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
  test("défaut à semer : seulement s'il manque, jamais par-dessus un réglage", () => {
    assert.deepEqual(Object.keys(missingDefaultSchedules(undefined)), ["nutrition"]);
    assert.deepEqual(Object.keys(missingDefaultSchedules({ recipe_roles: {} })), ["nutrition"]);
    assert.deepEqual(missingDefaultSchedules({ nutrition: { enabled: false } }), {});
    assert.deepEqual(missingDefaultSchedules({ nutrition: "illisible" }), {});
  });
  test("lecture stricte des jours et de l'heure", () => {
    for (const bad of [null, "", "5", true, 5.5, -1, 24, undefined]) {
      assert.equal(parseHour(bad), null, `heure ${JSON.stringify(bad)}`);
    }
    assert.equal(parseHour(0), 0);
    for (const bad of [null, "1", ["1"], [true], [1.5], [0], [8], [null]]) {
      assert.equal(parseDays(bad), null, `jours ${JSON.stringify(bad)}`);
    }
    assert.deepEqual(parseDays([]), []);
    assert.deepEqual(parseDays([5, 1, 5]), [1, 5]);
  });
});

// ── Fixture partagée avec le client ─────────────────────────────────────────

interface ScheduleFixture {
  registry: {
    key: string;
    kind: string;
    uses_ai: boolean;
    default_schedule: { days: number[]; hour: number } | null;
  }[];
  parse_schedule: {
    name: string;
    input: unknown;
    expected: {
      enabled: boolean;
      days: number[];
      hour: number;
      programme_par_uid: string | null;
    } | null;
  }[];
}

const FIXTURE = JSON.parse(
  readFileSync(
    path.join(__dirname, "..", "..", "..", "test-fixtures", "backfill_schedule.json"),
    "utf8",
  ),
) as ScheduleFixture;

describe("fixture backfill_schedule.json", () => {
  test("registre : mêmes clés, même ordre, même nature, même usage de l'IA", () => {
    assert.deepEqual(
      BACKFILLS.map((b) => ({
        key: b.key,
        kind: b.kind,
        uses_ai: b.usesAi,
        default_schedule:
          b.defaultSchedule == null
            ? null
            : { days: [...b.defaultSchedule.days], hour: b.defaultSchedule.hour },
      })),
      FIXTURE.registry,
    );
  });
  for (const c of FIXTURE.parse_schedule) {
    test(`lecture d'une programmation : ${c.name}`, () => {
      const parsed = parseSchedule(c.input);
      assert.deepEqual(
        parsed == null
          ? null
          : {
              enabled: parsed.enabled,
              days: parsed.days,
              hour: parsed.hour,
              programme_par_uid: parsed.programmeParUid,
            },
        c.expected,
      );
    });
  }
});

describe("auteur de la programmation", () => {
  test("encore administrateur : le passage part", () => {
    assert.equal(programmerBlocker("a1", true), null);
  });
  test("plus administrateur : pas de passage, message enregistré", () => {
    assert.equal(programmerBlocker("a1", false), PROGRAMMER_NOT_ADMIN_MESSAGE);
    assert.equal(
      PROGRAMMER_NOT_ADMIN_MESSAGE,
      "L'auteur de la programmation n'est plus administrateur.",
    );
  });
  test("sans auteur (défaut de la nutrition) : rien à vérifier", () => {
    assert.equal(programmerBlocker(null, false), null);
  });
});

describe("verrou commun", () => {
  test("l'enrichissement bloque le sel ; les autres ne bloquent personne", () => {
    assert.deepEqual(lockSiblings("enrich_referentials"), ["refresh_sodium"]);
    assert.deepEqual(lockSiblings("refresh_sodium"), ["enrich_referentials"]);
    assert.deepEqual(lockSiblings("recipe_roles"), []);
  });
});

describe("registre et validation", () => {
  test("cinq récurrents, un ponctuel, clés uniques", () => {
    assert.deepEqual(recurrentKeys(), [
      "nutrition",
      "enrich_referentials",
      "allergens",
      "recipe_roles",
      "shopping_products",
    ]);
    assert.equal(BACKFILLS.filter((b) => b.kind === "ponctuel").length, 1);
    assert.equal(new Set(BACKFILLS.map((b) => b.key)).size, BACKFILLS.length);
    assert.equal(backfillDefinition("inconnu"), null);
    // Ponctuels retirés en v0.23.52, v0.24.33, v0.24.37, v0.24.44 et v0.24.52 : leur clé n'est plus connue.
    for (const retired of [
      "recipe_protein",
      "estimated_times",
      "planning_defaults",
      "system_books",
      "group_planning_reach",
      "ticket_analyses",
      "ticket_delivered_pr",
      "recipe_title_keys",
      "invitation_group_owner",
      "illustration_folders",
      "illustration_folders_move",
      "move_meals_to_group",
      "default_units",
      "users_schema_check",
    ]) {
      assert.equal(backfillDefinition(retired), null);
    }
  });
  test("programmer un ponctuel est refusé", () => {
    assert.throws(
      () => validateScheduleRequest({ key: "refresh_sodium", enabled: true, days: [1], hour: 3 }),
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

describe("plafond de base d'un passage programmé", () => {
  test("le multiplicateur du compte ne s'applique pas dans runWithBaseBudgetCap", async () => {
    assert.equal(await effectiveBudgetMultiplier(UNATTRIBUTED), 100);
    assert.equal(await runWithBaseBudgetCap(() => effectiveBudgetMultiplier(UNATTRIBUTED)), 1);
  });
});
