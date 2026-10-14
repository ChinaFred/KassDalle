/**
 * Déplacer mes repas vers un groupe : validation de l'entrée, sélection des
 * repas personnels de la période, propriétaire requis, réentrance et liste à
 * revoir. Firestore est remplacé par un faux magasin en mémoire.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  MAX_PERIOD_DAYS,
  isPersonalMeal,
  isoDayToUtcMs,
  mealReviewLabel,
  movableMeal,
  parseMoveMealsRequest,
  runMoveMealsToGroupPass,
  summarizeMoveMealsToGroup,
  type MealRow,
  type MoveOutcome,
  type MoveMealsRequest,
  type MoveMealsStore,
} from "../callable/moveMealsToGroupBackfillCallable";
import { Timestamp } from "firebase-admin/firestore";

import { shouldAutoMarkDone } from "../backfills/schedule";

const H = 3_600_000;
const D = 24 * H;

/** Jours et bornes d'un appareil à UTC+2 : minuit local = 22 h UTC la veille. */
function request(over: Partial<Record<string, unknown>> = {}): Record<string, unknown> {
  return {
    groupId: "grpA",
    fromDay: "2030-03-01",
    toDay: "2030-03-07",
    startAt: Date.UTC(2030, 2, 1) - 2 * H,
    endAt: Date.UTC(2030, 2, 8) - 2 * H,
    ...over,
  };
}

function parsed(over: Partial<Record<string, unknown>> = {}): MoveMealsRequest {
  const r = parseMoveMealsRequest(request(over));
  if ("error" in r) throw new Error(r.error);
  return r.request;
}

describe("entrée", () => {
  test("valide : jours inclusifs et bornes de l'appareil", () => {
    const r = parsed();
    assert.equal(r.groupId, "grpA");
    assert.equal(r.fromDay, "2030-03-01");
    assert.equal(r.toDay, "2030-03-07");
  });
  test("un seul jour", () => {
    assert.ok(
      "request" in
        parseMoveMealsRequest(
          request({
            toDay: "2030-03-01",
            endAt: Date.UTC(2030, 2, 2) - 2 * H,
          }),
        ),
    );
  });
  test("identifiant de groupe : format sûr exigé", () => {
    for (const groupId of ["", "a/b", "../x", "a b", 42, null, "x".repeat(129)]) {
      const r = parseMoveMealsRequest(request({ groupId }));
      assert.ok("error" in r, `groupId ${JSON.stringify(groupId)}`);
    }
  });
  test("jours mal formés ou impossibles", () => {
    for (const fromDay of ["2030-3-1", "01/03/2030", "2030-02-30", "", null, 20300301]) {
      assert.ok("error" in parseMoveMealsRequest(request({ fromDay })), String(fromDay));
    }
  });
  test("début après la fin : refusé", () => {
    const r = parseMoveMealsRequest(
      request({
        fromDay: "2030-03-08",
        startAt: Date.UTC(2030, 2, 8) - 2 * H,
      }),
    );
    assert.deepEqual(r, { error: "Le jour de début est après le jour de fin." });
  });
  test(`période de ${MAX_PERIOD_DAYS} jours acceptée, un de plus refusé`, () => {
    const from = Date.UTC(2030, 0, 1);
    const ok = parseMoveMealsRequest({
      groupId: "g",
      fromDay: "2030-01-01",
      toDay: new Date(from + (MAX_PERIOD_DAYS - 1) * D).toISOString().slice(0, 10),
      startAt: from,
      endAt: from + MAX_PERIOD_DAYS * D,
    });
    assert.ok("request" in ok);
    const ko = parseMoveMealsRequest({
      groupId: "g",
      fromDay: "2030-01-01",
      toDay: new Date(from + MAX_PERIOD_DAYS * D).toISOString().slice(0, 10),
      startAt: from,
      endAt: from + (MAX_PERIOD_DAYS + 1) * D,
    });
    assert.ok("error" in ko);
  });
  test("bornes absentes, non entières ou inversées : refusées", () => {
    for (const over of [
      { startAt: undefined },
      { endAt: "123" },
      { startAt: 1.5 },
      { startAt: Date.UTC(2030, 2, 8), endAt: Date.UTC(2030, 2, 1) },
    ]) {
      assert.ok("error" in parseMoveMealsRequest(request(over)), JSON.stringify(over));
    }
  });
  test("bornes éloignées des jours de plus de quatorze heures : refusées", () => {
    const r = parseMoveMealsRequest(request({ startAt: Date.UTC(2030, 2, 1) - 15 * H }));
    assert.deepEqual(r, {
      error: "Les bornes de la période ne correspondent pas aux jours choisis.",
    });
    // UTC+14 et UTC−12 restent acceptés.
    assert.ok(
      "request" in parseMoveMealsRequest(request({ startAt: Date.UTC(2030, 2, 1) - 14 * H })),
    );
    assert.ok(
      "request" in parseMoveMealsRequest(request({ endAt: Date.UTC(2030, 2, 8) + 12 * H })),
    );
  });
  test("lecture d'un jour", () => {
    assert.equal(isoDayToUtcMs("2030-03-01"), Date.UTC(2030, 2, 1));
    assert.equal(isoDayToUtcMs("2030-13-01"), null);
    assert.equal(isoDayToUtcMs(undefined), null);
  });
});

describe("repas personnel", () => {
  test("group_id nul ou absent : personnel", () => {
    assert.equal(isPersonalMeal({ group_id: null }), true);
    assert.equal(isPersonalMeal({ uid: "u" }), true);
  });
  test("group_id posé : déjà dans un groupe", () => {
    assert.equal(isPersonalMeal({ group_id: "g" }), false);
    assert.equal(isPersonalMeal({ group_id: "" }), false);
    assert.equal(isPersonalMeal(undefined), false);
  });
});

// ── Passage, avec un faux magasin ───────────────────────────────────────────

interface FakeMeal {
  uid: string;
  group_id?: string | null;
  planned_at: number;
  recipe_titre?: string;
}

class FakeStore implements MoveMealsStore {
  readonly writes: { id: string; groupId: string }[] = [];
  readonly failing = new Set<string>();

  constructor(
    readonly groups: Record<string, Record<string, unknown>>,
    readonly meals: Record<string, FakeMeal>,
  ) {}

  async readGroup(groupId: string) {
    return this.groups[groupId] ?? null;
  }

  async listMeals(uid: string, startAt: number, endAt: number, limit: number): Promise<MealRow[]> {
    return Object.entries(this.meals)
      .filter(([, m]) => m.uid === uid && m.planned_at >= startAt && m.planned_at < endAt)
      .sort(([, a], [, b]) => a.planned_at - b.planned_at)
      .slice(0, limit)
      .map(([id, m]) => {
        const { planned_at: _at, ...data } = m;
        return { id, data: data as Record<string, unknown> };
      });
  }

  /** Rappelé après chaque écriture, pour simuler un changement concurrent. */
  afterMove: ((id: string) => void) | null = null;

  /** Rejoue la transaction : relit le groupe et le repas, puis écrit. */
  async moveMeal(id: string, groupId: string, ownerUid: string): Promise<MoveOutcome> {
    if (this.failing.has(id)) throw new Error("ABORTED");
    const group = await this.readGroup(groupId);
    if (!group || group.owner_id !== ownerUid) return "group_gone";
    const meal = this.meals[id];
    if (!movableMeal(meal as unknown as Record<string, unknown> | undefined, ownerUid)) {
      return "not_personal";
    }
    meal.group_id = groupId;
    this.writes.push({ id, groupId });
    this.afterMove?.(id);
    return "moved";
  }
}

const silent = {
  error: async () => undefined,
  info: async () => undefined,
};
const ctx = { userId: "owner", correlationId: "c1" };
const at = (day: number, hour = 12) => Date.UTC(2030, 2, day, hour) - 2 * H;

function store(): FakeStore {
  return new FakeStore(
    {
      grpA: { owner_id: "owner", name: "Groupe A", member_ids: ["owner", "m1"] },
      grpB: { owner_id: "someoneElse", name: "Groupe B" },
    },
    {
      // Dans la période, personnels : avec null explicite, et sans le champ.
      p1: { uid: "owner", group_id: null, planned_at: at(1, 0), recipe_titre: "Soupe" },
      p2: { uid: "owner", planned_at: at(7, 23) },
      // Dans la période, déjà dans un groupe : ignoré.
      g1: { uid: "owner", group_id: "grpOther", planned_at: at(3) },
      // Hors période (veille et lendemain, heure locale) : non lus.
      before: { uid: "owner", group_id: null, planned_at: at(1, 0) - 1 },
      after: { uid: "owner", group_id: null, planned_at: at(8, 0) },
      // Un autre cuisinier : jamais touché.
      other: { uid: "m1", group_id: null, planned_at: at(2) },
    },
  );
}

describe("passage", () => {
  test("déplace les repas personnels de la période, et eux seuls", async () => {
    const s = store();
    const r = await runMoveMealsToGroupPass(ctx, parsed(), s, {
      deadlineMs: Number.MAX_SAFE_INTEGER,
      logger: silent,
    });
    assert.deepEqual(
      s.writes.map((w) => w.id),
      ["p1", "p2"],
    );
    assert.ok(s.writes.every((w) => w.groupId === "grpA"));
    assert.equal(s.meals.before.group_id, null);
    assert.equal(s.meals.after.group_id, null);
    assert.equal(s.meals.other.group_id, null);
    assert.equal(s.meals.g1.group_id, "grpOther");
    assert.equal(r.groupId, "grpA");
    assert.equal(r.groupeIndisponible, false);
    assert.equal(
      JSON.stringify(r).includes("Groupe A"),
      false,
      "le nom du groupe ne part pas dans le compte rendu",
    );
    assert.equal(r.examines, 3);
    assert.equal(r.deplaces, 2);
    assert.equal(r.ignores, 1);
    assert.equal(r.echoues, 0);
    assert.equal(r.restants, 0);
    assert.equal(r.completed, true);
  });

  test("réentrant : un second passage ne déplace rien", async () => {
    const s = store();
    await runMoveMealsToGroupPass(ctx, parsed(), s, {
      deadlineMs: Number.MAX_SAFE_INTEGER,
      logger: silent,
    });
    const again = await runMoveMealsToGroupPass(ctx, parsed(), s, {
      deadlineMs: Number.MAX_SAFE_INTEGER,
      logger: silent,
    });
    assert.equal(s.writes.length, 2);
    assert.equal(again.deplaces, 0);
    assert.equal(again.ignores, 3);
    assert.equal(again.completed, true);
  });

  test("groupe d'un autre propriétaire : refusé, rien n'est écrit", async () => {
    const s = store();
    await assert.rejects(
      runMoveMealsToGroupPass(ctx, parsed({ groupId: "grpB" }), s, {
        deadlineMs: Number.MAX_SAFE_INTEGER,
        logger: silent,
      }),
      (e: { code?: string }) => e.code === "permission-denied",
    );
    assert.equal(s.writes.length, 0);
  });

  test("groupe introuvable : refusé", async () => {
    await assert.rejects(
      runMoveMealsToGroupPass(ctx, parsed({ groupId: "nope" }), store(), {
        deadlineMs: Number.MAX_SAFE_INTEGER,
        logger: silent,
      }),
      (e: { code?: string }) => e.code === "not-found",
    );
  });

  test("échec d'un repas : nommé à revoir, journalisé, les autres continuent", async () => {
    const s = store();
    s.failing.add("p1");
    const errors: unknown[] = [];
    const r = await runMoveMealsToGroupPass(ctx, parsed(), s, {
      deadlineMs: Number.MAX_SAFE_INTEGER,
      logger: {
        error: async (e) => {
          errors.push(e);
        },
        info: async () => undefined,
      },
    });
    assert.equal(r.deplaces, 1);
    assert.equal(r.echoues, 1);
    assert.equal(r.completed, false);
    assert.equal(r.aRevoir.total, 1);
    assert.equal(r.aRevoir.items[0].id, "p1");
    assert.equal(r.aRevoir.items[0].kind, "meal");
    assert.equal(r.aRevoir.items[0].label, "Repas p1");
    assert.equal(JSON.stringify(r).includes("Soupe"), false, "pas de titre de recette");
    assert.equal(errors.length, 1);
  });

  test("borné : arrêt au quota, reste compté", async () => {
    const s = store();
    const r = await runMoveMealsToGroupPass(ctx, parsed(), s, {
      deadlineMs: Number.MAX_SAFE_INTEGER,
      logger: silent,
      maxMoves: 1,
    });
    assert.equal(r.deplaces, 1);
    assert.equal(r.restants, 1);
    assert.equal(r.stoppedByBudget, true);
    assert.equal(r.completed, false);
  });

  test("lecture tronquée : jamais complet", async () => {
    const r = await runMoveMealsToGroupPass(ctx, parsed(), store(), {
      deadlineMs: Number.MAX_SAFE_INTEGER,
      logger: silent,
      maxReads: 2,
    });
    assert.equal(r.lectureTronquee, true);
    assert.equal(r.completed, false);
  });

  test("jamais marqué terminé tout seul : le reste est inconnu", async () => {
    const r = await runMoveMealsToGroupPass(ctx, parsed(), store(), {
      deadlineMs: Number.MAX_SAFE_INTEGER,
      logger: silent,
    });
    const summary = summarizeMoveMealsToGroup(r);
    assert.equal(summary.complete, true);
    assert.equal(summary.remaining, null);
    assert.equal(shouldAutoMarkDone("ponctuel", summary), false);
  });

  test("groupe supprimé après le premier déplacement : arrêt, plus aucune écriture", async () => {
    const s = store();
    s.afterMove = () => {
      delete s.groups.grpA;
    };
    const errors: unknown[] = [];
    const r = await runMoveMealsToGroupPass(ctx, parsed(), s, {
      deadlineMs: Number.MAX_SAFE_INTEGER,
      logger: {
        error: async (e) => {
          errors.push(e);
        },
        info: async () => undefined,
      },
    });
    assert.deepEqual(
      s.writes.map((w) => w.id),
      ["p1"],
    );
    assert.equal(s.meals.p2.group_id, undefined, "p2 reste personnel");
    assert.equal(r.groupeIndisponible, true);
    assert.equal(r.deplaces, 1);
    assert.equal(r.restants, 1);
    assert.equal(r.completed, false);
    assert.equal(errors.length, 1);
  });

  test("groupe cédé à un autre propriétaire pendant le passage : arrêt", async () => {
    const s = store();
    s.afterMove = () => {
      s.groups.grpA.owner_id = "someoneElse";
    };
    const r = await runMoveMealsToGroupPass(ctx, parsed(), s, {
      deadlineMs: Number.MAX_SAFE_INTEGER,
      logger: silent,
    });
    assert.equal(r.deplaces, 1);
    assert.equal(r.groupeIndisponible, true);
  });

  test("repas passé dans un groupe entre la lecture et l'écriture : ignoré", async () => {
    const s = store();
    s.afterMove = (id) => {
      if (id === "p1") s.meals.p2.group_id = "grpOther";
    };
    const r = await runMoveMealsToGroupPass(ctx, parsed(), s, {
      deadlineMs: Number.MAX_SAFE_INTEGER,
      logger: silent,
    });
    assert.equal(r.deplaces, 1);
    assert.equal(r.ignores, 2);
    assert.equal(s.meals.p2.group_id, "grpOther");
    assert.equal(r.completed, true);
  });
});

describe("transaction et liste à revoir", () => {
  test("repas déplaçable : présent, du cuisinier, personnel", () => {
    assert.equal(movableMeal({ uid: "u", group_id: null }, "u"), true);
    assert.equal(movableMeal({ uid: "u" }, "u"), true);
    assert.equal(movableMeal({ uid: "v", group_id: null }, "u"), false);
    assert.equal(movableMeal({ uid: "u", group_id: "g" }, "u"), false);
    assert.equal(movableMeal(undefined, "u"), false);
  });
  test("libellé : identifiant et jour, jamais le titre", () => {
    const label = mealReviewLabel({
      id: "m1",
      data: { recipe_titre: "Soupe", planned_at: Timestamp.fromMillis(Date.UTC(2030, 2, 1, 12)) },
    });
    assert.equal(label, "Repas m1 — 2030-03-01");
  });
});
