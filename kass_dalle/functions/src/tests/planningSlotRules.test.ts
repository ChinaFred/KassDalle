/**
 * Règles de créneau du planning — serveur seul.
 *
 * Le serveur les applique pour composer le prompt et lire la réponse du
 * modèle : le format d'un créneau (entrée ? dessert ? repas léger ?), le rôle
 * sous lequel une recette est proposée, la nature du créneau, le jour de
 * préparation, la fenêtre de variété.
 *
 * Un écart ne casse aucun écran et ne lève aucune erreur : il laisse passer un
 * dessert en plat, ou décale d'une semaine un jour de préparation. Les cas
 * viennent donc de la fixture `planning_slot_rules.json`.
 *
 * Logique pure : ni Firestore, ni réseau, ni appel de modèle.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import {
  isDessertBag,
  slotKind,
  computePrepDate,
  applyRecentlyServed,
  mealFormatOf,
  planningRoleOf,
  partitionByRole,
  CONCEPT_RUN_TTL_MS,
  FRESHNESS_FLOOR,
  HISTORY_DAYS,
  MIN_DISTINCT_PROTEINS,
  PROTEIN_REPEAT_FACTOR,
  RATING_EXCLUDE_MAX,
  RATING_HIGH_FACTOR,
  RATING_HIGH_MIN,
  RATING_LOW_FACTOR,
  RATING_LOW_MAX,
  REFUSAL_FACTOR,
  REFUSAL_FUTURE_TOLERANCE_DAYS,
  REFUSAL_MAX_ENTRIES,
  REFUSAL_PENALTY_DAYS,
  REFUSAL_REPEAT_FACTOR,
  REFUSAL_REPEAT_THRESHOLD,
  REHEAT_BONUS,
  REST_EVE_MINUTES,
  STARCH_REPEAT_FACTOR,
  buildPlanningPrompt,
  candidateWeight,
  codeJustification,
  freshnessScore,
  hardFilterReason,
  isReheatFriendly,
  needsModel,
  planningConceptDecision,
  conceptsAllowance,
  preselect,
  proteinOf,
  ratingFactor,
  readPlanningPolicy,
  readRefusals,
  refusalFactor,
  resizeOf,
  seededRng,
  slotContexts,
  spreadProteins,
  starchOf,
  isStarchRepeat,
  validateModelChoices,
  weightedOrder,
  DEFAULT_PLANNING_POLICY,
  type DayConstraint,
  type PlanningInput,
  type PlanningRecipeSummary,
  type CandidateRole,
  type ProteinKey,
  type RankedCandidate,
  type RefusalEntry,
  type SlotRanking,
} from "../gemini/planning";

const FIXTURE = path.join(__dirname, "..", "..", "..", "test-fixtures", "planning_slot_rules.json");

interface Fixture {
  meal_format: Array<{
    key: string | null;
    expected: { wantsStarter: boolean; wantsDessert: boolean; light: boolean };
    why: string;
  }>;
  planning_role: Array<{
    meal_role: string | null;
    attributes: string[];
    expected: string;
    why: string;
  }>;
  is_dessert: Array<{ attributes: string[]; expected: boolean; why: string }>;
  slot_kind: Array<{
    slot_weekday: number;
    is_reheat_constraint: boolean;
    batch_cooking_day: number | null;
    expected: string;
    why: string;
  }>;
  prep_date: Array<{
    slot_date: string;
    batch_weekday: number;
    expected: string;
    why: string;
  }>;
  recently_served: Array<{
    corpus: string[];
    served: Array<{ recipe_id: string; date: string }>;
    slots_to_fill: number;
    expected_candidates: string[];
    expected_excluded: string[];
    expected_kept: string[];
    why: string;
  }>;
}

/** Recette telle que la fixture l'écrit (snake_case). */
interface FxRecipe {
  id: string;
  titre?: string;
  prep?: number;
  rest?: number;
  dish_types?: string[];
  themes?: string[];
  meal_role?: string;
  main_protein?: string;
  main_starch?: string;
  portions?: number | null;
  rating?: number;
}

/** Créneau tel que la fixture l'écrit. */
interface FxSlot {
  date: string;
  max_prep?: number;
  format?: string;
  target?: number;
  dismissed?: string[];
}

interface FxRanking {
  slot: number;
  plats?: string[];
  entrees?: string[];
  desserts?: string[];
}

interface PreselectionFixture {
  constants: Record<string, number>;
  protein_of: Array<{
    dish_types: string[];
    main_protein?: string;
    expected: ProteinKey;
    why: string;
  }>;
  starch_of: Array<{ main_starch: string | null; expected: string | null; why: string }>;
  starch_repeat: Array<{
    candidate: string | null;
    neighbours: string[];
    expected: boolean;
    why: string;
  }>;
  reheat_friendly: Array<{
    dish_types: string[];
    themes: string[];
    expected: boolean;
    why: string;
  }>;
  hard_filter: Array<{
    recipe: FxRecipe;
    slot: FxSlot;
    role: CandidateRole;
    today: string;
    rating?: number;
    in_cycle?: string[];
    expected: string | null;
    why: string;
  }>;
  freshness: Array<{ days: number | null; expected: number; why: string }>;
  rating_factor: Array<{ rating: number | null; expected: number; why: string }>;
  refusal_factor: Array<{
    age_days: number | null;
    count: number | null;
    expected: number;
    why: string;
  }>;
  weight: Array<{
    days: number | null;
    reheat_slot: boolean;
    reheat_friendly: boolean;
    protein_repeats: number;
    rating?: number;
    refusal_factor?: number;
    starch_repeat?: boolean;
    expected: number;
    why: string;
  }>;
  weighted_order: Array<{
    seed: number;
    weights: Record<string, number>;
    expected_last?: string;
    expected_order?: string[];
    why: string;
  }>;
  spread_proteins: Array<{
    ordered: Array<[string, ProteinKey]>;
    k: number;
    min_distinct: number;
    expected: string[];
    why: string;
  }>;
  preselect: Array<{
    slots: FxSlot[];
    recipes: FxRecipe[];
    already_assigned?: Array<{ slot: number; recipe_id: string }>;
    served?: Array<{ recipe_id: string; date: string }>;
    ratings?: Record<string, number>;
    refusals?: Record<string, { age_days: number; count: number }>;
    policy: Record<string, unknown>;
    seed: number;
    today: string;
    expected: {
      heads_disjoint?: boolean;
      head_sizes?: number[];
      slots?: Array<{
        slot: number;
        plats: string[];
        entrees?: string[];
        desserts?: string[];
        repeat: string[];
        relaxed: string[];
        refused?: string[];
      }>;
    };
    why: string;
  }>;
  validate_choice: Array<{
    slots: FxSlot[];
    rankings: FxRanking[];
    raw: unknown;
    expected: Array<Record<string, unknown>>;
    rejected: number;
    why: string;
  }>;
  code_justification: Array<{
    recipe: FxRecipe;
    slot: FxSlot;
    last_served: string | null;
    history: boolean;
    rating?: number;
    repeat?: boolean;
    refused?: boolean;
    expected: string;
    why: string;
  }>;
  resize: Array<{
    portions: number | null;
    target: number | null;
    expected: { resized: boolean; reason?: string };
    why: string;
  }>;
  policy: Array<{
    raw: Record<string, unknown> | null;
    expected: Record<string, number>;
    why: string;
  }>;
  concept_decision: Array<{
    run: {
      created_at_ms: number;
      concepts_max: number;
      concepts_used: number;
      cost_usd: number;
      reserved_usd?: number;
      cost_cap_usd: number | null;
    } | null;
    now_ms: number;
    estimate_usd: number | null;
    expected: string | null;
    why: string;
  }>;
  concepts_allowance: Array<{
    policy_max: number;
    slots: number;
    filled: number;
    expected: number;
    why: string;
  }>;
}

const fixture = JSON.parse(readFileSync(FIXTURE, "utf8")) as Fixture & PreselectionFixture;

describe("format d'un créneau", () => {
  test("la fixture partagée est non vide", () => {
    assert.ok(fixture.meal_format.length > 0);
  });

  for (const c of fixture.meal_format) {
    test(`${c.key === null ? "(absent)" : `« ${c.key} »`} (${c.why})`, () => {
      const spec = mealFormatOf(c.key);
      assert.deepEqual(
        { wantsStarter: spec.wantsStarter, wantsDessert: spec.wantsDessert, light: spec.light },
        c.expected,
      );
    });
  }
});

/** Une recette de la fixture : le titre d'abord, les types de plat ensuite. */
function recipeOf(c: { meal_role: string | null; attributes: string[] }): PlanningRecipeSummary {
  return {
    id: "x",
    titre: c.attributes[0] ?? "",
    dishTypes: c.attributes.slice(1),
    mealRole: c.meal_role,
  };
}

describe("rôle sous lequel une recette est proposée", () => {
  test("la fixture partagée est non vide", () => {
    assert.ok(fixture.planning_role.length > 0);
  });

  for (const c of fixture.planning_role) {
    test(`${c.meal_role ?? "(sans rôle)"} · ${c.attributes.join(" · ")} (${c.why})`, () => {
      assert.equal(planningRoleOf(recipeOf(c)), c.expected);
    });
  }

  test("les listes du prompt : plats, entrées, desserts, en-cas — jamais un accompagnement", () => {
    const out = partitionByRole(
      fixture.planning_role.map((c, i) => ({ ...recipeOf(c), id: `r${i}` })),
    );
    const roles = (list: PlanningRecipeSummary[]) => list.map((r) => planningRoleOf(r));
    assert.ok(roles(out.plats).every((r) => r === "plat"));
    assert.ok(roles(out.entrees).every((r) => r === "entree"));
    assert.ok(roles(out.desserts).every((r) => r === "dessert"));
    assert.ok(roles(out.encas).every((r) => r === "snack"));
    const listed = out.plats.length + out.entrees.length + out.desserts.length + out.encas.length;
    const accompagnements = fixture.planning_role.filter(
      (c) => c.expected === "accompagnement",
    ).length;
    assert.equal(listed, fixture.planning_role.length - accompagnements);
  });
});

describe("recette sucrée", () => {
  test("la fixture partagée est non vide", () => {
    assert.ok(fixture.is_dessert.length > 0);
  });

  for (const c of fixture.is_dessert) {
    test(`${c.attributes.join(" · ")} (${c.why})`, () => {
      assert.equal(isDessertBag(c.attributes), c.expected);
    });
  }
});

describe("nature du créneau", () => {
  test("la fixture partagée est non vide", () => {
    assert.ok(fixture.slot_kind.length > 0);
  });

  for (const c of fixture.slot_kind) {
    test(`jour ${c.slot_weekday} (${c.why})`, () => {
      assert.equal(
        slotKind(c.slot_weekday, c.is_reheat_constraint, c.batch_cooking_day),
        c.expected,
      );
    });
  }
});

describe("jour de préparation à l'avance", () => {
  test("la fixture partagée est non vide", () => {
    assert.ok(fixture.prep_date.length > 0);
  });

  for (const c of fixture.prep_date) {
    test(`${c.slot_date} depuis le jour ${c.batch_weekday} (${c.why})`, () => {
      assert.equal(computePrepDate(c.slot_date, c.batch_weekday), c.expected);
    });
  }
});

describe("fenêtre de variété : recettes servies avant le cycle", () => {
  test("la fixture partagée est non vide", () => {
    assert.ok(fixture.recently_served.length > 0);
  });

  for (const c of fixture.recently_served) {
    test(`${c.corpus.join(",")} moins ${c.served.map((s) => s.recipe_id).join(",")} (${c.why})`, () => {
      const corpus: PlanningRecipeSummary[] = c.corpus.map((id) => ({
        id,
        titre: `Recette ${id}`,
      }));
      const served = c.served.map((s) => ({ recipeId: s.recipe_id, date: s.date }));
      const out = applyRecentlyServed(corpus, served, c.slots_to_fill);
      assert.deepEqual(
        out.candidates.map((r) => r.id),
        c.expected_candidates,
      );
      assert.deepEqual(out.excludedIds, c.expected_excluded);
      assert.deepEqual(out.keptRecentIds, c.expected_kept);
    });
  }

  test("le corpus d'origine n'est pas modifié", () => {
    const corpus: PlanningRecipeSummary[] = [
      { id: "a", titre: "A" },
      { id: "b", titre: "B" },
    ];
    applyRecentlyServed(corpus, [{ recipeId: "a", date: "2026-09-01" }], 1);
    assert.deepEqual(
      corpus.map((r) => r.id),
      ["a", "b"],
    );
  });
});

// ── Présélection ─────────────────────────────────────────────────────────────

/** Recette de la fixture (snake_case) → résumé du planning. */
function summaryOf(r: FxRecipe): PlanningRecipeSummary {
  return {
    id: r.id,
    titre: r.titre ?? `Recette ${r.id}`,
    ...(r.prep != null ? { prepTime: r.prep } : {}),
    ...(r.rest != null ? { restTime: r.rest } : {}),
    ...(r.dish_types ? { dishTypes: r.dish_types } : {}),
    ...(r.themes ? { themes: r.themes } : {}),
    ...(r.meal_role ? { mealRole: r.meal_role } : {}),
    ...(r.main_protein ? { mainProtein: r.main_protein } : {}),
    ...(r.main_starch ? { mainStarch: r.main_starch } : {}),
    ...(r.portions != null ? { portions: r.portions } : {}),
  };
}

/** Créneaux de la fixture → entrée de planning. */
function inputOf(
  slots: FxSlot[],
  recipes: PlanningRecipeSummary[],
  extra: {
    already_assigned?: Array<{ slot: number; recipe_id: string }>;
    served?: Array<{ recipe_id: string; date: string }>;
  } = {},
): PlanningInput {
  const slotConstraints: Array<DayConstraint | null> = slots.map((s) =>
    s.max_prep != null || s.format != null || s.target != null
      ? {
          ...(s.max_prep != null ? { maxPrepMinutes: s.max_prep } : {}),
          ...(s.format != null ? { mealFormat: s.format } : {}),
          ...(s.target != null ? { targetPortions: s.target } : {}),
        }
      : null,
  );
  return {
    recipes,
    slotDates: slots.map((s) => s.date),
    dailyConstraints: {},
    slotConstraints,
    globalConstraints: "",
    slotDismissed: slots.map((s) => s.dismissed ?? null),
    ...(extra.already_assigned
      ? {
          alreadyAssigned: extra.already_assigned.map((a) => ({
            slot: a.slot,
            recipeId: a.recipe_id,
          })),
        }
      : {}),
    ...(extra.served
      ? {
          recentlyServed: extra.served.map((m) => ({ recipeId: m.recipe_id, date: m.date })),
        }
      : {}),
  };
}

describe("présélection — constantes recopiées dans la fixture", () => {
  test("mêmes valeurs des deux côtés", () => {
    const c = fixture.constants;
    assert.equal(HISTORY_DAYS, c.history_days);
    assert.equal(FRESHNESS_FLOOR, c.freshness_floor);
    assert.equal(REHEAT_BONUS, c.reheat_bonus);
    assert.equal(PROTEIN_REPEAT_FACTOR, c.protein_repeat_factor);
    assert.equal(MIN_DISTINCT_PROTEINS, c.min_distinct_proteins);
    assert.equal(REST_EVE_MINUTES, c.rest_eve_minutes);
    assert.equal(RATING_EXCLUDE_MAX, c.rating_exclude_max);
    assert.equal(RATING_LOW_MAX, c.rating_low_max);
    assert.equal(RATING_LOW_FACTOR, c.rating_low_factor);
    assert.equal(RATING_HIGH_MIN, c.rating_high_min);
    assert.equal(RATING_HIGH_FACTOR, c.rating_high_factor);
    assert.equal(CONCEPT_RUN_TTL_MS, c.concept_run_ttl_hours * 3_600_000);
    assert.equal(REFUSAL_PENALTY_DAYS, c.refusal_penalty_days);
    assert.equal(REFUSAL_FACTOR, c.refusal_factor);
    assert.equal(REFUSAL_REPEAT_THRESHOLD, c.refusal_repeat_threshold);
    assert.equal(REFUSAL_REPEAT_FACTOR, c.refusal_repeat_factor);
    assert.equal(REFUSAL_MAX_ENTRIES, c.refusal_max_entries);
    assert.equal(REFUSAL_FUTURE_TOLERANCE_DAYS, c.refusal_future_tolerance_days);
    assert.equal(STARCH_REPEAT_FACTOR, c.starch_repeat_factor);
  });
});

describe("présélection — protéine et réchauffage", () => {
  for (const c of fixture.protein_of) {
    test(`${c.main_protein ?? ""} ${c.dish_types.join(", ") || "(vide)"} (${c.why})`, () => {
      assert.equal(
        proteinOf({
          dishTypes: c.dish_types,
          ...(c.main_protein != null ? { mainProtein: c.main_protein } : {}),
        }),
        c.expected,
      );
    });
  }
  for (const c of fixture.starch_of) {
    test(`féculent ${c.main_starch} (${c.why})`, () => {
      assert.equal(starchOf({ mainStarch: c.main_starch }), c.expected);
    });
  }
  for (const c of fixture.starch_repeat) {
    test(`féculent répété : ${c.candidate} (${c.why})`, () => {
      assert.equal(
        isStarchRepeat(
          starchOf({ mainStarch: c.candidate }),
          c.neighbours.map((n) => starchOf({ mainStarch: n })),
        ),
        c.expected,
      );
    });
  }
  for (const c of fixture.reheat_friendly) {
    test(`réchauffage : ${[...c.dish_types, ...c.themes].join(", ")} (${c.why})`, () => {
      assert.equal(isReheatFriendly({ dishTypes: c.dish_types, themes: c.themes }), c.expected);
    });
  }
});

describe("présélection — filtres durs", () => {
  for (const c of fixture.hard_filter) {
    test(c.why, () => {
      const input = inputOf([c.slot], [summaryOf(c.recipe)]);
      const ctx = slotContexts(input)[0];
      const ratings = new Map<string, number>(
        c.rating != null ? [[c.recipe.id as string, c.rating as number]] : [],
      );
      assert.equal(
        hardFilterReason(summaryOf(c.recipe), ctx, c.role, {
          inCycle: new Set(c.in_cycle ?? []),
          today: c.today,
          ratings,
        }),
        c.expected,
      );
    });
  }
});

describe("présélection — note et poids", () => {
  for (const c of fixture.freshness) {
    test(`fraîcheur ${c.days} (${c.why})`, () => {
      assert.equal(freshnessScore(c.days), c.expected);
    });
  }
  for (const c of fixture.rating_factor) {
    test(`note ${c.rating} (${c.why})`, () => {
      assert.equal(ratingFactor(c.rating), c.expected);
    });
  }
  for (const c of fixture.weight) {
    test(`poids (${c.why})`, () => {
      const w = candidateWeight({
        daysSinceServed: c.days,
        reheatSlot: c.reheat_slot,
        reheatFriendly: c.reheat_friendly,
        proteinRepeats: c.protein_repeats,
        rating: c.rating ?? null,
        ...(c.refusal_factor != null ? { refusalFactor: c.refusal_factor } : {}),
        ...(c.starch_repeat != null ? { starchRepeat: c.starch_repeat } : {}),
      });
      assert.ok(Math.abs(w - c.expected) < 1e-9, `${w} ≠ ${c.expected}`);
    });
  }
});

const DAY_MS = 86_400_000;
const NOW_MS = Date.parse("2026-10-10T12:00:00Z");

/** Refus de la fixture (âge en jours) → entrée, relative à [nowMs]. */
function refusalOf(r: { age_days: number; count: number | null }, nowMs: number): RefusalEntry {
  return { refusedAtMs: nowMs - r.age_days * DAY_MS, count: r.count ?? 0 };
}

describe("présélection — mémoire des refus", () => {
  for (const c of fixture.refusal_factor) {
    test(`refus ${c.age_days ?? "aucun"} j, ${c.count ?? "-"} fois (${c.why})`, () => {
      const entry =
        c.age_days == null ? null : refusalOf({ age_days: c.age_days, count: c.count }, NOW_MS);
      assert.equal(refusalFactor(entry, NOW_MS), c.expected);
    });
  }

  /** Horodatage Firestore minimal : seule `toMillis()` est lue. */
  const ts = (ms: number) => ({ toMillis: () => ms });

  test("lecture du document : entrées expirées et illisibles ignorées", () => {
    const out = readRefusals(
      {
        entries: {
          recent: { refused_at: ts(NOW_MS - 2 * DAY_MS), count: 2 },
          old: { refused_at: ts(NOW_MS - 30 * DAY_MS), count: 9 },
          noDate: { count: 1 },
          future: { refused_at: ts(NOW_MS + 3 * DAY_MS), count: 1 },
          badCount: { refused_at: ts(NOW_MS - DAY_MS), count: "x" },
          notAMap: "x",
        },
      },
      NOW_MS,
    );
    assert.deepEqual([...out.keys()].sort(), ["badCount", "recent"]);
    assert.equal(out.get("recent")?.count, 2);
    assert.equal(out.get("badCount")?.count, 1);
  });

  test("lecture du document : absent ou mal formé, aucune entrée", () => {
    assert.equal(readRefusals(null, NOW_MS).size, 0);
    assert.equal(readRefusals({ entries: [] }, NOW_MS).size, 0);
    assert.equal(readRefusals({ entries: "x" }, NOW_MS).size, 0);
  });

  test("lecture du document : au plus les entrées les plus récentes", () => {
    const entries: Record<string, unknown> = {};
    for (let i = 0; i < REFUSAL_MAX_ENTRIES + 20; i++) {
      entries[`r${i}`] = { refused_at: ts(NOW_MS - i * 60_000), count: 1 };
    }
    const out = readRefusals({ entries }, NOW_MS);
    assert.equal(out.size, REFUSAL_MAX_ENTRIES);
    assert.ok(out.has("r0"));
    assert.ok(!out.has(`r${REFUSAL_MAX_ENTRIES + 19}`));
  });
});

describe("présélection — tirage pondéré", () => {
  for (const c of fixture.weighted_order) {
    test(c.why, () => {
      const items = Object.keys(c.weights);
      const out = weightedOrder(items, (k) => c.weights[k], seededRng(c.seed));
      if (c.expected_last) assert.equal(out[out.length - 1], c.expected_last);
      if (c.expected_order) assert.deepEqual(out, c.expected_order);
    });
  }

  test("même graine, même ordre ; deux graines, deux ordres", () => {
    const items = Array.from({ length: 20 }, (_, i) => `r${i}`);
    const a = weightedOrder(items, () => 1, seededRng(3));
    const b = weightedOrder(items, () => 1, seededRng(3));
    const c = weightedOrder(items, () => 1, seededRng(4));
    assert.deepEqual(a, b);
    assert.notDeepEqual(a, c);
  });

  test("un poids 2 sort en tête environ deux fois plus souvent qu'un poids 1", () => {
    const rng = seededRng(2026);
    let heavy = 0;
    const runs = 2000;
    for (let i = 0; i < runs; i++) {
      if (weightedOrder(["lourd", "léger"], (k) => (k === "lourd" ? 2 : 1), rng)[0] === "lourd") {
        heavy++;
      }
    }
    // Probabilité attendue : 2 / 3.
    assert.ok(Math.abs(heavy / runs - 2 / 3) < 0.05, `${heavy} sur ${runs}`);
  });
});

describe("présélection — répartition par protéine", () => {
  for (const c of fixture.spread_proteins) {
    test(c.why, () => {
      const proteins = new Map<string, ProteinKey>(
        (c.ordered as Array<[string, ProteinKey]>).map(([id, p]) => [id, p]),
      );
      const typesOf = (p: ProteinKey) =>
        p === "inconnue" ? [] : [p === "viande" ? "boeuf" : p.replace(/_/g, " ")];
      const ordered = (c.ordered as Array<[string, ProteinKey]>).map(([id, p]) => ({
        id,
        titre: id,
        dishTypes: typesOf(p),
      }));
      for (const r of ordered) assert.equal(proteinOf(r), proteins.get(r.id));
      assert.deepEqual(
        spreadProteins(ordered, c.k, c.min_distinct).map((r) => r.id),
        c.expected,
      );
    });
  }
});

describe("présélection — listes par créneau", () => {
  for (const c of fixture.preselect) {
    test(c.why, () => {
      const recipes = c.recipes.map(summaryOf);
      const input = inputOf(c.slots, recipes, c);
      const served = c.served ?? [];
      const slotsToFill = Math.max(
        1,
        input.slotDates.length - (input.alreadyAssigned?.length ?? 0),
      );
      const window = applyRecentlyServed(recipes, input.recentlyServed ?? [], slotsToFill);
      const out = preselect({
        input,
        candidates: window.candidates,
        recentExcluded: recipes.filter((r) => window.excludedIds.includes(r.id)),
        lastServed: new Map(served.map((m) => [m.recipe_id as string, m.date as string])),
        ratings: new Map(Object.entries((c.ratings ?? {}) as Record<string, number>)),
        refusals: new Map(
          Object.entries(c.refusals ?? {}).map(([id, r]) => [
            id,
            refusalOf(r, Date.parse(`${c.today}T12:00:00Z`)),
          ]),
        ),
        nowMs: Date.parse(`${c.today}T12:00:00Z`),
        historyAvailable: true,
        policy: readPlanningPolicy(c.policy),
        today: c.today,
        rng: seededRng(c.seed),
      });
      const head = (list: RankedCandidate[], n: number) =>
        list
          .slice(0, n)
          .map((x) => x.recipeId)
          .sort();
      if (c.expected.heads_disjoint) {
        const heads = out.map((r) => head(r.plats, r.sent.plats));
        assert.deepEqual(
          heads.map((h) => h.length),
          c.expected.head_sizes,
        );
        const all = heads.flat();
        assert.equal(new Set(all).size, all.length, "têtes disjointes");
      }
      for (const want of c.expected.slots ?? []) {
        const got = out.find((r) => r.slot === want.slot);
        assert.ok(got, `créneau ${want.slot} classé`);
        assert.deepEqual(head(got.plats, got.sent.plats), want.plats);
        if (want.desserts) assert.deepEqual(head(got.desserts, got.sent.desserts), want.desserts);
        if (want.entrees) assert.deepEqual(head(got.entrees, got.sent.entrees), want.entrees);
        assert.deepEqual(
          got.plats
            .filter((x) => x.repeat)
            .map((x) => x.recipeId)
            .sort(),
          want.repeat,
        );
        assert.deepEqual(got.relaxed, want.relaxed);
        if (want.refused) {
          assert.deepEqual(
            got.plats
              .filter((x) => x.why.includes("refusée récemment"))
              .map((x) => x.recipeId)
              .sort(),
            want.refused,
          );
        }
      }
      assert.ok(
        out.every((r) => !(input.alreadyAssigned ?? []).some((a) => a.slot === r.slot)),
        "un créneau déjà assigné n'a pas de liste",
      );
    });
  }

  test("féculent de la veille : le premier plat du lendemain en change plus souvent", () => {
    const plat = (id: string, starch: string): PlanningRecipeSummary => ({
      id,
      titre: id,
      mealRole: "plat",
      mainStarch: starch,
    });
    const share = (neighbourStarch: string) => {
      const recipes = [
        plat("r0", neighbourStarch),
        plat("a1", "riz"),
        plat("a2", "riz"),
        plat("a3", "riz"),
        plat("b1", "pates"),
        plat("b2", "pates"),
        plat("b3", "pates"),
      ];
      const input: PlanningInput = {
        ...inputOf([{ date: "2026-10-12" }, { date: "2026-10-13" }], recipes),
        alreadyAssigned: [{ slot: 0, recipeId: "r0" }],
      };
      let riz = 0;
      const runs = 600;
      for (let seed = 1; seed <= runs; seed++) {
        const [ranking] = preselect({
          input,
          candidates: recipes,
          recentExcluded: [],
          lastServed: new Map(),
          ratings: new Map(),
          historyAvailable: true,
          policy: readPlanningPolicy({ plats_per_slot: 3 }),
          today: "2026-10-10",
          rng: seededRng(seed),
        });
        if (ranking.plats[0].recipeId.startsWith("a")) riz++;
      }
      return riz / runs;
    };
    // Poids 0,5 contre 1 : environ un tiers de riz en tête, contre la moitié.
    assert.ok(share("riz") < 0.42, `riz en tête : ${share("riz")}`);
    assert.ok(share("semoule") > 0.42, `riz en tête sans voisin riz : ${share("semoule")}`);
  });

  test("chaque candidat rendu passe les filtres durs du créneau", () => {
    const recipes: PlanningRecipeSummary[] = Array.from({ length: 40 }, (_, i) => ({
      id: `r${i}`,
      titre: `Recette ${i}`,
      prepTime: (i % 6) * 10,
      mealRole: i % 7 === 0 ? "dessert" : i % 5 === 0 ? "entree" : "plat",
      dishTypes: [["volaille"], ["poisson"], ["boeuf"], ["vegan"], []][i % 5],
    }));
    const slots = [
      { date: "2026-10-12", max_prep: 30, format: "entree_plat_dessert" },
      { date: "2026-10-13", max_prep: 20 },
      { date: "2026-10-14", format: "leger" },
    ];
    const input = inputOf(slots, recipes);
    const out = preselect({
      input,
      candidates: recipes,
      recentExcluded: [],
      lastServed: new Map(),
      ratings: new Map(),
      historyAvailable: true,
      policy: DEFAULT_PLANNING_POLICY,
      today: "2026-10-10",
      rng: seededRng(9),
    });
    const contexts = slotContexts(input);
    const byId = new Map(recipes.map((r) => [r.id, r]));
    for (const r of out) {
      const ctx = contexts[r.slot];
      const check = (list: RankedCandidate[], role: "main" | "starter" | "dessert") => {
        for (const c of list) {
          assert.equal(
            hardFilterReason(byId.get(c.recipeId)!, ctx, role, {
              inCycle: new Set(),
              today: "2026-10-10",
            }),
            null,
            `${c.recipeId} sur le créneau ${r.slot}`,
          );
        }
      };
      check(r.plats, "main");
      check(r.entrees, "starter");
      check(r.desserts, "dessert");
    }
  });
});

/** Classement de la fixture : tout ce qui est listé part au modèle. */
function rankingOf(r: FxRanking): SlotRanking {
  const cand = (ids: string[] | undefined): RankedCandidate[] =>
    (ids ?? []).map((id) => ({ recipeId: id, why: `faits ${id}` }));
  return {
    slot: r.slot,
    plats: cand(r.plats),
    entrees: cand(r.entrees),
    desserts: cand(r.desserts),
    sent: {
      plats: (r.plats ?? []).length,
      entrees: (r.entrees ?? []).length,
      desserts: (r.desserts ?? []).length,
    },
    relaxed: [],
  };
}

describe("lecture des choix du modèle", () => {
  for (const c of fixture.validate_choice) {
    test(c.why, () => {
      const rankings = c.rankings.map(rankingOf);
      const ids = new Set(rankings.flatMap((r) => [...r.plats, ...r.entrees, ...r.desserts]));
      const recipes = [...ids].map((x) => ({ id: x.recipeId, titre: x.recipeId }));
      const input = inputOf(c.slots, recipes);
      const out = validateModelChoices({
        raw: c.raw,
        rankings,
        input,
        corpusById: new Map(recipes.map((r) => [r.id, r])),
      });
      assert.equal(out.rejected, c.rejected);
      assert.deepEqual(
        out.slots.map((s) => ({
          slot: s.slot,
          recipe_id: s.recipeId,
          source: s.source,
          ...(s.starterId ? { starter_id: s.starterId } : {}),
          ...(s.dessertId ? { dessert_id: s.dessertId } : {}),
        })),
        c.expected,
      );
    });
  }
});

describe("justification produite par le code", () => {
  for (const c of fixture.code_justification) {
    test(c.why, () => {
      const r = summaryOf(c.recipe);
      const ctx = slotContexts(inputOf([c.slot], [r]))[0];
      assert.equal(
        codeJustification(r, ctx, {
          lastServed: c.last_served,
          historyAvailable: c.history,
          rating: c.rating ?? null,
          repeat: c.repeat ?? false,
          refused: c.refused ?? false,
        }),
        c.expected,
      );
    });
  }
});

describe("redimensionnement calculé", () => {
  for (const c of fixture.resize) {
    test(c.why, () => {
      const out = resizeOf({ portions: c.portions }, { targetPortions: c.target });
      assert.equal(out.resized, c.expected.resized);
      if (c.expected.reason) assert.equal(out.resizeReason, c.expected.reason);
      else assert.equal(out.resizeReason, undefined);
    });
  }
});

describe("politique de présélection", () => {
  for (const c of fixture.policy) {
    test(c.why, () => {
      const p = readPlanningPolicy(c.raw);
      assert.deepEqual(
        {
          plats_per_slot: p.platsPerSlot,
          starters_per_slot: p.startersPerSlot,
          desserts_per_slot: p.dessertsPerSlot,
          ranked_depth: p.rankedDepth,
          concepts_per_generation: p.conceptsPerGeneration,
          cost_cap_eur_per_generation: p.costCapEurPerGeneration,
        },
        c.expected,
      );
    });
  }
});

describe("plafond de conceptions par génération", () => {
  for (const c of fixture.concept_decision) {
    test(c.why, () => {
      const run = c.run
        ? {
            createdAtMs: c.run.created_at_ms,
            conceptsMax: c.run.concepts_max,
            conceptsUsed: c.run.concepts_used,
            costUsd: c.run.cost_usd,
            reservedUsd: c.run.reserved_usd ?? 0,
            costCapUsd: c.run.cost_cap_usd,
          }
        : null;
      const out = planningConceptDecision({ run, nowMs: c.now_ms, estimateUsd: c.estimate_usd });
      assert.equal(out.ok ? null : out.reason, c.expected);
    });
  }
});

describe("conceptions automatiques ouvertes par une génération", () => {
  for (const c of fixture.concepts_allowance) {
    test(c.why, () => {
      assert.equal(
        conceptsAllowance({ policyMax: c.policy_max, slots: c.slots, filled: c.filled }),
        c.expected,
      );
    });
  }
});

describe("prompt compact", () => {
  const recipes: PlanningRecipeSummary[] = Array.from({ length: 60 }, (_, i) => ({
    id: `r${String(i).padStart(2, "0")}`,
    titre: `Recette ${String(i).padStart(2, "0")}`,
    mealRole: i < 40 ? "plat" : i < 50 ? "entree" : "dessert",
  }));
  const slots = Array.from({ length: 7 }, (_, i) => ({
    date: `2026-10-${12 + i}`,
    format: "entree_plat_dessert",
  }));
  const build = (seed: number) => {
    const input = inputOf(slots, recipes);
    const rng = seededRng(seed);
    const rankings = preselect({
      input,
      candidates: recipes,
      recentExcluded: [],
      lastServed: new Map(),
      ratings: new Map(),
      historyAvailable: true,
      policy: DEFAULT_PLANNING_POLICY,
      today: "2026-10-10",
      rng,
    });
    return buildPlanningPrompt({
      input,
      rankings,
      sentSlots: new Set(rankings.filter(needsModel).map((r) => r.slot)),
      corpusById: new Map(recipes.map((r) => [r.id, r])),
      rng,
    });
  };

  test("7 créneaux : au plus 35 plats, 21 entrées, 21 desserts, chacun décrit une fois", () => {
    const { prompt, candidateIds } = build(1);
    assert.equal(new Set(candidateIds).size, candidateIds.length);
    assert.ok(candidateIds.length <= 35 + 21 + 21);
    for (const id of candidateIds) {
      const described = prompt.split("\n").filter((l) => l.startsWith(`${id} | `));
      assert.equal(described.length, 1, `${id} décrit une fois`);
    }
    const platsLines = prompt.split("\n").filter((l) => l.trim().startsWith("PLATS :"));
    assert.equal(platsLines.length, 7);
    for (const l of platsLines) assert.ok(l.split(",").length <= 5);
  });

  test("le prompt ne pousse plus vers les plats familiaux et ne demande plus le redimensionnement", () => {
    const { prompt } = build(1);
    assert.ok(!prompt.includes("plat familial"));
    assert.ok(!prompt.includes("resize_reason"));
    assert.ok(!prompt.includes('"why"'));
  });

  test("l'ordre des recettes ne suit pas l'ordre du corpus", () => {
    const sorted = (ids: string[]) => [...ids].sort();
    let differs = false;
    for (let seed = 1; seed <= 20 && !differs; seed++) {
      const { candidateIds } = build(seed);
      differs = candidateIds.some((id, i) => sorted(candidateIds)[i] !== id);
    }
    assert.ok(differs);
  });
});
