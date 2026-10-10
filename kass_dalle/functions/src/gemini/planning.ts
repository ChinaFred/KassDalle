/**
 * Suggestion de planning de repas.
 * Porté depuis PlanningAiService.suggestMealPlan().
 */

import { extractJsonArray } from "./client";
import { callModel } from "../ai/router";
import { BudgetExceededError } from "../ai/budget";
import { estimateAiCostUsd, type AiModelPricing } from "../ai/pricing";
import { textPart, type AiProvider, type ModelCallContext } from "../ai/types";
import { logError, logInfo, logWarn } from "../logging";
import { parseMainProtein, parseMainStarch, type MainProtein, type MainStarch } from "./mealRole";

export interface RecipeConceptInput {
  slotDate: string;
  globalConstraints: string;
  dayConstraint?: DayConstraint;

  /**
   * Ce qui est déjà prévu dans le cycle, du plus proche au plus lointain.
   *
   * Sans cette liste, chaque conception est aveugle aux autres : sept appels
   * indépendants à qui l'on demande « un plat familial » rendent sept fois le
   * même réflexe — six poulets et deux tajines dans la même semaine, malgré une
   * consigne de variété que chaque appel respecte pourtant, isolément.
   *
   * C'est la seule façon de tenir une contrainte qui porte sur l'ENSEMBLE quand
   * on génère créneau par créneau.
   */
  alreadyPlanned?: string[];

  /**
   * Le plat à rédiger, quand la personne l'a déjà choisi — une idée retenue
   * dans « Générer avec l'IA » du sélecteur. Le modèle écrit CETTE recette,
   * sous ce titre, au lieu d'en inventer une.
   */
  requestedDish?: { titre: string; description?: string };

  /**
   * Génération à laquelle la conception se rattache (`pr_…`). Présent, le
   * plafond de conceptions et de coût de la génération s'applique ; absent,
   * c'est un geste unitaire, borné par le plafond du jour.
   */
  runId?: string;
}

export interface RecipeConceptResult {
  titre: string;
  cooklang: string;
  justification: string;
  /** Coût enregistré par `callModel` — interne, non renvoyé au client. */
  costUsd?: number | null;
}

export interface PlanningRecipeSummary {
  id: string;
  titre: string;
  prepTime?: number | null;
  /** Marinade, réfrigération, levée : ce qui oblige à commencer la veille. */
  restTime?: number | null;
  cookTime?: number | null;
  dishTypes?: string[];
  themes?: string[];
  cuisines?: string[];
  occasions?: string[];
  mainIngredients?: string[];
  /**
   * Rôle dans un repas, posé sur la recette par le modèle une fois pour
   * toutes : `plat`, `accompagnement`, `entree`, `dessert`, `snack`. Absent
   * pour une recette pas encore classée.
   */
  mealRole?: string | null;
  /**
   * Protéine et féculent principaux (`tags.main_protein`, `tags.main_starch`),
   * envoyés par le client pour un plat ou un accompagnement. Donnée non fiable :
   * relue par `parseMainProtein` / `parseMainStarch`, une valeur hors liste vaut
   * absente.
   */
  mainProtein?: string | null;
  mainStarch?: string | null;
  /**
   * Parts pour lesquelles la recette est écrite. Sert à dire qu'un repas sera
   * redimensionné (`resizeOf`) ; rien n'est écrit dans la recette.
   */
  portions?: number | null;
}

/**
 * Règles de créneau — serveur seul, verrouillées par
 * `test-fixtures/planning_slot_rules.json` (`planningSlotRules.test.ts`).
 *
 * Un écart ne lève aucune erreur : il laisse passer un dessert en plat, ou
 * décale un jour de préparation. Les cas vivent dans la fixture.
 */

/** Ce qu'un format de repas demande autour du plat. */
export type MealFormatKey =
  "plat" | "plat_dessert" | "entree_plat" | "entree_plat_dessert" | "leger";

export interface MealFormatSpec {
  key: MealFormatKey;
  wantsStarter: boolean;
  wantsDessert: boolean;
  /** Un seul plat léger : soupe, salade, entrée servie en plat, en-cas. */
  light: boolean;
  /** Comment le prompt nomme ce format. */
  label: string;
}

const MEAL_FORMATS: Record<MealFormatKey, MealFormatSpec> = {
  plat: { key: "plat", wantsStarter: false, wantsDessert: false, light: false, label: "plat seul" },
  plat_dessert: {
    key: "plat_dessert",
    wantsStarter: false,
    wantsDessert: true,
    light: false,
    label: "plat + dessert",
  },
  entree_plat: {
    key: "entree_plat",
    wantsStarter: true,
    wantsDessert: false,
    light: false,
    label: "entrée + plat",
  },
  entree_plat_dessert: {
    key: "entree_plat_dessert",
    wantsStarter: true,
    wantsDessert: true,
    light: false,
    label: "entrée + plat + dessert",
  },
  leger: {
    key: "leger",
    wantsStarter: false,
    wantsDessert: false,
    light: true,
    label: "repas léger — un seul plat léger : soupe, salade, entrée servie en plat, en-cas",
  },
};

/**
 * Le format d'un créneau. Tout ce qui n'est pas réglé, ou inconnu, est le
 * plat seul : un format deviné vaudrait un dessert que personne n'a demandé.
 *
 * C'est le format qui décide d'une entrée ou d'un dessert — et non plus un
 * mot-clé lu dans une contrainte en langage naturel.
 */
export function mealFormatOf(key: string | null | undefined): MealFormatSpec {
  if (!key) return MEAL_FORMATS.plat;
  return (MEAL_FORMATS as Record<string, MealFormatSpec>)[key] ?? MEAL_FORMATS.plat;
}

export type PlanningRole = "plat" | "accompagnement" | "entree" | "dessert" | "snack";

/**
 * Le rôle sous lequel le planning propose une recette.
 *
 * Une recette classée porte son rôle. Une recette pas encore classée est un
 * plat — sauf si son titre ou ses types disent un dessert : le repli par
 * mots-clés d'avant, gardé pour ce que le backfill n'a pas encore vu.
 */
export function planningRoleOf(recipe: PlanningRecipeSummary): PlanningRole {
  const role = recipe.mealRole;
  if (
    role === "plat" ||
    role === "accompagnement" ||
    role === "entree" ||
    role === "dessert" ||
    role === "snack"
  ) {
    return role;
  }
  return isDessertRecipe(recipe) ? "dessert" : "plat";
}

/**
 * Ce que le prompt liste, par rôle. Un accompagnement ne se sert pas seul :
 * il n'est proposé nulle part ici, c'est le programme qui le pose.
 */
export function partitionByRole(recipes: PlanningRecipeSummary[]): {
  plats: PlanningRecipeSummary[];
  entrees: PlanningRecipeSummary[];
  desserts: PlanningRecipeSummary[];
  encas: PlanningRecipeSummary[];
} {
  const plats: PlanningRecipeSummary[] = [];
  const entrees: PlanningRecipeSummary[] = [];
  const desserts: PlanningRecipeSummary[] = [];
  const encas: PlanningRecipeSummary[] = [];
  for (const r of recipes) {
    switch (planningRoleOf(r)) {
      case "plat":
        plats.push(r);
        break;
      case "entree":
        entrees.push(r);
        break;
      case "dessert":
        desserts.push(r);
        break;
      case "snack":
        encas.push(r);
        break;
      default:
        break;
    }
  }
  return { plats, entrees, desserts, encas };
}

const DESSERT_RECIPE_MARKERS = [
  "dessert",
  "sucre",
  "sucré",
  "gateau",
  "gâteau",
  "tarte",
  "beignet",
  "crepe",
  "crêpe",
  "brownie",
  "cookie",
  "mousse",
  "patis",
  "pâtis",
  "glace",
  "sorbet",
  "banane split",
];

/**
 * Vrai si les attributs d'une recette la désignent comme sucrée.
 *
 * Repli pour les recettes que le backfill des rôles n'a pas encore vues : une
 * recette classée porte `meal_role`, et ce repli ne la regarde plus.
 */
export function isDessertBag(attributes: string[]): boolean {
  const bag = attributes.join(" ").toLowerCase();
  return DESSERT_RECIPE_MARKERS.some((k) => bag.includes(k));
}

/**
 * Un temps de repos, écrit comme on le dit.
 *
 * « 720min » ne se lit pas ; « 12 h » si. Et c'est bien la lecture qui compte :
 * ce nombre part dans un prompt, pas dans un calcul.
 */
function formatRepos(minutes: number): string {
  if (minutes >= 1440) {
    const jours = Math.round(minutes / 1440);
    return jours === 1 ? "1 jour" : `${jours} jours`;
  }
  if (minutes >= 60) {
    const heures = Math.floor(minutes / 60);
    const reste = minutes % 60;
    return reste === 0 ? `${heures} h` : `${heures} h ${reste}`;
  }
  return `${minutes} min`;
}

function isDessertRecipe(recipe: PlanningRecipeSummary): boolean {
  return isDessertBag([
    recipe.titre,
    ...(recipe.dishTypes ?? []),
    ...(recipe.themes ?? []),
    ...(recipe.occasions ?? []),
  ]);
}

/**
 * Nature d'un créneau : `batch`, `reheat` ou `regular`.
 *
 * Le jour de batch cooking l'emporte : on y sert un vrai repas du cycle.
 */
export function slotKind(
  slotWeekday: number,
  isReheatConstraint: boolean,
  batchCookingDay?: number | null,
): "batch" | "reheat" | "regular" {
  if (batchCookingDay != null && slotWeekday === batchCookingDay) return "batch";
  if (isReheatConstraint) return "reheat";
  return "regular";
}

export interface DayConstraint {
  maxPrepMinutes?: number;
  /** Nombre de parts à préparer ce jour-là (0 = portions de la recette). */
  targetPortions?: number;
  isBatchCooking?: boolean;
  notes?: string;
  /** Format du repas (`MealFormatKey`) ; absent = plat seul. */
  mealFormat?: string;
}

export interface PlanningInput {
  recipes: PlanningRecipeSummary[];
  /** ISO 8601 dates pour chaque slot. */
  slotDates: string[];
  /** Map weekday (1=lundi … 7=dimanche) → contraintes. */
  dailyConstraints: Record<number, DayConstraint>;
  /**
   * Contraintes par index de slot, prioritaires sur `dailyConstraints`.
   *
   * Un cycle peut dépasser sept jours : deux slots partagent alors le même jour
   * de semaine et s'écraseraient mutuellement dans une map indexée par weekday.
   */
  slotConstraints?: Array<DayConstraint | null>;
  globalConstraints: string;
  /** Jour de la semaine dédié au batch cooking (1=lundi…7=dimanche). */
  batchCookingDay?: number;
  /**
   * Recettes déjà assignées dans le cycle (pour éviter les répétitions). Un
   * `slot` hors de `slotDates` (−1) désigne une recette posée ailleurs dans le
   * cycle, hors de cette demande : « Autre suggestion » sur un seul créneau.
   */
  alreadyAssigned?: Array<{ slot: number; recipeId: string }>;
  /**
   * Repas servis AVANT le cycle, dans la fenêtre de variété choisie par
   * l'utilisateur (« ne pas reproposer un plat servi dans les N dernières
   * semaines »). Le client les lit dans ses propres repas planifiés ; le
   * serveur les retire du corpus tant qu'il reste assez de recettes ; celles
   * qu'il a dû garder reçoivent une note de fraîcheur basse et, sélectionnées,
   * la mention « peu d'autres choix ». Absent ou vide : aucune fenêtre.
   */
  recentlyServed?: RecentlyServedMeal[];
  /**
   * `model` (défaut) : présélection puis un appel de modèle. `code` :
   * présélection seule, sans appel — « Autre suggestion » sans liste en main.
   */
  mode?: "model" | "code";
  /** Recettes écartées par créneau, même index que `slotDates`. */
  slotDismissed?: Array<string[] | null>;
}

/** Un repas servi avant le cycle : ce que la fenêtre de variété regarde. */
export interface RecentlyServedMeal {
  recipeId: string;
  titre?: string;
  /** Date ISO (YYYY-MM-DD) du repas. */
  date: string;
}

/** Ce que la fenêtre de variété a fait du corpus. */
export interface RecentlyServedOutcome {
  /** Les recettes encore proposables au modèle. */
  candidates: PlanningRecipeSummary[];
  /** Retirées du corpus : servies dans la fenêtre, et le corpus restait suffisant. */
  excludedIds: string[];
  /** Servies dans la fenêtre, mais gardées faute d'alternatives. */
  keptRecentIds: string[];
}

/**
 * Retire du corpus les recettes servies dans la fenêtre de variété.
 *
 * Un candidat absent de la liste est une certitude ; une consigne « évite »
 * dans le prompt est un vœu. Mais retirer sans compter peut laisser moins de
 * recettes que de créneaux : on retire donc du plus récent au plus ancien, et
 * on s'arrête dès que le corpus tomberait sous le nombre de créneaux à
 * remplir. Ce qui reste de récent garde une note de fraîcheur basse.
 *
 * Testé par la fixture `planning_slot_rules.json`, section `recently_served`.
 */
export function applyRecentlyServed(
  recipes: PlanningRecipeSummary[],
  recentlyServed: RecentlyServedMeal[],
  slotsToFill: number,
): RecentlyServedOutcome {
  const floor = Math.max(1, slotsToFill);
  const recentIds = recentlyServedIdsNewestFirst(recentlyServed);
  const inCorpus = new Set(recipes.map((r) => r.id));
  const excluded = new Set<string>();
  const kept: string[] = [];
  let remaining = recipes.length;
  for (const id of recentIds) {
    if (!inCorpus.has(id) || excluded.has(id)) continue;
    if (remaining - 1 >= floor) {
      excluded.add(id);
      remaining--;
    } else {
      kept.push(id);
    }
  }
  return {
    candidates: recipes.filter((r) => !excluded.has(r.id)),
    excludedIds: [...excluded],
    keptRecentIds: kept,
  };
}

/** Les identifiants servis, du plus récent au plus ancien, une fois chacun. */
function recentlyServedIdsNewestFirst(meals: RecentlyServedMeal[]): string[] {
  const ordered = [...meals]
    .filter((m) => typeof m.recipeId === "string" && m.recipeId.length > 0)
    .sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : 0));
  const seen = new Set<string>();
  const ids: string[] = [];
  for (const m of ordered) {
    if (seen.has(m.recipeId)) continue;
    seen.add(m.recipeId);
    ids.push(m.recipeId);
  }
  return ids;
}

export interface PlanningSlotResult {
  slot: number;
  recipeId: string;
  /** L'entrée, quand le format du créneau en demande une ; une recette de rôle `entree`. */
  starterId?: string;
  /** Le dessert, quand le format du créneau en demande un ; une recette de rôle `dessert`. */
  dessertId?: string;
  /**
   * Faits vérifiables produits par le code (`codeJustification`) : protéine,
   * durée, note personnelle, dernier service. Jamais un texte du modèle.
   */
  justification?: string;
  /** Vrai quand les parts servies diffèrent de celles de la recette (`resizeOf`). */
  resized?: boolean;
  /** « Écrite pour 4 parts, servie pour 6. » */
  resizeReason?: string;
  /** ISO date (YYYY-MM-DD) du jour de préparation à l'avance, si applicable. */
  prepDate?: string;
  /** Qui a choisi : le modèle parmi les candidats, ou le code. */
  source: "model" | "code";
  /** Vrai si la recette n'est là que par relâchement d'un filtre (petit corpus). */
  repeat?: boolean;
}

/** Jour de semaine (1=lundi … 7=dimanche) d'une date ISO de slot. */
export function weekdayOfSlot(slotDateStr: string): number {
  return ((new Date(slotDateStr).getUTCDay() + 6) % 7) + 1;
}

/**
 * Contrainte applicable à un slot : celle du slot si elle est fournie, sinon
 * celle du jour de semaine. Renvoie `undefined` si aucune des deux n'existe.
 */
export function constraintForSlot(
  input: Pick<PlanningInput, "slotDates" | "dailyConstraints" | "slotConstraints">,
  slot: number,
): DayConstraint | undefined {
  const explicit = input.slotConstraints?.[slot];
  if (explicit) return explicit;
  const dateStr = input.slotDates[slot];
  if (!dateStr) return undefined;
  return input.dailyConstraints[weekdayOfSlot(dateStr)];
}

export function computePrepDate(slotDateStr: string, batchCookingWeekday: number): string {
  const date = new Date(slotDateStr);
  const slotWeekday = ((date.getUTCDay() + 6) % 7) + 1; // 1=lundi
  let daysBack = (slotWeekday - batchCookingWeekday + 7) % 7;
  if (daysBack === 0) daysBack = 7; // même jour → semaine précédente
  const prepDate = new Date(date);
  prepDate.setUTCDate(date.getUTCDate() - daysBack);
  return prepDate.toISOString().slice(0, 10);
}

// ── Présélection ─────────────────────────────────────────────────────────────
//
// Le serveur choisit lui-même les candidats de chaque créneau ; le modèle ne
// fait plus que trancher entre cinq plats. Tout ce qui suit est pur — ni
// Firestore, ni réseau — et verrouillé par `planning_slot_rules.json`.

/** Profondeur d'historique lue pour la note de fraîcheur, en jours. */
export const HISTORY_DAYS = 90;
/** Note de fraîcheur minimale : une recette servie hier reste tirable. */
export const FRESHNESS_FLOOR = 0.1;
/** Bonus d'un plat qui se réchauffe, sur un créneau de réchauffage. */
export const REHEAT_BONUS = 2;
/** Facteur appliqué par répétition d'une protéine déjà posée dans le cycle. */
export const PROTEIN_REPEAT_FACTOR = 0.6;
/** Protéines distinctes visées dans la tête de liste d'un créneau. */
export const MIN_DISTINCT_PROTEINS = 3;
/** Facteur d'un plat dont le féculent est celui d'un créneau voisin. */
export const STARCH_REPEAT_FACTOR = 0.5;
/** Repos qui oblige à commencer la veille. */
export const REST_EVE_MINUTES = 240;
/** Note personnelle jusqu'à laquelle une recette n'est plus proposée. */
export const RATING_EXCLUDE_MAX = 3;
/** Plage basse : de `RATING_EXCLUDE_MAX + 1` à cette note, poids réduit. */
export const RATING_LOW_MAX = 6;
export const RATING_LOW_FACTOR = 0.5;
/** À partir de cette note, poids augmenté. */
export const RATING_HIGH_MIN = 8;
export const RATING_HIGH_FACTOR = 1.5;
/**
 * Mémoire des refus (`users/{uid}/preferences/planning_refusals`) : un refus
 * pèse pendant 21 jours après le dernier, puis il est ignoré. Le client
 * rejoue cette durée pour élaguer le document et compter les refus actifs.
 */
export const REFUSAL_PENALTY_DAYS = 21;
/** Poids d'une recette refusée dans les 21 jours. */
export const REFUSAL_FACTOR = 0.5;
/** À partir de ce nombre de refus, la pénalité double. */
export const REFUSAL_REPEAT_THRESHOLD = 3;
export const REFUSAL_REPEAT_FACTOR = 0.25;
/** Entrées gardées au plus dans le document ; les plus anciennes sortent. */
export const REFUSAL_MAX_ENTRIES = 300;
/**
 * Avance tolérée d'une date de refus sur l'horloge du serveur (horloge du
 * téléphone). Au-delà, l'entrée est ignorée : une date lointaine dans le
 * futur ne s'éteindrait jamais.
 */
export const REFUSAL_FUTURE_TOLERANCE_DAYS = 1;
/** Forme d'un identifiant de génération (`pr_` + 32 hexadécimaux), tiré par le serveur. */
export const PLANNING_RUN_ID_PATTERN = /^pr_[0-9a-f]{32}$/;
/** Durée de vie d'une génération pour les conceptions qui s'y rattachent. */
export const CONCEPT_RUN_TTL_MS = 6 * 60 * 60 * 1000;
/** Plafond de jetons de sortie du poste `planning` : sept lignes de JSON. */
export const PLANNING_MAX_TOKENS = 4_000;
/** Plafond de jetons de sortie du poste `planning_concept` : une recette. */
export const PLANNING_CONCEPT_MAX_TOKENS = 6_000;

/** Réglages de la présélection, lus dans `app_config/planning_policy`. */
export interface PlanningPolicy {
  platsPerSlot: number;
  startersPerSlot: number;
  dessertsPerSlot: number;
  /** Plats gardés par créneau pour « Autre suggestion » (tête comprise). */
  rankedDepth: number;
  conceptsPerGeneration: number;
  costCapEurPerGeneration: number;
}

/**
 * Valeurs par défaut. Ce sont des réglages, pas des prix : un défaut dans le
 * code est admis, comme `DEFAULT_AI_BUDGET_POLICY`.
 */
export const DEFAULT_PLANNING_POLICY: PlanningPolicy = {
  platsPerSlot: 5,
  startersPerSlot: 3,
  dessertsPerSlot: 3,
  rankedDepth: 15,
  conceptsPerGeneration: 2,
  costCapEurPerGeneration: 0.5,
};

function boundedInt(value: unknown, min: number, max: number, fallback: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return fallback;
  return Math.min(max, Math.max(min, Math.trunc(value)));
}

/** Lit la politique depuis sa forme Firestore, chaque champ borné. */
export function readPlanningPolicy(
  raw: Record<string, unknown> | null | undefined,
): PlanningPolicy {
  const d = DEFAULT_PLANNING_POLICY;
  const r = raw ?? {};
  const platsPerSlot = boundedInt(r.plats_per_slot, 3, 10, d.platsPerSlot);
  const cap = r.cost_cap_eur_per_generation;
  return {
    platsPerSlot,
    startersPerSlot: boundedInt(r.starters_per_slot, 1, 10, d.startersPerSlot),
    dessertsPerSlot: boundedInt(r.desserts_per_slot, 1, 10, d.dessertsPerSlot),
    rankedDepth: boundedInt(
      r.ranked_depth,
      platsPerSlot,
      30,
      Math.max(d.rankedDepth, platsPerSlot),
    ),
    conceptsPerGeneration: boundedInt(r.concepts_per_generation, 0, 7, d.conceptsPerGeneration),
    costCapEurPerGeneration:
      typeof cap === "number" && Number.isFinite(cap)
        ? Math.min(5, Math.max(0.05, cap))
        : d.costCapEurPerGeneration,
  };
}

/** Générateur pseudo-aléatoire injectable : valeurs dans [0, 1[. */
export type Rng = () => number;

/** mulberry32 — reproductible pour les tests ; graine tirée par crypto en production. */
export function seededRng(seed: number): Rng {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function normalize(text: string): string {
  return text.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "");
}

/**
 * La protéine d'une recette : le tag `main_protein` quand il est posé, sinon
 * l'indice lu dans `dishTypes` — qui ne distingue pas les viandes entre elles
 * (« viande »). Sans indice : « inconnue ».
 */
export type ProteinKey = MainProtein | "viande" | "inconnue";

/** Ordre de lecture : le plus précis d'abord (volaille avant viande). */
const PROTEIN_MARKERS: Array<[ProteinKey, string[]]> = [
  ["vegetarien", ["vegetarien", "vegan", "vegetalien"]],
  [
    "fruits_de_mer",
    ["fruits de mer", "crevette", "moule", "saint-jacques", "calamar", "homard", "crustace"],
  ],
  [
    "poisson",
    ["poisson", "saumon", "cabillaud", "thon", "truite", "colin", "merlu", "sardine", "maquereau"],
  ],
  ["volaille", ["volaille", "poulet", "dinde", "canard", "pintade", "chapon"]],
  [
    "viande",
    ["viande", "boeuf", "bœuf", "porc", "agneau", "veau", "mouton", "gibier", "lapin", "saucisse"],
  ],
];

export function proteinOf(r: Pick<PlanningRecipeSummary, "dishTypes" | "mainProtein">): ProteinKey {
  const tagged = parseMainProtein(r.mainProtein);
  if (tagged) return tagged;
  const bag = normalize((r.dishTypes ?? []).join(" | "));
  if (!bag) return "inconnue";
  for (const [key, markers] of PROTEIN_MARKERS) {
    if (markers.some((m) => bag.includes(m))) return key;
  }
  return "inconnue";
}

const PROTEIN_LABELS: Record<ProteinKey, string> = {
  boeuf: "bœuf",
  porc: "porc",
  agneau: "agneau",
  oeuf: "œufs",
  legumineuses: "légumineuses",
  viande: "viande",
  volaille: "volaille",
  poisson: "poisson",
  fruits_de_mer: "fruits de mer",
  vegetarien: "végétarien",
  inconnue: "",
};

const STARCH_LABELS: Record<MainStarch, string> = {
  pates: "pâtes",
  riz: "riz",
  pommes_de_terre: "pommes de terre",
  semoule: "semoule",
  pain: "pain",
  aucun: "aucun",
};

/** Le féculent principal (`main_starch`), ou `null` s'il n'est pas posé. */
export function starchOf(r: Pick<PlanningRecipeSummary, "mainStarch">): MainStarch | null {
  return parseMainStarch(r.mainStarch);
}

/**
 * Vrai si le féculent du candidat est celui d'un créneau voisin. « aucun » et
 * un féculent inconnu ne se répètent jamais.
 */
export function isStarchRepeat(
  starch: MainStarch | null,
  neighbours: ReadonlyArray<MainStarch | null>,
): boolean {
  return starch != null && starch !== "aucun" && neighbours.includes(starch);
}

const REHEAT_MARKERS = [
  "soupe",
  "mijot",
  "gratin",
  "plat complet",
  "ragout",
  "curry",
  "lasagne",
  "potee",
  "tajine",
  "daube",
];

/** Indice « se réchauffe bien » : souple, un bonus de poids, jamais un filtre. */
export function isReheatFriendly(r: Pick<PlanningRecipeSummary, "dishTypes" | "themes">): boolean {
  const bag = normalize([...(r.dishTypes ?? []), ...(r.themes ?? [])].join(" | "));
  return REHEAT_MARKERS.some((m) => bag.includes(m));
}

/** Ce que la présélection sait d'un créneau. */
export interface SlotContext {
  slot: number;
  /** YYYY-MM-DD */
  date: string;
  /** 1 = lundi */
  weekday: number;
  kind: "batch" | "reheat" | "regular";
  format: MealFormatSpec;
  maxPrepMinutes: number | null;
  targetPortions: number | null;
  dismissedIds: ReadonlySet<string>;
}

export function slotContexts(input: PlanningInput): SlotContext[] {
  return input.slotDates.map((raw, slot) => {
    const date = raw.slice(0, 10);
    const weekday = weekdayOfSlot(date);
    const constraint = constraintForSlot(input, slot);
    const maxPrep = constraint?.maxPrepMinutes ?? 0;
    const target = constraint?.targetPortions ?? 0;
    const dismissed = input.slotDismissed?.[slot];
    return {
      slot,
      date,
      weekday,
      kind: slotKind(weekday, !!constraint?.isBatchCooking, input.batchCookingDay),
      format: mealFormatOf(constraint?.mealFormat),
      maxPrepMinutes: maxPrep > 0 ? maxPrep : null,
      targetPortions: target > 0 ? target : null,
      dismissedIds: new Set(Array.isArray(dismissed) ? dismissed : []),
    };
  });
}

export type CandidateRole = "main" | "starter" | "dessert";
export type HardFilterReason = "role" | "prep" | "rest" | "rating" | "dismissed" | "in_cycle";

/** Le rôle de la recette convient-il à cette place du repas ? */
export function roleFits(
  r: PlanningRecipeSummary,
  format: MealFormatSpec,
  role: CandidateRole,
): boolean {
  const own = planningRoleOf(r);
  if (role === "starter") return own === "entree";
  if (role === "dessert") return own === "dessert";
  return own === "plat" || (format.light && (own === "entree" || own === "snack"));
}

/** Une note personnelle lisible : un entier de 0 à 10, sinon rien. */
export function readRating(value: unknown): number | null {
  return typeof value === "number" && Number.isInteger(value) && value >= 0 && value <= 10
    ? value
    : null;
}

function isLowRated(rating: number | null | undefined): boolean {
  const n = readRating(rating);
  return n != null && n <= RATING_EXCLUDE_MAX;
}

/**
 * Pourquoi une recette ne peut pas aller sur ce créneau, ou `null`.
 *
 * L'ordre des tests est celui du type : le premier qui échoue est rendu.
 */
export function hardFilterReason(
  r: PlanningRecipeSummary,
  ctx: SlotContext,
  role: CandidateRole,
  opts: {
    inCycle: ReadonlySet<string>;
    today: string;
    ratings?: ReadonlyMap<string, number>;
  },
): HardFilterReason | null {
  if (!roleFits(r, ctx.format, role)) return "role";
  // La préparation maximale borne le plat : une entrée ou un dessert se
  // préparent souvent à l'avance, et les borner viderait leurs listes.
  if (
    role === "main" &&
    ctx.maxPrepMinutes != null &&
    typeof r.prepTime === "number" &&
    r.prepTime > ctx.maxPrepMinutes
  ) {
    return "prep";
  }
  // Une veille n'est impossible que si le créneau tombe aujourd'hui (ou avant).
  if (typeof r.restTime === "number" && r.restTime >= REST_EVE_MINUTES && ctx.date <= opts.today) {
    return "rest";
  }
  if (isLowRated(opts.ratings?.get(r.id))) return "rating";
  if (ctx.dismissedIds.has(r.id)) return "dismissed";
  if (opts.inCycle.has(r.id)) return "in_cycle";
  return null;
}

/** 1 si pas servie dans la fenêtre ; sinon jours / 90, entre 0,1 et 1. */
export function freshnessScore(daysSinceServed: number | null): number {
  if (daysSinceServed == null) return 1;
  return Math.min(1, Math.max(FRESHNESS_FLOOR, daysSinceServed / HISTORY_DAYS));
}

/** Un refus de l'appelant : date du dernier, et combien depuis le premier encore actif. */
export interface RefusalEntry {
  refusedAtMs: number;
  count: number;
}

/**
 * Vrai tant que le dernier refus a 21 jours ou moins, et n'est pas daté de
 * plus d'un jour dans le futur.
 */
export function isRefusalActive(entry: RefusalEntry, nowMs: number): boolean {
  const age = nowMs - entry.refusedAtMs;
  return (
    age <= REFUSAL_PENALTY_DAYS * 86_400_000 && age >= -REFUSAL_FUTURE_TOLERANCE_DAYS * 86_400_000
  );
}

/**
 * Facteur de refus : 1 sans refus actif, 0,5 dans les 21 jours, 0,25 à partir
 * de 3 refus. Jamais 0 : une recette refusée reste tirable.
 */
export function refusalFactor(entry: RefusalEntry | null | undefined, nowMs: number): number {
  if (!entry || !isRefusalActive(entry, nowMs)) return 1;
  return entry.count >= REFUSAL_REPEAT_THRESHOLD ? REFUSAL_REPEAT_FACTOR : REFUSAL_FACTOR;
}

/**
 * Lit le document des refus, données non fiables : écrit par le client.
 *
 * Une entrée sans date lisible est ignorée ; un compte illisible vaut un
 * refus. Les entrées expirées, ou datées de plus d'un jour dans le futur,
 * sont ignorées ; au plus
 * `REFUSAL_MAX_ENTRIES`, les plus récentes.
 */
export function readRefusals(raw: unknown, nowMs: number): Map<string, RefusalEntry> {
  const out: Array<[string, RefusalEntry]> = [];
  const entries =
    raw != null && typeof raw === "object" ? (raw as Record<string, unknown>).entries : null;
  if (entries == null || typeof entries !== "object" || Array.isArray(entries)) return new Map();
  for (const [id, value] of Object.entries(entries as Record<string, unknown>)) {
    if (!id || value == null || typeof value !== "object") continue;
    const v = value as Record<string, unknown>;
    const at = v.refused_at as { toMillis?: unknown } | null | undefined;
    const ms = at != null && typeof at.toMillis === "function" ? Number(at.toMillis()) : NaN;
    if (!Number.isFinite(ms)) continue;
    const count =
      typeof v.count === "number" && Number.isInteger(v.count) && v.count >= 1 ? v.count : 1;
    const entry = { refusedAtMs: ms, count };
    if (isRefusalActive(entry, nowMs)) out.push([id, entry]);
  }
  out.sort((a, b) => b[1].refusedAtMs - a[1].refusedAtMs);
  return new Map(out.slice(0, REFUSAL_MAX_ENTRIES));
}

/** Facteur de la note personnelle : 0 (exclue), 0,5, 1 ou 1,5. */
export function ratingFactor(rating: number | null | undefined): number {
  const n = readRating(rating);
  if (n == null) return 1;
  if (n <= RATING_EXCLUDE_MAX) return 0;
  if (n <= RATING_LOW_MAX) return RATING_LOW_FACTOR;
  if (n >= RATING_HIGH_MIN) return RATING_HIGH_FACTOR;
  return 1;
}

export function candidateWeight(args: {
  daysSinceServed: number | null;
  reheatSlot: boolean;
  reheatFriendly: boolean;
  /** Fois où cette protéine est déjà posée dans le cycle ("inconnue" : 0). */
  proteinRepeats: number;
  rating?: number | null;
  /** Facteur de refus (`refusalFactor`), 1 sans refus. */
  refusalFactor?: number;
  /** Même féculent qu'un créneau voisin (`isStarchRepeat`). */
  starchRepeat?: boolean;
}): number {
  return (
    freshnessScore(args.daysSinceServed) *
    (args.reheatSlot && args.reheatFriendly ? REHEAT_BONUS : 1) *
    Math.pow(PROTEIN_REPEAT_FACTOR, Math.max(0, args.proteinRepeats)) *
    ratingFactor(args.rating) *
    (args.refusalFactor ?? 1) *
    (args.starchRepeat ? STARCH_REPEAT_FACTOR : 1)
  );
}

/**
 * Ordre aléatoire pondéré sans remise (Efraimidis–Spirakis : clé = u^(1/w),
 * tri décroissant). Rend toute la liste : la tête part au modèle, la queue
 * sert « Autre suggestion ». Un poids nul passe en dernier, dans l'ordre
 * d'entrée.
 */
export function weightedOrder<T>(items: readonly T[], weightOf: (t: T) => number, rng: Rng): T[] {
  const keyed = items.map((item, index) => {
    const u = Math.max(rng(), Number.MIN_VALUE);
    const w = weightOf(item);
    return { item, index, key: w > 0 && Number.isFinite(w) ? Math.pow(u, 1 / w) : -1 };
  });
  keyed.sort((a, b) => (b.key !== a.key ? b.key - a.key : a.index - b.index));
  return keyed.map((k) => k.item);
}

/**
 * Réordonne la tête pour couvrir au moins `minDistinct` protéines parmi les
 * `k` premiers, si la liste le permet. « inconnue » compte comme une
 * catégorie. Glouton, stable sur le reste.
 */
export function spreadProteins(
  ordered: readonly PlanningRecipeSummary[],
  k: number,
  minDistinct: number,
): PlanningRecipeSummary[] {
  const chosen = new Set<number>();
  const seen = new Set<ProteinKey>();
  const target = Math.min(k, minDistinct);
  for (let i = 0; i < ordered.length && chosen.size < target; i++) {
    const p = proteinOf(ordered[i]);
    if (!seen.has(p)) {
      seen.add(p);
      chosen.add(i);
    }
  }
  for (let i = 0; i < ordered.length && chosen.size < k; i++) chosen.add(i);
  return [...ordered.filter((_, i) => chosen.has(i)), ...ordered.filter((_, i) => !chosen.has(i))];
}

/** YYYY-MM-DD décalé de `days` jours (UTC). */
function shiftDate(date: string, days: number): string {
  const t = Date.parse(`${date.slice(0, 10)}T00:00:00Z`) + days * 86_400_000;
  return new Date(t).toISOString().slice(0, 10);
}

function daysBetween(from: string, to: string): number {
  const a = Date.parse(`${from.slice(0, 10)}T00:00:00Z`);
  const b = Date.parse(`${to.slice(0, 10)}T00:00:00Z`);
  return Math.round((b - a) / 86_400_000);
}

const WEEKDAY_NAMES = ["lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche"];

/**
 * Justification produite par le code, à partir de faits vérifiables :
 * protéine, durée, note personnelle haute, dernier service, répétition.
 * Vide quand aucun fait n'est connu — jamais une phrase générique.
 */
export function codeJustification(
  r: PlanningRecipeSummary,
  ctx: Pick<SlotContext, "date" | "weekday" | "maxPrepMinutes">,
  opts: {
    lastServed: string | null;
    historyAvailable: boolean;
    rating?: number | null;
    repeat?: boolean;
    /** Refus actif de l'appelant : le dire, la recette pèse moins. */
    refused?: boolean;
  },
): string {
  const facts: string[] = [];
  const protein = PROTEIN_LABELS[proteinOf(r)];
  if (protein) facts.push(protein);
  if (typeof r.prepTime === "number" && r.prepTime > 0) {
    facts.push(
      ctx.maxPrepMinutes != null && r.prepTime <= ctx.maxPrepMinutes
        ? `${r.prepTime} min, sous les ${ctx.maxPrepMinutes} min du ${WEEKDAY_NAMES[ctx.weekday - 1]}`
        : `${r.prepTime} min`,
    );
  }
  const rating = readRating(opts.rating);
  if (rating != null && rating >= RATING_HIGH_MIN) facts.push(`notée ${rating}/10`);
  let served: string | null = null;
  if (opts.historyAvailable) {
    if (opts.lastServed == null) {
      served = "pas servie ces 3 derniers mois";
    } else {
      const days = Math.max(0, daysBetween(opts.lastServed, ctx.date));
      served =
        days === 0
          ? "servie aujourd'hui"
          : days === 1
            ? "servie hier"
            : days < 14
              ? `servie il y a ${days} jours`
              : `pas servie depuis ${Math.floor(days / 7)} semaines`;
    }
  }
  if (opts.repeat) served = served ? `${served}, peu d'autres choix` : "peu d'autres choix";
  if (served) facts.push(served);
  if (opts.refused) facts.push("refusée récemment");
  return facts.join(" · ");
}

/**
 * Le redimensionnement se calcule ; il ne se demande plus au modèle. Rien
 * n'est écrit dans la recette : les quantités sont recalculées à l'affichage.
 */
export function resizeOf(
  r: Pick<PlanningRecipeSummary, "portions">,
  ctx: Pick<SlotContext, "targetPortions">,
): { resized: boolean; resizeReason?: string } {
  const portions = typeof r.portions === "number" && r.portions > 0 ? r.portions : null;
  const target = ctx.targetPortions;
  if (portions == null || target == null || portions === target) return { resized: false };
  return { resized: true, resizeReason: `Écrite pour ${portions} parts, servie pour ${target}.` };
}

export interface RankedCandidate {
  recipeId: string;
  /** Faits produits par le code (`codeJustification`). */
  why: string;
  /** Vrai si la recette n'est là que par relâchement d'un filtre. */
  repeat?: boolean;
  /** « Écrite pour 4 parts, servie pour 6. » quand les parts diffèrent. */
  resizeReason?: string;
}

export type RelaxedFilter = "rating" | "in_cycle" | "variety_window";

export interface SlotRanking {
  slot: number;
  /** Profondeur `policy.rankedDepth` ; la tête part au modèle. */
  plats: RankedCandidate[];
  /** Vide si le format n'en demande pas. */
  entrees: RankedCandidate[];
  desserts: RankedCandidate[];
  /** Combien de têtes de liste partent au modèle. */
  sent: { plats: number; entrees: number; desserts: number };
  /** Filtres relâchés pour les plats de ce créneau, dans l'ordre. */
  relaxed: RelaxedFilter[];
  /** Jour de préparation d'un créneau de réchauffage (YYYY-MM-DD). */
  prepDate?: string;
}

export interface PreselectArgs {
  input: PlanningInput;
  /** Corpus après `applyRecentlyServed`. */
  candidates: PlanningRecipeSummary[];
  /** Recettes retirées par la fenêtre de variété : réservoir du relâchement. */
  recentExcluded: PlanningRecipeSummary[];
  /** recipeId → dernière date servie (YYYY-MM-DD), avant le cycle. */
  lastServed: ReadonlyMap<string, string>;
  /** recipeId → note personnelle de l'appelant (0 à 10). */
  ratings: ReadonlyMap<string, number>;
  /** recipeId → refus de l'appelant ; absent : aucun. */
  refusals?: ReadonlyMap<string, RefusalEntry>;
  /** Instant de référence des refus ; absent : midi UTC de `today`. */
  nowMs?: number;
  historyAvailable: boolean;
  policy: PlanningPolicy;
  /** YYYY-MM-DD */
  today: string;
  rng: Rng;
}

const NO_IDS: ReadonlySet<string> = new Set();
const NO_RATINGS: ReadonlyMap<string, number> = new Map();
const NO_REFUSALS: ReadonlyMap<string, RefusalEntry> = new Map();

/**
 * Classe les candidats de chaque créneau à remplir.
 *
 * Créneaux traités dans l'ordre des dates. Les têtes de liste évitent ce qui
 * est déjà en tête d'un autre créneau tant que le corpus le permet. Quand un
 * créneau n'a aucun plat admissible, les filtres se relâchent dans cet ordre :
 * « déjà au cycle », puis « fenêtre de variété ». La note personnelle ne se
 * relâche que si tous les plats du corpus sont mal notés ; le rôle, la durée,
 * le repos et les écartés ne se relâchent jamais.
 */
export function preselect(args: PreselectArgs): SlotRanking[] {
  const { input, candidates, recentExcluded, lastServed, ratings, policy, today, rng } = args;
  const refusals = args.refusals ?? NO_REFUSALS;
  const nowMs = args.nowMs ?? Date.parse(`${today}T12:00:00Z`);
  const refusalOf = (r: PlanningRecipeSummary) => refusalFactor(refusals.get(r.id), nowMs);
  const corpusById = new Map(input.recipes.map((r) => [r.id, r]));
  const assigned = new Set((input.alreadyAssigned ?? []).map((a) => a.slot));
  const inCycle = new Set((input.alreadyAssigned ?? []).map((a) => a.recipeId));
  const recentIds = new Set(recentExcluded.map((r) => r.id));
  const proteinCounts = new Map<ProteinKey, number>();
  for (const id of inCycle) {
    const r = corpusById.get(id);
    if (!r) continue;
    const p = proteinOf(r);
    if (p !== "inconnue") proteinCounts.set(p, (proteinCounts.get(p) ?? 0) + 1);
  }
  const reserved = new Set<string>();
  const allContexts = slotContexts(input);
  // Féculents posés par date : les recettes déjà assignées, puis le premier
  // plat classé de chaque créneau traité. Lus la veille et le lendemain.
  const starchesByDate = new Map<string, Array<MainStarch | null>>();
  const noteStarch = (date: string, starch: MainStarch | null) => {
    if (starch == null) return;
    starchesByDate.set(date, [...(starchesByDate.get(date) ?? []), starch]);
  };
  for (const a of input.alreadyAssigned ?? []) {
    const ctx = allContexts[a.slot];
    const r = corpusById.get(a.recipeId);
    if (ctx && r) noteStarch(ctx.date, starchOf(r));
  }
  const neighbourStarches = (date: string): Array<MainStarch | null> => [
    ...(starchesByDate.get(shiftDate(date, -1)) ?? []),
    ...(starchesByDate.get(shiftDate(date, 1)) ?? []),
  ];
  const contexts = allContexts
    .filter((c) => !assigned.has(c.slot))
    .sort((a, b) => (a.date !== b.date ? (a.date < b.date ? -1 : 1) : a.slot - b.slot));

  const rank = (
    ctx: SlotContext,
    role: CandidateRole,
    headSize: number,
    depth: number,
  ): { list: RankedCandidate[]; sent: number; relaxed: RelaxedFilter[] } => {
    const relaxed: RelaxedFilter[] = [];
    const ofRole = [...candidates, ...recentExcluded].filter((r) => roleFits(r, ctx.format, role));
    const ratingRelaxed = ofRole.length > 0 && ofRole.every((r) => isLowRated(ratings.get(r.id)));
    if (ratingRelaxed) relaxed.push("rating");
    const ratingsUsed = ratingRelaxed ? NO_RATINGS : ratings;
    const admit = (pool: PlanningRecipeSummary[], cycle: ReadonlySet<string>) =>
      pool.filter(
        (r) =>
          hardFilterReason(r, ctx, role, { inCycle: cycle, today, ratings: ratingsUsed }) == null,
      );

    let admissible = admit(candidates, inCycle);
    if (admissible.length === 0) {
      relaxed.push("in_cycle");
      admissible = admit(candidates, NO_IDS);
    }
    if (admissible.length === 0) {
      relaxed.push("variety_window");
      admissible = admit([...candidates, ...recentExcluded], NO_IDS);
    }
    const isRepeat = (r: PlanningRecipeSummary) =>
      inCycle.has(r.id) || recentIds.has(r.id) || (ratingRelaxed && isLowRated(ratings.get(r.id)));

    const daysOf = (r: PlanningRecipeSummary): number | null => {
      const last = lastServed.get(r.id);
      return last ? Math.max(0, daysBetween(last, ctx.date)) : null;
    };
    const neighbours = role === "main" ? neighbourStarches(ctx.date) : [];
    const weightOf = (r: PlanningRecipeSummary) => {
      const p = proteinOf(r);
      return candidateWeight({
        starchRepeat: isStarchRepeat(starchOf(r), neighbours),
        daysSinceServed: daysOf(r),
        reheatSlot: ctx.kind === "reheat",
        reheatFriendly: isReheatFriendly(r),
        proteinRepeats: role === "main" && p !== "inconnue" ? (proteinCounts.get(p) ?? 0) : 0,
        rating: ratingRelaxed ? null : ratings.get(r.id),
        refusalFactor: refusalOf(r),
      });
    };
    const ordered = weightedOrder(admissible, weightOf, rng);
    const fresh = ordered.filter((r) => !reserved.has(r.id));
    const shared = ordered.filter((r) => reserved.has(r.id));
    const list =
      role === "main"
        ? [...spreadProteins(fresh, headSize, MIN_DISTINCT_PROTEINS), ...shared]
        : [...fresh, ...shared];
    const head = list.slice(0, headSize);
    for (const r of head) reserved.add(r.id);
    if (role === "main" && list.length > 0) noteStarch(ctx.date, starchOf(list[0]));
    return {
      list: list.slice(0, Math.max(depth, headSize)).map((r) => {
        const repeat = isRepeat(r);
        const resize = role === "main" ? resizeOf(r, ctx) : { resized: false };
        return {
          recipeId: r.id,
          why: codeJustification(r, ctx, {
            lastServed: lastServed.get(r.id) ?? null,
            historyAvailable: args.historyAvailable,
            rating: ratings.get(r.id),
            repeat,
            refused: refusalOf(r) < 1,
          }),
          ...(repeat ? { repeat: true } : {}),
          ...(resize.resizeReason ? { resizeReason: resize.resizeReason } : {}),
        };
      }),
      sent: head.length,
      relaxed,
    };
  };

  return contexts.map((ctx) => {
    const plats = rank(ctx, "main", policy.platsPerSlot, policy.rankedDepth);
    const entrees = ctx.format.wantsStarter
      ? rank(ctx, "starter", policy.startersPerSlot, policy.startersPerSlot)
      : { list: [], sent: 0, relaxed: [] };
    const desserts = ctx.format.wantsDessert
      ? rank(ctx, "dessert", policy.dessertsPerSlot, policy.dessertsPerSlot)
      : { list: [], sent: 0, relaxed: [] };
    const prepDate =
      ctx.kind === "reheat" && input.batchCookingDay != null
        ? computePrepDate(ctx.date, input.batchCookingDay)
        : undefined;
    return {
      slot: ctx.slot,
      plats: plats.list,
      entrees: entrees.list,
      desserts: desserts.list,
      sent: { plats: plats.sent, entrees: entrees.sent, desserts: desserts.sent },
      relaxed: plats.relaxed,
      ...(prepDate ? { prepDate } : {}),
    };
  });
}

/** Un créneau ne part au modèle que s'il y a un choix à faire. */
export function needsModel(ranking: SlotRanking): boolean {
  return ranking.sent.plats > 1 || ranking.sent.entrees > 1 || ranking.sent.desserts > 1;
}

interface ValidateArgs {
  /** Tableau parsé de la réponse du modèle, éléments non fiables ; `null` sans réponse. */
  raw: unknown;
  rankings: SlotRanking[];
  input: PlanningInput;
  corpusById: ReadonlyMap<string, PlanningRecipeSummary>;
  /** Créneaux envoyés au modèle ; absent : tous. */
  sentSlots?: ReadonlySet<number>;
}

/**
 * Lit les choix du modèle contre les listes envoyées.
 *
 * Un `recipe_id` hors de la tête de liste du créneau, ou déjà pris dans le
 * cycle, est remplacé par le premier candidat libre de la liste (source
 * `code`). Même règle pour l'entrée et le dessert. Un créneau absent de la
 * réponse reçoit aussi le premier candidat. `rejected` compte ces
 * remplacements sur les créneaux envoyés. Les créneaux non envoyés sont
 * remplis par le code en premier, sans compter de rejet.
 */
export function validateModelChoices(args: ValidateArgs): {
  slots: PlanningSlotResult[];
  rejected: number;
} {
  const { rankings, input, corpusById } = args;
  const contexts = slotContexts(input);
  const entries = new Map<number, Record<string, unknown>>();
  if (Array.isArray(args.raw)) {
    for (const e of args.raw) {
      if (!e || typeof e !== "object") continue;
      const o = e as Record<string, unknown>;
      if (typeof o.slot === "number" && !entries.has(o.slot)) entries.set(o.slot, o);
    }
  }
  const asId = (v: unknown): string | null =>
    typeof v === "string" && v.trim().length > 0 ? v.trim() : null;
  const isSent = (slot: number) => (args.sentSlots ? args.sentSlots.has(slot) : true);
  const used = new Set((input.alreadyAssigned ?? []).map((a) => a.recipeId));
  const free = (c: RankedCandidate) => !used.has(c.recipeId) || c.repeat === true;
  const proteinById = (id: string): ProteinKey => {
    const r = corpusById.get(id);
    return r ? proteinOf(r) : "inconnue";
  };
  const firstFree = (list: RankedCandidate[], avoid: ProteinKey | null) =>
    (avoid && avoid !== "inconnue"
      ? list.find((c) => free(c) && proteinById(c.recipeId) !== avoid)
      : undefined) ?? list.find(free);

  const ordered = [
    ...rankings.filter((r) => !isSent(r.slot)),
    ...rankings.filter((r) => isSent(r.slot)),
  ];
  const results: PlanningSlotResult[] = [];
  let rejected = 0;
  let lastProtein: ProteinKey | null = null;

  for (const ranking of ordered) {
    const ctx = contexts[ranking.slot];
    if (!ctx || ranking.plats.length === 0) continue;
    const sent = isSent(ranking.slot);
    const e = sent ? entries.get(ranking.slot) : undefined;

    const pick = (
      list: RankedCandidate[],
      head: number,
      wanted: string | null,
      avoid: ProteinKey | null,
    ): { candidate: RankedCandidate | undefined; fromModel: boolean } => {
      const fromModel =
        wanted != null
          ? list.slice(0, head).find((c) => c.recipeId === wanted && free(c))
          : undefined;
      if (fromModel) return { candidate: fromModel, fromModel: true };
      return { candidate: firstFree(list, avoid), fromModel: false };
    };

    const main = pick(ranking.plats, ranking.sent.plats, asId(e?.recipe_id), lastProtein);
    if (!main.candidate) continue;
    if (sent && !main.fromModel) rejected++;
    used.add(main.candidate.recipeId);
    lastProtein = proteinById(main.candidate.recipeId);

    let starterId: string | undefined;
    if (ctx.format.wantsStarter && ranking.entrees.length > 0) {
      const s = pick(ranking.entrees, ranking.sent.entrees, asId(e?.starter_id), null);
      if (s.candidate) {
        starterId = s.candidate.recipeId;
        used.add(starterId);
        if (sent && !s.fromModel) rejected++;
      }
    }
    let dessertId: string | undefined;
    if (ctx.format.wantsDessert && ranking.desserts.length > 0) {
      const d = pick(ranking.desserts, ranking.sent.desserts, asId(e?.dessert_id), null);
      if (d.candidate) {
        dessertId = d.candidate.recipeId;
        used.add(dessertId);
        if (sent && !d.fromModel) rejected++;
      }
    }

    const recipe = corpusById.get(main.candidate.recipeId);
    const resize = recipe ? resizeOf(recipe, ctx) : { resized: false };
    let prepDate: string | undefined;
    if (ctx.kind === "reheat" && input.batchCookingDay != null) {
      prepDate = computePrepDate(ctx.date, input.batchCookingDay);
    }
    results.push({
      slot: ranking.slot,
      recipeId: main.candidate.recipeId,
      ...(starterId ? { starterId } : {}),
      ...(dessertId ? { dessertId } : {}),
      ...(main.candidate.why ? { justification: main.candidate.why } : {}),
      resized: resize.resized,
      ...(resize.resizeReason ? { resizeReason: resize.resizeReason } : {}),
      ...(prepDate ? { prepDate } : {}),
      source: main.fromModel ? "model" : "code",
      ...(main.candidate.repeat ? { repeat: true } : {}),
    });
  }
  results.sort((a, b) => a.slot - b.slot);
  return { slots: results, rejected };
}

/** Remplissage par le code : premier candidat libre de chaque liste, sans modèle. */
export function codeFill(args: Omit<ValidateArgs, "raw" | "sentSlots">): PlanningSlotResult[] {
  return validateModelChoices({ ...args, raw: null, sentSlots: NO_SLOTS }).slots;
}

const NO_SLOTS: ReadonlySet<number> = new Set();

/** Jetons d'entrée estimés depuis la longueur du prompt (prudent : 3 caractères par jeton). */
export function estimateInputTokens(promptChars: number): number {
  return Math.ceil(Math.max(0, promptChars) / 3);
}

/**
 * Coût plafond d'un appel, calculé sur la grille reçue en argument : aucun
 * prix dans le code. Sur Gemini, la sortie n'est pas bornée par `maxTokens` :
 * l'appelant passe `maxTokens + plafond de raisonnement`.
 */
export function estimateCallCeilingUsd(args: {
  model: string;
  promptChars: number;
  maxOutputTokens: number;
  table: Record<string, AiModelPricing>;
  at: Date;
}): number {
  return estimateAiCostUsd({
    model: args.model,
    inputTokens: estimateInputTokens(args.promptChars),
    outputTokens: Math.max(0, args.maxOutputTokens),
    table: args.table,
    at: args.at,
  });
}

export type ConceptDenialReason = "unknown" | "expired" | "count" | "cost";

/** État d'une génération, tel que la conception le relit. */
export interface PlanningRunState {
  createdAtMs: number;
  conceptsMax: number;
  conceptsUsed: number;
  costUsd: number;
  /**
   * Coût estimé des conceptions réservées dont le coût réel n'est pas encore
   * reporté. Sans lui, des conceptions lancées en parallèle voyaient toutes le
   * même `costUsd` et passaient ensemble le plafond.
   */
  reservedUsd: number;
  costCapUsd: number | null;
}

/**
 * Combien de conceptions automatiques une génération ouvre : le maximum de la
 * politique, borné par le nombre de créneaux restés vides. Une génération qui
 * a tout rempli n'en ouvre aucune.
 */
export function conceptsAllowance(args: {
  policyMax: number;
  slots: number;
  filled: number;
}): number {
  return Math.max(0, Math.min(args.policyMax, args.slots - args.filled));
}

/**
 * Une conception rattachée à une génération est-elle permise ?
 *
 * Sans taux de change (`costCapUsd` nul) ou sans grille (`estimateUsd` nul),
 * le plafond en euros ne s'applique pas — aucun chiffre n'est inventé — et le
 * plafond de nombre reste seul actif.
 */
export function planningConceptDecision(args: {
  run: PlanningRunState | null;
  nowMs: number;
  estimateUsd: number | null;
}): { ok: true } | { ok: false; reason: ConceptDenialReason; message: string } {
  const { run } = args;
  if (!run) {
    return {
      ok: false,
      reason: "unknown",
      message: "Génération introuvable : relancez la génération du planning.",
    };
  }
  if (args.nowMs - run.createdAtMs > CONCEPT_RUN_TTL_MS) {
    return {
      ok: false,
      reason: "expired",
      message:
        "Cette génération a plus de 6 heures : utilisez « Concevoir avec l'IA » sur le créneau.",
    };
  }
  if (run.conceptsUsed >= run.conceptsMax) {
    return {
      ok: false,
      reason: "count",
      message: `${run.conceptsMax} recette${run.conceptsMax > 1 ? "s" : ""} conçue${run.conceptsMax > 1 ? "s" : ""}, c'est le maximum par génération.`,
    };
  }
  if (
    run.costCapUsd != null &&
    args.estimateUsd != null &&
    run.costUsd + run.reservedUsd + args.estimateUsd > run.costCapUsd
  ) {
    return {
      ok: false,
      reason: "cost",
      message: "Cette conception dépasserait le plafond de coût de la génération.",
    };
  }
  return { ok: true };
}

/** Format d'un montant en euros pour un message : « 0,50 € ». */
export function formatEur(amount: number): string {
  return `${amount.toFixed(2).replace(".", ",")} €`;
}

const NOTICE_FAILED = "L'IA n'a pas répondu. Kass'Dalle a choisi les plats selon vos contraintes.";
const NOTICE_DAILY_CAP =
  "Votre plafond d'IA du jour est atteint. Kass'Dalle a choisi les plats selon vos contraintes. Rien n'a été facturé.";

export function generationCapNotice(capEur: number): string {
  return `Cette génération aurait coûté plus de ${formatEur(capEur)} en IA. Kass'Dalle a choisi les plats selon vos contraintes. Rien n'a été facturé.`;
}

/** Une ligne compacte par recette candidate, pour la section RECETTES. */
function describeCandidate(r: PlanningRecipeSummary): string {
  const attrs: string[] = [];
  if (r.prepTime) attrs.push(`${r.prepTime} min prép`);
  if (r.cookTime) attrs.push(`${r.cookTime} min cuisson`);
  if (r.restTime) attrs.push(`${formatRepos(r.restTime)} de repos avant de servir`);
  if (r.dishTypes && r.dishTypes.length > 0) attrs.push(`type : ${r.dishTypes.join(", ")}`);
  const protein = parseMainProtein(r.mainProtein);
  if (protein) attrs.push(`protéine : ${PROTEIN_LABELS[protein]}`);
  const starch = starchOf(r);
  if (starch) attrs.push(`féculent : ${STARCH_LABELS[starch]}`);
  if (r.cuisines && r.cuisines.length > 0) attrs.push(`cuisine : ${r.cuisines.join(", ")}`);
  if (r.mainIngredients && r.mainIngredients.length > 0) {
    attrs.push(`ingrédients : ${r.mainIngredients.slice(0, 6).join(", ")}`);
  }
  return `${r.id} | ${r.titre}${attrs.length ? " | " + attrs.join(" | ") : ""}`;
}

/**
 * Prompt compact : chaque candidat décrit une fois, puis les identifiants
 * proposés par créneau. Les deux listes sont mélangées : la position d'une
 * recette ne dépend ni de l'ordre du corpus ni de sa note.
 */
export function buildPlanningPrompt(args: {
  input: PlanningInput;
  rankings: SlotRanking[];
  sentSlots: ReadonlySet<number>;
  corpusById: ReadonlyMap<string, PlanningRecipeSummary>;
  rng: Rng;
}): { prompt: string; candidateIds: string[] } {
  const { input, rankings, sentSlots, corpusById, rng } = args;
  const contexts = slotContexts(input);
  const shuffle = (ids: string[]) => weightedOrder(ids, () => 1, rng);
  const sent = rankings.filter((r) => sentSlots.has(r.slot));
  const headIds = (list: RankedCandidate[], n: number) => list.slice(0, n).map((c) => c.recipeId);
  const unique = new Set<string>();
  for (const r of sent) {
    for (const id of [
      ...headIds(r.plats, r.sent.plats),
      ...headIds(r.entrees, r.sent.entrees),
      ...headIds(r.desserts, r.sent.desserts),
    ]) {
      unique.add(id);
    }
  }
  const candidateIds = shuffle([...unique]);

  const lines: string[] = [];
  lines.push(
    "Tu composes un planning de repas. Pour chaque créneau ci-dessous, choisis une recette parmi les identifiants listés pour CE créneau, et aucun autre.",
  );
  lines.push(
    "Les candidats respectent déjà le rôle, la durée de préparation et la variété récente. Ton travail : varier les protéines et les féculents d'un jour à l'autre, et suivre les préférences.",
  );
  lines.push("");
  lines.push("=== RECETTES (id | titre | détails) ===");
  for (const id of candidateIds) {
    const r = corpusById.get(id);
    if (r) lines.push(describeCandidate(r));
  }
  lines.push("");

  if (input.globalConstraints.trim()) {
    lines.push("=== PRÉFÉRENCES GÉNÉRALES ===");
    lines.push(input.globalConstraints.trim());
    lines.push("");
  }

  const decided: string[] = [];
  for (const a of input.alreadyAssigned ?? []) {
    const r = corpusById.get(a.recipeId);
    if (!r) continue;
    decided.push(
      a.slot >= 0 && a.slot < input.slotDates.length
        ? `- Slot ${a.slot} : ${r.titre}`
        : `- ${r.titre}`,
    );
  }
  for (const r of rankings) {
    if (sentSlots.has(r.slot) || r.plats.length === 0) continue;
    const t = corpusById.get(r.plats[0].recipeId);
    if (t) decided.push(`- Slot ${r.slot} : ${t.titre}`);
  }
  if (decided.length > 0) {
    lines.push("=== DÉJÀ AU MENU DE CE CYCLE (à ne pas répéter) ===");
    lines.push(...decided);
    lines.push("");
  }

  const recent = [...(input.recentlyServed ?? [])]
    .filter((m) => typeof m.date === "string" && m.date.length > 0)
    .sort((a, b) => (a.date < b.date ? 1 : a.date > b.date ? -1 : 0))
    .slice(0, 5);
  if (recent.length > 0) {
    lines.push("=== DERNIERS REPAS SERVIS AVANT CE CYCLE ===");
    for (const m of recent) {
      const titre = m.titre?.trim() || corpusById.get(m.recipeId)?.titre;
      if (titre) lines.push(`- ${m.date} : ${titre}`);
    }
    lines.push(
      "Enchaîne avec eux : pas la même protéine principale ni le même féculent que les deux derniers.",
    );
    lines.push("");
  }

  if (input.batchCookingDay != null) {
    lines.push("=== BATCH COOKING ===");
    lines.push(
      `Le jour de batch cooking (jour n°${input.batchCookingDay}, 1 = lundi) sert un repas normal. Un créneau « RÉCHAUFFAGE » sert un plat préparé un autre jour : préfère un plat qui se réchauffe, et pas le même que celui du jour de batch.`,
    );
    lines.push("");
  }

  lines.push("=== CRÉNEAUX ===");
  for (const r of sent) {
    const ctx = contexts[r.slot];
    if (!ctx) continue;
    const tags = [`FORMAT : ${ctx.format.label}`];
    if (ctx.kind === "batch") tags.push("JOUR DE BATCH COOKING");
    if (ctx.kind === "reheat") tags.push("RÉCHAUFFAGE");
    let line = `Slot ${r.slot} — ${ctx.date} (${WEEKDAY_NAMES[ctx.weekday - 1]}) [${tags.join(" + ")}]`;
    const notes = constraintForSlot(input, r.slot)?.notes?.trim();
    if (notes) line += ` [PRÉFÉRENCES DU JOUR : ${notes}]`;
    lines.push(line);
    lines.push(`  PLATS : ${shuffle(headIds(r.plats, r.sent.plats)).join(", ")}`);
    if (r.sent.entrees > 0) {
      lines.push(`  ENTRÉES : ${shuffle(headIds(r.entrees, r.sent.entrees)).join(", ")}`);
    }
    if (r.sent.desserts > 0) {
      lines.push(`  DESSERTS : ${shuffle(headIds(r.desserts, r.sent.desserts)).join(", ")}`);
    }
  }
  lines.push("");
  lines.push("=== RÉPONSE ===");
  lines.push(
    'Réponds UNIQUEMENT avec un tableau JSON, une entrée par créneau listé : [{"slot":0,"recipe_id":"…","starter_id":"…","dessert_id":"…"}]',
  );
  lines.push(
    '- "recipe_id" vient de la liste PLATS du créneau ; "starter_id" de sa liste ENTRÉES et "dessert_id" de sa liste DESSERTS, seulement quand le créneau en a une.',
  );
  lines.push("- Une recette ne sert qu'une fois dans le cycle.");
  lines.push(
    "- Pas la même protéine principale ni le même féculent dominant deux jours de suite, tant qu'une alternative existe.",
  );
  lines.push(
    "- Le nombre de parts à servir ne guide pas ton choix : les quantités sont recalculées à l'affichage.",
  );
  lines.push("- N'écris rien d'autre que le tableau.");
  return { prompt: lines.join("\n"), candidateIds };
}

/** Ce que rend une suggestion de cycle. */
export interface PlanningSuggestion {
  slots: PlanningSlotResult[];
  /** Recettes retirées du corpus par la fenêtre de variété, pour le dire à l'écran. */
  excludedRecentIds: string[];
  /** Listes classées par créneau, pour « Autre suggestion » côté client. */
  rankings: SlotRanking[];
  modelStatus: "ok" | "partial" | "failed" | "budget" | "skipped";
  /** Phrase prête à afficher quand le modèle n'a pas choisi (`failed`, `budget`). */
  notice: string | null;
  stats: {
    corpus: number;
    candidatesSent: number;
    durationMs: number;
    rejectedChoices: number;
    historyAvailable: boolean;
  };
  /** L'appel de modèle, s'il a eu lieu. */
  modelCall: { provider: AiProvider; model: string; costUsd: number | null } | null;
}

/** Ce que la génération reçoit de l'appelant, hors entrée du client. */
export interface PlanningDeps {
  policy: PlanningPolicy;
  lastServed: ReadonlyMap<string, string>;
  historyAvailable: boolean;
  ratings: ReadonlyMap<string, number>;
  /** Refus actifs de l'appelant (`readRefusals`). */
  refusals: ReadonlyMap<string, RefusalEntry>;
  /** Instant de référence des refus. */
  nowMs: number;
  /** YYYY-MM-DD */
  today: string;
  rng: Rng;
  /** Rattache les lignes `ai_usage` de la génération ; `null` en mode code. */
  runId: string | null;
  /** Plafond de la génération en dollars ; `null` sans taux de change utilisable. */
  costCapUsd: number | null;
  /** Coût plafond de l'appel pour ce prompt ; `null` si la grille est illisible. */
  estimateCeilingUsd: (promptChars: number) => Promise<number | null>;
}

/**
 * Génère un cycle : présélection par le code, un appel de modèle qui tranche
 * entre les têtes de liste, validation, remplissage par le code de ce que le
 * modèle n'a pas choisi.
 *
 * Mode `code` : présélection seule, aucun appel de modèle, aucune ligne
 * `ai_usage`. Le modèle n'est pas appelé non plus quand aucun créneau n'a de
 * choix à faire, quand l'estimation dépasse le plafond de la génération, ou
 * quand le plafond du jour est atteint.
 */
export async function suggestMealPlan(
  apiKey: string,
  input: PlanningInput,
  ctx: ModelCallContext,
  deps: PlanningDeps,
): Promise<PlanningSuggestion> {
  const startedAt = Date.now();
  const mode = input.mode ?? "model";
  const corpusById = new Map(input.recipes.map((r) => [r.id, r]));
  const slotsToFill = Math.max(1, input.slotDates.length - (input.alreadyAssigned?.length ?? 0));
  const { candidates, excludedIds } = applyRecentlyServed(
    input.recipes,
    input.recentlyServed ?? [],
    slotsToFill,
  );
  const excluded = new Set(excludedIds);
  const rankings =
    input.recipes.length === 0
      ? []
      : preselect({
          input,
          candidates,
          recentExcluded: input.recipes.filter((r) => excluded.has(r.id)),
          lastServed: deps.lastServed,
          ratings: deps.ratings,
          refusals: deps.refusals,
          nowMs: deps.nowMs,
          historyAvailable: deps.historyAvailable,
          policy: deps.policy,
          today: deps.today,
          rng: deps.rng,
        });
  const sentSlots = new Set(rankings.filter(needsModel).map((r) => r.slot));

  let modelStatus: PlanningSuggestion["modelStatus"] = "skipped";
  let notice: string | null = null;
  let slots: PlanningSlotResult[] | null = null;
  let rejected = 0;
  let candidatesSent = 0;
  let modelCall: PlanningSuggestion["modelCall"] = null;
  const logCtx = {
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN" as const,
    feature: "planning",
  };

  if (mode === "model" && sentSlots.size > 0) {
    const { prompt, candidateIds } = buildPlanningPrompt({
      input,
      rankings,
      sentSlots,
      corpusById,
      rng: deps.rng,
    });
    candidatesSent = candidateIds.length;
    const ceiling = await deps.estimateCeilingUsd(prompt.length);
    if (deps.costCapUsd != null && ceiling != null && ceiling > deps.costCapUsd) {
      modelStatus = "budget";
      notice = generationCapNotice(deps.policy.costCapEurPerGeneration);
      await logWarn({
        ...logCtx,
        message: "Planning — plafond de la génération : appel évité, choix par le code",
        extra: { runId: deps.runId, ceilingUsd: ceiling, capUsd: deps.costCapUsd },
      });
    } else {
      try {
        const result = await callModel({
          parts: [textPart(prompt)],
          ctx: { ...ctx, feature: "planning", timeoutMs: 2 * 60 * 1000 },
          maxTokens: PLANNING_MAX_TOKENS,
          ...(deps.runId
            ? { usageMeta: { entityType: "planning_run", entityId: deps.runId } }
            : {}),
        });
        modelCall = {
          provider: result.provider,
          model: result.model,
          costUsd: result.recordedCostUsd ?? null,
        };
        const text = result.text.trim();
        let parsed: unknown = null;
        try {
          parsed = text ? JSON.parse(extractJsonArray(text)) : null;
        } catch (e) {
          await logError({
            ...logCtx,
            message: "Planning — réponse du modèle illisible, choix par le code",
            geminiStatus: "ERROR",
            errorDescription: e instanceof Error ? e.message : String(e),
            extra: {
              runId: deps.runId,
              stopReason: result.stopReason ?? null,
              responsePreview: text.slice(0, 500),
            },
          });
        }
        if (!Array.isArray(parsed)) {
          modelStatus = "failed";
          notice = NOTICE_FAILED;
          if (!text) {
            await logError({
              ...logCtx,
              message: "Planning — réponse vide du modèle, choix par le code",
              extra: { runId: deps.runId, stopReason: result.stopReason ?? null },
            });
          }
        } else {
          const validated = validateModelChoices({
            raw: parsed,
            rankings,
            input,
            corpusById,
            sentSlots,
          });
          slots = validated.slots;
          rejected = validated.rejected;
          modelStatus = rejected > 0 ? "partial" : "ok";
          if (rejected > 0) {
            await logWarn({
              ...logCtx,
              message: "Planning — choix du modèle hors des listes, remplacés par le code",
              extra: { runId: deps.runId, rejected },
            });
          }
        }
      } catch (err) {
        if (err instanceof BudgetExceededError) {
          modelStatus = "budget";
          notice = NOTICE_DAILY_CAP;
          await logWarn({
            ...logCtx,
            message: "Planning — plafond du jour atteint, choix par le code",
            errorDescription: err.message,
            extra: { runId: deps.runId },
          });
        } else {
          modelStatus = "failed";
          notice = NOTICE_FAILED;
          await logError({
            ...logCtx,
            message: "Planning — appel du modèle en échec, choix par le code",
            errorDescription: err instanceof Error ? err.message : String(err),
            extra: { runId: deps.runId },
          });
        }
      }
    }
  }

  if (slots == null) slots = codeFill({ rankings, input, corpusById });
  const durationMs = Date.now() - startedAt;
  const stats = {
    corpus: input.recipes.length,
    candidatesSent,
    durationMs,
    rejectedChoices: rejected,
    historyAvailable: deps.historyAvailable,
  };
  await logInfo({
    ...logCtx,
    message: "Planning — génération",
    executionTimeMs: durationMs,
    extra: {
      ...stats,
      mode,
      modelStatus,
      slots: input.slotDates.length,
      filled: slots.length,
      runId: deps.runId,
    },
  });
  return {
    slots,
    excludedRecentIds: excludedIds,
    rankings,
    modelStatus,
    notice,
    stats,
    modelCall,
  };
}

/**
 * Génère une recette de toutes pièces (conception IA) qui respecte les contraintes
 * d'un slot spécifique. Utilisé en fallback quand aucune recette existante ne convient.
 */
export function buildConceptPrompt(input: RecipeConceptInput): string {
  const lines: string[] = [];
  const requestedTitre = (input.requestedDish?.titre ?? "").trim().slice(0, 200);
  const requestedDescription = (input.requestedDish?.description ?? "").trim().slice(0, 600);
  if (requestedTitre) {
    lines.push(
      "Tu es un chef cuisinier expert. Rédige la recette du plat demandé ci-dessous, réaliste et faisable à la maison, en respectant les contraintes qui suivent.",
    );
    lines.push("");
    lines.push("=== PLAT DEMANDÉ ===");
    lines.push(`Titre : ${requestedTitre}`);
    if (requestedDescription) lines.push(`Description : ${requestedDescription}`);
    lines.push(
      "Écris CETTE recette, sous ce titre. Ne propose pas un autre plat, même si les contraintes s'y prêteraient mieux : la personne l'a choisi.",
    );
    lines.push("");
  } else {
    lines.push(
      "Tu es un chef cuisinier expert. Crée une recette originale et réaliste qui respecte exactement les contraintes suivantes.",
    );
    lines.push(
      "La recette doit être faisable à la maison, délicieuse et adaptée à un repas familial.",
    );
    lines.push("");
  }

  if (input.globalConstraints.trim()) {
    lines.push("=== PRÉFÉRENCES GÉNÉRALES ===");
    lines.push(input.globalConstraints.trim());
    lines.push("");
  }

  if (input.dayConstraint) {
    const c = input.dayConstraint;
    const parts: string[] = [];
    if (c.maxPrepMinutes && c.maxPrepMinutes > 0)
      parts.push(`préparation max ${c.maxPrepMinutes}min`);
    if (c.targetPortions && c.targetPortions > 0) parts.push(`${c.targetPortions} parts à servir`);
    if (c.isBatchCooking) parts.push("réchauffage uniquement (plat préparé à l'avance)");
    if (c.notes?.trim()) parts.push(c.notes.trim());
    if (parts.length > 0) {
      lines.push("=== CONTRAINTES DU JOUR ===");
      lines.push(parts.join(", "));
      lines.push("");
    }
  }

  // Ce que le cycle contient déjà. Une contrainte de variété porte sur
  // l'ensemble ; générée créneau par créneau, elle n'a de sens que si chaque
  // appel voit les autres.
  const planned = (input.alreadyPlanned ?? []).map((t) => t.trim()).filter((t) => t.length > 0);
  if (planned.length > 0) {
    lines.push("=== DÉJÀ PRÉVU CETTE SEMAINE — NE PAS RÉPÉTER ===");
    for (const titre of planned) lines.push(`- ${titre}`);
    lines.push("");
    lines.push(
      "VARIÉTÉ IMPÉRATIVE : ta recette doit se distinguer de TOUTES celles ci-dessus — " +
        "par sa protéine principale, par son féculent dominant ET par son style de cuisine. " +
        "Si la liste compte déjà du poulet, propose autre chose ; si elle compte déjà un tajine, " +
        "change de registre. Une semaine de sept plats doit donner l'impression de sept repas " +
        "différents, pas de sept variations du même.",
    );
    lines.push("");
  }

  lines.push("=== FORMAT DE RÉPONSE ===");
  lines.push("Réponds UNIQUEMENT avec un objet JSON valide (sans balises markdown) :");
  lines.push(
    '{"titre": "Nom de la recette", "cooklang": "Contenu Cooklang complet", "justification": "Pourquoi cette recette est adaptée."}',
  );
  lines.push(
    'Le champ "justification" est lu par une personne, dans sa fiche recette : dis en une à ' +
      "deux phrases pourquoi CE plat pour CE jour — la contrainte du jour qu'il satisfait, et ce " +
      "qui le distingue du reste de la semaine.",
  );
  lines.push("");
  lines.push("Règles Cooklang :");
  lines.push(
    // Les clés doivent être celles que `cooklang/parser.ts` lit vraiment.
    // `prepTime` et `cookTime` en camelCase n'en font pas partie : les
    // brouillons du planning sortaient donc sans durées, depuis toujours, sans
    // qu'aucune erreur ne le dise.
    // `portions` est lu par le client à l'enregistrement du brouillon : sans
    // cette ligne, la fiche s'ouvrait sans nombre de parts, et les quantités
    // ne se rapportaient à rien.
    "- Métadonnées en début (une par ligne) : >> portions: N (le nombre de parts pour lequel " +
      "les quantités sont écrites)  >> temps_preparation: XX min  " +
      ">> temps_cuisson: XX min  >> temps_repos: XX min (ou omise si aucun repos)",
  );
  lines.push("- Ingrédients : @nom{quantité%unité}  ex: @farine{200%g}  @oignon{1%}");
  lines.push("- Durées : ~{durée%unité}  ex: ~{15%min}");
  lines.push("- Ustensiles : #nom{}  ex: #casserole{}");

  return lines.join("\n");
}

export async function generateRecipeConcept(
  apiKey: string,
  input: RecipeConceptInput,
  ctx: ModelCallContext,
  opts?: { runId?: string },
): Promise<RecipeConceptResult> {
  const result = await callModel({
    parts: [textPart(buildConceptPrompt(input))],
    ctx: { ...ctx, feature: "planning_concept", timeoutMs: 90 * 1000 },
    maxTokens: PLANNING_CONCEPT_MAX_TOKENS,
    // Rattache le coût de la conception à sa génération, dans `ai_usage`.
    ...(opts?.runId ? { usageMeta: { entityType: "planning_run", entityId: opts.runId } } : {}),
  });
  const costUsd = result.recordedCostUsd ?? null;

  const text = result.text.trim();
  const cleaned = text
    .replace(/^```(?:json)?\s*\n?/, "")
    .replace(/\n?```\s*$/, "")
    .trim();
  try {
    const parsed = JSON.parse(cleaned) as {
      titre?: string;
      cooklang?: string;
      justification?: string;
    };
    return {
      titre: parsed.titre ?? "Recette générée par l'IA",
      cooklang: parsed.cooklang ?? "",
      justification: parsed.justification ?? "Recette créée par l'IA selon les contraintes.",
      costUsd,
    };
  } catch (e) {
    // Le brouillon serait enregistré avec un CookLang vide : le dire, sinon la
    // recette apparaît dans la liste sans un seul ingrédient et sans explication.
    await logError("Conception de recette — réponse du modèle illisible", {
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      geminiStatus: "ERROR",
      feature: "planning_concept",
      errorDescription: e instanceof Error ? e.message : String(e),
      extra: { slotDate: input.slotDate, responsePreview: cleaned.slice(0, 500) },
    });
    return {
      titre: "Recette générée par l'IA",
      cooklang: "",
      justification:
        "L'IA n'a pas renvoyé de recette exploitable. Rien n'a été conçu pour ce créneau.",
      costUsd,
    };
  }
}
