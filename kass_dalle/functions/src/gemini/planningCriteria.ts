/**
 * Critères structurés du planning — vocabulaire, lecture et prédicat.
 *
 * Le texte libre des préférences (préférences générales, note du jour) est
 * traduit par le modèle en critères de ce vocabulaire (`planningConstraints.ts`,
 * poste `planning_constraints`). Le programme les vérifie : au modèle la
 * reconnaissance, au programme la vérification.
 *
 * Deux régimes. Une **exclusion** (allergène, protéine principale, féculent
 * principal) ne se relâche jamais : un service sans candidat reste vide, et
 * l'écran dit pourquoi. Une **préférence** (protéine ou féculent voulus, durée
 * maximale, léger, style voulu) se relâche faute d'autre choix, et l'écran le
 * dit.
 *
 * Un texte peut réserver des critères à un jour de semaine nommé (« le
 * vendredi ») : ils vivent à part (`criteria_by_weekday`) et ne valent que
 * pour les créneaux de ce jour (`criteriaForWeekday`).
 *
 * Logique dupliquée : `lib/features/planning/domain/planning_criteria.dart`
 * rejoue la lecture, la réunion et le prédicat d'exclusion, verrouillés par
 * `test-fixtures/planning_criteria.json`. Le prédicat des préférences est
 * serveur seul : le client n'applique que les exclusions.
 *
 * Pur : ni Firestore, ni réseau, ni appel de modèle.
 */

import { ALLERGEN_KEYS, ALLERGEN_LABELS, type AllergenKey } from "../nutrition/allergens";
import {
  MAIN_PROTEINS,
  MAIN_STARCHES,
  RECIPE_STYLES,
  styleWord,
  type MainProtein,
  type MainStarch,
  type RecipeStyle,
} from "./mealRole";

export type CriterionRegime = "exclusion" | "preference";

export type CriterionKey =
  | "excluded_allergens"
  | "excluded_proteins"
  | "excluded_starches"
  | "wanted_proteins"
  | "wanted_starches"
  | "max_duration"
  | "light"
  | "wanted_styles";

/**
 * Le régime de chaque clé, dans l'ordre du vocabulaire : celui des résultats
 * du prédicat et de `planning_criteria.json`.
 */
export const CRITERION_REGIMES: Readonly<Record<CriterionKey, CriterionRegime>> = {
  excluded_allergens: "exclusion",
  excluded_proteins: "exclusion",
  excluded_starches: "exclusion",
  wanted_proteins: "preference",
  wanted_starches: "preference",
  max_duration: "preference",
  light: "preference",
  wanted_styles: "preference",
};

/** Bornes d'une durée maximale lue, en minutes. Hors bornes : absente. */
export const MAX_DURATION_MIN = 5;
export const MAX_DURATION_MAX = 600;

export interface PlanningCriteria {
  excludedAllergens: AllergenKey[];
  excludedProteins: MainProtein[];
  excludedStarches: MainStarch[];
  wantedProteins: MainProtein[];
  wantedStarches: MainStarch[];
  /** Préparation maximale, en minutes ; `null` sans limite. */
  maxDuration: number | null;
  light: boolean;
  /** Styles voulus : un plat qui porte l'un d'eux suffit. */
  wantedStyles: RecipeStyle[];
}

export const EMPTY_CRITERIA: PlanningCriteria = {
  excludedAllergens: [],
  excludedProteins: [],
  excludedStarches: [],
  wantedProteins: [],
  wantedStarches: [],
  maxDuration: null,
  light: false,
  wantedStyles: [],
};

/** Les valeurs de [raw] qui sont dans [vocabulary], une fois, dans son ordre. */
function vocabularyList<T extends string>(raw: unknown, vocabulary: readonly T[]): T[] {
  if (!Array.isArray(raw)) return [];
  const wanted = new Set(raw.filter((v): v is string => typeof v === "string"));
  return vocabulary.filter((v) => wanted.has(v));
}

function readDuration(raw: unknown): number | null {
  return typeof raw === "number" &&
    Number.isInteger(raw) &&
    raw >= MAX_DURATION_MIN &&
    raw <= MAX_DURATION_MAX
    ? raw
    : null;
}

/** Une valeur exclue quitte la liste voulue : l'exclusion l'emporte. */
function withoutConflicts(c: PlanningCriteria): PlanningCriteria {
  return {
    ...c,
    wantedProteins: c.wantedProteins.filter((p) => !c.excludedProteins.includes(p)),
    wantedStarches: c.wantedStarches.filter((s) => !c.excludedStarches.includes(s)),
  };
}

/**
 * Lit un objet de critères stocké ou rendu par le modèle, en snake_case.
 * Donnée non fiable : une valeur hors vocabulaire est écartée.
 */
export function readPlanningCriteria(raw: unknown): PlanningCriteria {
  if (raw == null || typeof raw !== "object" || Array.isArray(raw)) return { ...EMPTY_CRITERIA };
  const r = raw as Record<string, unknown>;
  return withoutConflicts({
    excludedAllergens: vocabularyList(r.excluded_allergens, ALLERGEN_KEYS),
    excludedProteins: vocabularyList(r.excluded_proteins, MAIN_PROTEINS),
    excludedStarches: vocabularyList(r.excluded_starches, MAIN_STARCHES),
    wantedProteins: vocabularyList(r.wanted_proteins, MAIN_PROTEINS),
    wantedStarches: vocabularyList(r.wanted_starches, MAIN_STARCHES),
    maxDuration: readDuration(r.max_duration),
    light: r.light === true,
    wantedStyles: vocabularyList(r.wanted_styles, RECIPE_STYLES),
  });
}

/** La forme canonique, en snake_case : les huit clés. */
export function planningCriteriaToMap(c: PlanningCriteria): Record<CriterionKey, unknown> {
  return {
    excluded_allergens: [...c.excludedAllergens],
    excluded_proteins: [...c.excludedProteins],
    excluded_starches: [...c.excludedStarches],
    wanted_proteins: [...c.wantedProteins],
    wanted_starches: [...c.wantedStarches],
    max_duration: c.maxDuration,
    light: c.light,
    wanted_styles: [...c.wantedStyles],
  };
}

/**
 * Les critères d'un créneau : préférences générales et note du jour réunies.
 * Listes en union, durée la plus courte, léger si l'un le dit.
 */
export function mergeCriteria(parts: readonly PlanningCriteria[]): PlanningCriteria {
  const union = <T extends string>(pick: (c: PlanningCriteria) => T[], vocabulary: readonly T[]) =>
    vocabularyList(
      parts.flatMap((p) => pick(p)),
      vocabulary,
    );
  const durations = parts.map((p) => p.maxDuration).filter((d): d is number => d != null);
  return withoutConflicts({
    excludedAllergens: union((p) => p.excludedAllergens, ALLERGEN_KEYS),
    excludedProteins: union((p) => p.excludedProteins, MAIN_PROTEINS),
    excludedStarches: union((p) => p.excludedStarches, MAIN_STARCHES),
    wantedProteins: union((p) => p.wantedProteins, MAIN_PROTEINS),
    wantedStarches: union((p) => p.wantedStarches, MAIN_STARCHES),
    maxDuration: durations.length > 0 ? Math.min(...durations) : null,
    light: parts.some((p) => p.light),
    wantedStyles: union((p) => p.wantedStyles, RECIPE_STYLES),
  });
}

/** Jour de semaine lisible : « 1 » (lundi) à « 7 » (dimanche). */
const WEEKDAY_KEY = /^[1-7]$/;

/**
 * Les critères qu'un texte réserve à un jour de semaine, lus dans
 * `criteria_by_weekday` (clés "1" à "7"). Donnée non fiable : une clé hors
 * bornes, une valeur qui n'est pas un objet ou un objet sans critère est
 * écartée. Cas : `weekday_read_cases` de `planning_criteria.json`.
 */
export function readCriteriaByWeekday(raw: unknown): Map<number, PlanningCriteria> {
  const out = new Map<number, PlanningCriteria>();
  if (raw == null || typeof raw !== "object" || Array.isArray(raw)) return out;
  for (const [key, value] of Object.entries(raw as Record<string, unknown>)) {
    if (!WEEKDAY_KEY.test(key)) continue;
    if (value == null || typeof value !== "object" || Array.isArray(value)) continue;
    const c = readPlanningCriteria(value);
    if (!criteriaIsEmpty(c)) out.set(Number(key), c);
  }
  return out;
}

/** La forme stockée : `{ "5": { …les huit clés… } }`, jours croissants. */
export function criteriaByWeekdayToMap(
  byWeekday: ReadonlyMap<number, PlanningCriteria>,
): Record<string, Record<CriterionKey, unknown>> {
  const out: Record<string, Record<CriterionKey, unknown>> = {};
  for (const day of [...byWeekday.keys()].sort((a, b) => a - b)) {
    const c = byWeekday.get(day);
    if (c && !criteriaIsEmpty(c)) out[String(day)] = planningCriteriaToMap(c);
  }
  return out;
}

/**
 * Les critères d'un texte pour un jour : ceux de tous les jours réunis à ceux
 * réservés à [weekday]. Cas : `weekday_cases` de `planning_criteria.json`.
 */
export function criteriaForWeekday(
  criteria: PlanningCriteria,
  byWeekday: ReadonlyMap<number, PlanningCriteria> | undefined,
  weekday: number,
): PlanningCriteria {
  const day = byWeekday?.get(weekday);
  return day ? mergeCriteria([criteria, day]) : criteria;
}

export function hasExclusions(c: PlanningCriteria): boolean {
  return (
    c.excludedAllergens.length > 0 || c.excludedProteins.length > 0 || c.excludedStarches.length > 0
  );
}

/** Vrai si une préférence de texte est posée (protéine, féculent, léger, style). */
export function hasWantedPreferences(c: PlanningCriteria): boolean {
  return (
    c.wantedProteins.length > 0 ||
    c.wantedStarches.length > 0 ||
    c.light ||
    c.wantedStyles.length > 0
  );
}

export function criteriaIsEmpty(c: PlanningCriteria): boolean {
  return !hasExclusions(c) && !hasWantedPreferences(c) && c.maxDuration == null;
}

/** Ce que le prédicat sait d'un élément : un plat, une entrée, un dessert. */
export interface CriteriaItem {
  /** `allergens` de la recette ; `null` quand le champ manque. */
  allergens: { present: readonly string[]; complete: boolean } | null;
  mainProtein: string | null;
  mainStarch: string | null;
  /** Préparation, en minutes. */
  prepMinutes: number | null;
  /** L'élément est-il léger ? `null` quand on ne sait pas. */
  light: boolean | null;
  /**
   * Styles de la recette (`tags.styles`) ; `null` ou absent quand elle n'a
   * jamais été examinée (pas de `tags.styles_checked_at`).
   */
  styles?: readonly string[] | null;
}

export type CriterionVerdict = "ok" | "violates" | "unknown";

export interface CriterionCheck {
  key: CriterionKey;
  regime: CriterionRegime;
  verdict: CriterionVerdict;
  /** Ce qui est en cause (violates) ou ce qui n'a pas pu être vérifié (unknown). */
  values: string[];
}

function check(key: CriterionKey, verdict: CriterionVerdict, values: string[] = []) {
  return { key, regime: CRITERION_REGIMES[key], verdict, values };
}

function inVocabulary<T extends string>(value: string | null, vocabulary: readonly T[]): T | null {
  return value != null && (vocabulary as readonly string[]).includes(value) ? (value as T) : null;
}

/**
 * Prédicat d'exclusion : un résultat par exclusion active.
 *
 * Une donnée absente ne prouve rien : un allergène exclu absent d'une liste
 * incomplète, une protéine inconnue rendent `unknown`, jamais `ok`.
 */
export function checkExclusions(c: PlanningCriteria, item: CriteriaItem): CriterionCheck[] {
  const out: CriterionCheck[] = [];
  if (c.excludedAllergens.length > 0) {
    const present = new Set(item.allergens?.present ?? []);
    const found = c.excludedAllergens.filter((a) => present.has(a));
    if (found.length > 0) out.push(check("excluded_allergens", "violates", found));
    else if (item.allergens == null || !item.allergens.complete) {
      out.push(check("excluded_allergens", "unknown", [...c.excludedAllergens]));
    } else out.push(check("excluded_allergens", "ok"));
  }
  if (c.excludedProteins.length > 0) {
    const p = inVocabulary(item.mainProtein, MAIN_PROTEINS);
    if (p == null) out.push(check("excluded_proteins", "unknown", [...c.excludedProteins]));
    else if (c.excludedProteins.includes(p)) out.push(check("excluded_proteins", "violates", [p]));
    else out.push(check("excluded_proteins", "ok"));
  }
  if (c.excludedStarches.length > 0) {
    const s = inVocabulary(item.mainStarch, MAIN_STARCHES);
    if (s == null) out.push(check("excluded_starches", "unknown", [...c.excludedStarches]));
    else if (c.excludedStarches.includes(s)) out.push(check("excluded_starches", "violates", [s]));
    else out.push(check("excluded_starches", "ok"));
  }
  return out;
}

/**
 * Prédicat des préférences — serveur seul. Une donnée absente laisse passer
 * (`unknown`) : sans preuve contraire, l'élément reste proposable.
 */
export function checkPreferences(c: PlanningCriteria, item: CriteriaItem): CriterionCheck[] {
  const out: CriterionCheck[] = [];
  if (c.wantedProteins.length > 0) {
    const p = inVocabulary(item.mainProtein, MAIN_PROTEINS);
    if (p == null) out.push(check("wanted_proteins", "unknown"));
    else if (c.wantedProteins.includes(p)) out.push(check("wanted_proteins", "ok"));
    else out.push(check("wanted_proteins", "violates", [p]));
  }
  if (c.wantedStarches.length > 0) {
    const s = inVocabulary(item.mainStarch, MAIN_STARCHES);
    if (s == null) out.push(check("wanted_starches", "unknown"));
    else if (c.wantedStarches.includes(s)) out.push(check("wanted_starches", "ok"));
    else out.push(check("wanted_starches", "violates", [s]));
  }
  if (c.maxDuration != null) {
    const prep = item.prepMinutes;
    if (prep == null) out.push(check("max_duration", "unknown"));
    else if (prep > c.maxDuration) out.push(check("max_duration", "violates", [String(prep)]));
    else out.push(check("max_duration", "ok"));
  }
  if (c.light) {
    if (item.light == null) out.push(check("light", "unknown"));
    else out.push(check("light", item.light ? "ok" : "violates"));
  }
  if (c.wantedStyles.length > 0) {
    if (item.styles == null) out.push(check("wanted_styles", "unknown"));
    else {
      const carried = vocabularyList([...item.styles], RECIPE_STYLES);
      if (carried.some((s) => c.wantedStyles.includes(s))) out.push(check("wanted_styles", "ok"));
      else out.push(check("wanted_styles", "violates", carried));
    }
  }
  return out;
}

// ── Libellés ─────────────────────────────────────────────────────────────────

const PROTEIN_WORDS: Readonly<Record<MainProtein, string>> = {
  boeuf: "bœuf",
  porc: "porc",
  volaille: "volaille",
  agneau: "agneau",
  poisson: "poisson",
  fruits_de_mer: "fruits de mer",
  oeuf: "œufs",
  vegetarien: "végétarien",
  legumineuses: "légumineuses",
};

const STARCH_WORDS: Readonly<Record<MainStarch, string>> = {
  pates: "pâtes",
  riz: "riz",
  pommes_de_terre: "pommes de terre",
  semoule: "semoule",
  pain: "pain",
  aucun: "sans féculent",
};

export function proteinWord(key: string): string {
  return (PROTEIN_WORDS as Record<string, string>)[key] ?? key;
}

export function starchWord(key: string): string {
  return (STARCH_WORDS as Record<string, string>)[key] ?? key;
}

export function allergenWord(key: string): string {
  const label = (ALLERGEN_LABELS as Record<string, string>)[key];
  return label ? label.toLowerCase() : key;
}

/** « 1 h 10 », « 45 min ». */
export function formatMinutes(minutes: number): string {
  if (minutes < 60) return `${minutes} min`;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return m === 0 ? `${h} h` : `${h} h ${String(m).padStart(2, "0")}`;
}

/**
 * Les critères en clair, pour le prompt : « sans porc · sans gluten · 30 min
 * de préparation au plus ». Vide sans critère.
 */
export function describeCriteria(c: PlanningCriteria): string {
  const parts: string[] = [];
  if (c.excludedProteins.length > 0) {
    parts.push(`sans ${c.excludedProteins.map(proteinWord).join(", ")} en protéine principale`);
  }
  if (c.excludedAllergens.length > 0) {
    parts.push(`sans ${c.excludedAllergens.map(allergenWord).join(", ")} (allergènes)`);
  }
  if (c.excludedStarches.length > 0) {
    parts.push(
      c.excludedStarches
        .map((s) =>
          s === "aucun" ? "avec un féculent" : `sans ${starchWord(s)} en féculent principal`,
        )
        .join(" · "),
    );
  }
  if (c.wantedProteins.length > 0) {
    parts.push(`de préférence ${c.wantedProteins.map(proteinWord).join(" ou ")}`);
  }
  if (c.wantedStarches.length > 0) {
    parts.push(`de préférence ${c.wantedStarches.map(starchWord).join(" ou ")}`);
  }
  if (c.maxDuration != null) parts.push(`${formatMinutes(c.maxDuration)} de préparation au plus`);
  if (c.light) parts.push("léger");
  if (c.wantedStyles.length > 0) {
    parts.push(`de préférence un plat ${c.wantedStyles.map(styleWord).join(" ou ")}`);
  }
  return parts.join(" · ");
}

/** « sans fruits à coque, sans porc » : les exclusions, pour un service vide. */
export function exclusionPhrase(c: PlanningCriteria): string {
  const parts: string[] = [];
  if (c.excludedAllergens.length > 0) {
    parts.push(`sans ${c.excludedAllergens.map(allergenWord).join(", ")}`);
  }
  if (c.excludedProteins.length > 0) {
    parts.push(`sans ${c.excludedProteins.map(proteinWord).join(", ")}`);
  }
  if (c.excludedStarches.length > 0) {
    parts.push(
      c.excludedStarches
        .map((s) => (s === "aucun" ? "avec un féculent" : `sans ${starchWord(s)}`))
        .join(", "),
    );
  }
  return parts.join(", ");
}

// ── Écarts rendus au client ──────────────────────────────────────────────────

/** Le service d'un repas auquel un écart se rapporte. */
export type UnmetService = "plat" | "entree" | "dessert";

/**
 * Un critère que le choix ne tient pas, ou n'a pas pu vérifier.
 *
 * `relaxed` : préférence relâchée faute d'autre choix. `empty` : exclusion
 * sans candidat, le service reste vide. `unverified` : exclusion que la
 * donnée de l'élément ne permet pas de vérifier.
 */
export interface UnmetCriterion {
  key: CriterionKey;
  regime: CriterionRegime;
  status: "relaxed" | "empty" | "unverified";
  service: UnmetService;
  /** Phrase prête à afficher, en français. */
  detail: string;
}

const SERVICE_PLURAL: Readonly<Record<UnmetService, string>> = {
  plat: "plat",
  entree: "entrée",
  dessert: "dessert",
};

/** « Aucun dessert sans fruits à coque. » */
export function emptyServiceDetail(service: UnmetService, c: PlanningCriteria): string {
  const noun = SERVICE_PLURAL[service];
  const article = service === "entree" ? "Aucune" : "Aucun";
  return `${article} ${noun} ${exclusionPhrase(c)}.`;
}

/**
 * La phrase d'un écart, depuis le résultat du prédicat.
 *
 * Préférence non tenue : « 1 h 10, au-delà des 45 min demandées : peu
 * d'autres choix ». Exclusion non vérifiée : « Allergènes non vérifiés :
 * gluten ».
 */
export function unmetDetail(
  result: CriterionCheck,
  c: PlanningCriteria,
  item: CriteriaItem,
  opts: {
    /**
     * Styles portés par au moins un plat du corpus. Quand aucun style voulu
     * n'y figure : « Aucun plat street food dans vos recettes » ; sinon, ou
     * sans corpus connu : « Pas un plat street food : peu d'autres choix ».
     */
    corpusStyles?: ReadonlySet<string>;
  } = {},
): string {
  const few = "peu d'autres choix";
  switch (result.key) {
    case "wanted_styles": {
      const wanted = c.wantedStyles.map(styleWord).join(" ou ");
      const corpus = opts.corpusStyles;
      const absent = corpus != null && !c.wantedStyles.some((s) => corpus.has(s));
      return absent ? `Aucun plat ${wanted} dans vos recettes` : `Pas un plat ${wanted} : ${few}`;
    }
    case "max_duration":
      return `${formatMinutes(item.prepMinutes ?? 0)}, au-delà des ${formatMinutes(c.maxDuration ?? 0)} demandées : ${few}`;
    case "wanted_proteins":
      return `${proteinWord(result.values[0] ?? "")}, au lieu de ${c.wantedProteins.map(proteinWord).join(" ou ")} : ${few}`;
    case "wanted_starches":
      return `${starchWord(result.values[0] ?? "")}, au lieu de ${c.wantedStarches.map(starchWord).join(" ou ")} : ${few}`;
    case "light":
      return `Pas un plat léger : ${few}`;
    case "excluded_allergens":
      return `Allergènes non vérifiés : ${result.values.map(allergenWord).join(", ")}`;
    case "excluded_proteins":
      return `Protéine principale inconnue : « sans ${result.values.map(proteinWord).join(", ")} » non vérifié`;
    case "excluded_starches":
      return `Féculent principal inconnu : « sans ${result.values.map(starchWord).join(", ")} » non vérifié`;
  }
}
