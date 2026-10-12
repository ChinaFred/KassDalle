/**
 * Programmation des backfills récurrents, et état d'un passage — logique pure.
 *
 * Rien ici ne lit ni n'écrit Firestore : les décisions (« ce backfill est-il
 * échu à cette heure ? », « ce ponctuel est-il terminé ? ») se testent seules,
 * dans `tests/backfillSchedule.test.ts`. `runner.ts` et `scheduledBackfills.ts`
 * les appliquent aux documents.
 *
 * Heure de Paris. Le jour et l'heure se lisent par `Intl` avec le fuseau
 * `Europe/Paris` : Node 22 embarque les données de fuseau, le passage à
 * l'heure d'été est compris sans table écrite ici.
 */

import { BACKFILLS, type BackfillKey, type BackfillKind } from "./registry";

export const BACKFILL_TIMEZONE = "Europe/Paris";

/** `app_config/backfill_schedules` : une entrée par clé de backfill récurrent. */
export const BACKFILL_SCHEDULES_DOC_ID = "backfill_schedules";

/**
 * Durée de vie d'un verrou de passage. Une fonction s'arrête au plus tard à
 * 540 s ; un verrou plus vieux que dix minutes est celui d'un passage
 * interrompu (instance arrêtée, délai dépassé), et peut être repris.
 */
export const BACKFILL_LOCK_TTL_MS = 10 * 60_000;

/** Programmation d'un backfill récurrent. */
export interface BackfillSchedule {
  enabled: boolean;
  /** Jours ISO, lundi = 1 … dimanche = 7, triés, sans doublon. */
  days: number[];
  /** Heure de Paris, 0 à 23. */
  hour: number;
  /**
   * Administrateur qui a enregistré la programmation : le plafond de dépense
   * quotidien des passages programmés lui est imputé. `null` pour le défaut
   * de la nutrition, qui impute chaque recette à son propriétaire.
   */
  programmeParUid: string | null;
}

/**
 * Programmation appliquée quand `app_config/backfill_schedules` ne dit rien
 * pour ce backfill, tirée du registre (`defaultSchedule`). Le rattrapage
 * quotidien de la nutrition ne doit pas s'arrêter au déploiement :
 * `scheduledBackfills` l'applique dès le premier tick, et l'y écrit
 * (`missingDefaultSchedules`).
 */
export const DEFAULT_BACKFILL_SCHEDULES: Partial<Record<BackfillKey, BackfillSchedule>> =
  Object.fromEntries(
    BACKFILLS.filter((b) => b.defaultSchedule != null).map((b) => [
      b.key,
      {
        enabled: true,
        days: [...(b.defaultSchedule?.days ?? [])],
        hour: b.defaultSchedule?.hour ?? 0,
        programmeParUid: null,
      },
    ]),
  );

/**
 * Un entier de [min] à [max], ou `null`. Strict : une chaîne (« 5 »), un
 * booléen, `null` ou un nombre non entier (5.5) sont refusés, pas convertis.
 * Même règle côté client (`BackfillSchedule.fromMap`), fixture
 * `test-fixtures/backfill_schedule.json`.
 */
function strictInt(value: unknown, min: number, max: number): number | null {
  return typeof value === "number" && Number.isInteger(value) && value >= min && value <= max
    ? value
    : null;
}

/**
 * Jours ISO triés, sans doublon ; `null` si la valeur n'est pas une liste ou
 * si un seul élément n'est pas un jour valide. Une liste vide est valide.
 */
export function parseDays(value: unknown): number[] | null {
  if (!Array.isArray(value)) return null;
  const days = new Set<number>();
  for (const raw of value) {
    const day = strictInt(raw, 1, 7);
    if (day == null) return null;
    days.add(day);
  }
  return [...days].sort((a, b) => a - b);
}

/** Heure de 0 à 23, ou `null`. */
export function parseHour(value: unknown): number | null {
  return strictInt(value, 0, 23);
}

/**
 * Lit une programmation stockée. Mal formée : `null`, et le défaut ne
 * s'applique pas. `enabled` ne vaut vrai que pour le booléen `true`.
 */
export function parseSchedule(raw: unknown): BackfillSchedule | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  const days = parseDays(r.days);
  const hour = parseHour(r.hour);
  if (days == null || hour == null) return null;
  const uid = typeof r.programme_par_uid === "string" ? r.programme_par_uid.trim() : "";
  return {
    enabled: r.enabled === true && days.length > 0,
    days,
    hour,
    programmeParUid: uid.length > 0 ? uid : null,
  };
}

/**
 * La programmation qui vaut pour [key] : celle du document, ou le défaut si
 * le document ne porte aucune entrée pour cette clé. Une entrée présente mais
 * illisible ne retombe pas sur le défaut : elle vaut « non programmé », et
 * l'appelant la journalise.
 */
export function effectiveSchedule(
  key: BackfillKey,
  schedulesDoc: Record<string, unknown> | undefined,
): BackfillSchedule | null {
  const raw = schedulesDoc?.[key];
  if (raw === undefined) return DEFAULT_BACKFILL_SCHEDULES[key] ?? null;
  return parseSchedule(raw);
}

/**
 * Défauts à écrire dans `app_config/backfill_schedules` : ceux dont la clé
 * n'y figure pas encore. Une entrée présente, même désactivée ou illisible,
 * n'est jamais remplacée.
 */
export function missingDefaultSchedules(
  schedulesDoc: Record<string, unknown> | undefined,
): Partial<Record<BackfillKey, BackfillSchedule>> {
  const out: Partial<Record<BackfillKey, BackfillSchedule>> = {};
  for (const [key, schedule] of Object.entries(DEFAULT_BACKFILL_SCHEDULES)) {
    if (schedule && schedulesDoc?.[key] === undefined) out[key as BackfillKey] = schedule;
  }
  return out;
}

/** Message enregistré quand l'auteur d'une programmation a perdu le rôle admin. */
export const PROGRAMMER_NOT_ADMIN_MESSAGE =
  "L'auteur de la programmation n'est plus administrateur.";

/**
 * Un passage programmé peut-il partir au nom de son auteur ? `null` : oui.
 * Sans auteur (le défaut de la nutrition), rien à vérifier : la nutrition est
 * imputée au propriétaire de chaque recette. Avec un auteur, il doit être
 * encore administrateur — un compte rétrogradé ou révoqué ne doit plus voir
 * de dépense imputée par une programmation qu'il ne peut plus modifier.
 */
export function programmerBlocker(
  programmeParUid: string | null,
  programmerIsAdmin: boolean,
): string | null {
  if (programmeParUid == null) return null;
  return programmerIsAdmin ? null : PROGRAMMER_NOT_ADMIN_MESSAGE;
}

/** Jour ISO, heure et créneau (`AAAA-MM-JJTHH`) d'un instant, à Paris. */
export interface ParisSlot {
  isoDay: number;
  hour: number;
  /** Identifiant du créneau horaire : deux ticks dans la même heure le partagent. */
  slot: string;
}

const WEEKDAYS: Record<string, number> = {
  Mon: 1,
  Tue: 2,
  Wed: 3,
  Thu: 4,
  Fri: 5,
  Sat: 6,
  Sun: 7,
};

const PARIS_FORMAT = new Intl.DateTimeFormat("en-GB", {
  timeZone: BACKFILL_TIMEZONE,
  weekday: "short",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  hourCycle: "h23",
});

export function parisSlot(date: Date): ParisSlot {
  const parts: Record<string, string> = {};
  for (const p of PARIS_FORMAT.formatToParts(date)) parts[p.type] = p.value;
  const hour = Number(parts.hour);
  return {
    isoDay: WEEKDAYS[parts.weekday] ?? 0,
    hour,
    slot: `${parts.year}-${parts.month}-${parts.day}T${String(hour).padStart(2, "0")}`,
  };
}

/** Ce que la décision « échu » lit de l'état d'un backfill. */
export interface RunStateForDue {
  /** Un passage tient le verrou. */
  enCours: boolean;
  /** Pose du verrou, en millisecondes. */
  enCoursDepuisMs: number | null;
  /**
   * Un passage programmé s'est arrêté avant la fin (délai, nombre de
   * documents) ou n'a pas tenu dans le tick : il reprend l'heure suivante.
   * Faux après un arrêt par plafond de dépense : la reprise attend alors le
   * prochain créneau.
   */
  repriseDue: boolean;
  /** Créneau du dernier passage lancé par la programmation (`AAAA-MM-JJTHH`). */
  dernierCreneau: string | null;
}

/** Le verrou est-il celui d'un passage interrompu ? */
export function lockExpired(enCoursDepuisMs: number | null, nowMs: number): boolean {
  if (enCoursDepuisMs == null) return true;
  return nowMs - enCoursDepuisMs > BACKFILL_LOCK_TTL_MS;
}

/** Le verrou est-il tenu par un passage vivant ? */
export function lockHeld(run: Pick<RunStateForDue, "enCours" | "enCoursDepuisMs">, nowMs: number) {
  return run.enCours && !lockExpired(run.enCoursDepuisMs, nowMs);
}

export type DueReason = "creneau" | "reprise";

/**
 * Le backfill est-il échu à [now] ?
 *
 *  - `creneau` : le jour et l'heure de Paris sont ceux de la programmation, et
 *    aucun passage programmé n'a déjà démarré dans ce créneau ;
 *  - `reprise` : le dernier passage programmé est resté incomplet sans
 *    toucher le plafond de dépense ;
 *  - `null` : rien à faire — non programmé, désactivé, ou un passage en cours.
 *
 * Une reprise ne dépend pas des jours programmés : un passage commencé le
 * dimanche à 3 h continue à 4 h, puis à 5 h, jusqu'à la fin.
 */
export function dueReason(
  schedule: BackfillSchedule | null,
  run: RunStateForDue,
  now: Date,
): DueReason | null {
  if (!schedule || !schedule.enabled || schedule.days.length === 0) return null;
  if (lockHeld(run, now.getTime())) return null;
  if (slotMatches(schedule, run, now)) return "creneau";
  if (run.repriseDue) return "reprise";
  return null;
}

/**
 * [now] tombe-t-il dans un créneau programmé que la programmation n'a pas
 * encore servi ? Verrou ignoré : un créneau tombé pendant un passage manuel
 * se reporte d'une heure.
 */
export function slotMatches(
  schedule: BackfillSchedule,
  run: Pick<RunStateForDue, "dernierCreneau">,
  now: Date,
): boolean {
  if (!schedule.enabled || schedule.days.length === 0) return false;
  const paris = parisSlot(now);
  return (
    schedule.days.includes(paris.isoDay) &&
    schedule.hour === paris.hour &&
    run.dernierCreneau !== paris.slot
  );
}

/** Ce qu'un passage a laissé, lu dans le compte rendu de chaque backfill. */
export interface PassSummary {
  /** Plus rien n'attend : collection(s) parcourue(s) en entier. */
  complete: boolean;
  /** Éléments encore à traiter après le passage ; `null` quand on ne sait pas les compter. */
  remaining: number | null;
  /** Éléments de la liste « à revoir ». */
  toReview: number;
  /** Arrêté par le plafond de dépense quotidien. */
  spendCapHit: boolean;
}

export type RunStatus = "termine" | "incomplet" | "erreur" | "en_cours";
export type RunOrigin = "manuel" | "programme";

export function passStatus(summary: PassSummary): "termine" | "incomplet" {
  return summary.complete ? "termine" : "incomplet";
}

/**
 * Faut-il reprendre l'heure suivante ? Un passage programmé incomplet, oui,
 * sauf arrêt par plafond de dépense (reprise au prochain créneau). Un passage
 * terminé, non. Un passage manuel incomplet ne change rien à ce que la
 * programmation devait.
 */
export function repriseDueAfter(
  origin: RunOrigin,
  summary: PassSummary,
  previous: boolean,
): boolean {
  if (summary.complete || summary.spendCapHit) return false;
  if (origin === "programme") return true;
  return previous;
}

/**
 * Un ponctuel se marque terminé tout seul quand un passage finit sans aucun
 * reste : tout parcouru, rien à traiter, rien à revoir. Un reste inconnu
 * (décompte impossible) n'est pas un reste nul.
 */
export function shouldAutoMarkDone(kind: BackfillKind, summary: PassSummary): boolean {
  return (
    kind === "ponctuel" && summary.complete && summary.remaining === 0 && summary.toReview === 0
  );
}

/** Version de l'application telle que le client l'envoie (`0.23.43`), ou `null`. */
export function sanitizeAppVersion(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const v = value.trim();
  return /^\d{1,3}\.\d{1,3}\.\d{1,4}$/.test(v) ? v : null;
}
