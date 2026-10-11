/**
 * Durées estimées d'une recette, posées à l'écriture.
 *
 * Une recette sans durée de préparation ou de cuisson reçoit une estimation
 * du modèle (poste `time_estimate`), écrite dans un champ racine à part :
 *
 *   estimated_times: {
 *     status: "done" | "pending",
 *     fingerprint: string,      // empreinte du contenu estimé
 *     prep: number | null,      // minutes, 1..1440 (status "done")
 *     cook: number | null,
 *     estimated_at: Timestamp,  // status "done"
 *     claim_id: string,         // status "pending"
 *     claimed_at: Timestamp,    // status "pending"
 *   }
 *
 * Hors du CookLang : l'estimation n'est pas ce que dit la recette, et une
 * durée lue — métadonnée `>> temps_preparation:` ou champ `tags.prep_time` —
 * garde toujours la priorité. Le client n'écrit jamais ce champ (règles
 * Firestore) ; c'est ce module qui l'efface quand les deux durées sont lues.
 *
 * Pas de boucle : `estimated_times` n'entre pas dans l'empreinte des entrées
 * du déclencheur (`recipeTriggerInputsFingerprint`), et l'écho d'une
 * écriture de ce module trouve une estimation à jour pour le contenu. Pas de
 * double appel non plus : le module RÉSERVE l'estimation par une transaction
 * (`status: "pending"`) avant d'appeler le modèle. Les échos qui arrivent
 * pendant l'appel — écriture du rôle dans un repas, de la nutrition —
 * trouvent la réservation et passent leur chemin. Une réservation restée
 * sans réponse (appel en échec) expire après `PENDING_TTL_MS` : la prochaine
 * écriture, ou le backfill « Durées estimées », reprend la recette.
 */

import { createHash, randomUUID } from "node:crypto";
import { FieldValue, Timestamp, getFirestore } from "firebase-admin/firestore";
import type { DocumentReference } from "firebase-admin/firestore";

import { recipeBudgetUserId } from "../ai/budget";
import { readDurations } from "../cooklang/parser";
import { estimateRecipeTimes, type TimeEstimate } from "../gemini/timeEstimate";
import { logError, logInfo } from "../logging";

export const TIME_ESTIMATE_FEATURE = "time_estimate";

/** Délai au-delà duquel une réservation sans réponse peut être reprise. */
export const PENDING_TTL_MS = 10 * 60_000;

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

/** Une durée lue dans un champ : un nombre strictement positif. */
function positiveMinutes(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) && value > 0 ? value : null;
}

/**
 * Les durées que la recette DONNE (`readDurations`, `cooklang/parser.ts`) :
 * `tags` d'abord, puis les métadonnées du brouillon, puis du texte validé.
 * Une durée lue à l'un de ces endroits n'est jamais estimée.
 */
export function readRecipeDurations(data: Record<string, unknown>): TimeEstimate {
  const tags = (data.tags && typeof data.tags === "object" ? data.tags : {}) as Record<
    string,
    unknown
  >;
  return readDurations(tags, [asString(data.draft_cooklang), asString(data.raw_cooklang)]);
}

/** Le texte de la recette, sans ses lignes de métadonnées. */
export function estimateContent(data: Record<string, unknown>): string {
  const cooklang = asString(data.draft_cooklang) || asString(data.raw_cooklang);
  return cooklang
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith(">>"))
    .join("\n");
}

/**
 * Empreinte du contenu que l'estimation juge : le titre et le texte de la
 * recette, SANS ses métadonnées. Saisir une durée réécrit une ligne
 * `>> temps_…:` : l'empreinte ne bouge pas, et l'estimation de l'autre durée
 * reste valable. Changer une étape la fait bouger : la recette est réestimée.
 */
export function estimateFingerprint(data: Record<string, unknown>): string {
  const payload = JSON.stringify([asString(data.titre).trim(), estimateContent(data)]);
  return createHash("sha256").update(payload).digest("hex").slice(0, 32);
}

/** Le champ `estimated_times` tel qu'il est stocké, lu sans confiance. */
export interface StoredEstimatedTimes {
  status: "done" | "pending";
  fingerprint: string;
  prep: number | null;
  cook: number | null;
  claimId: string | null;
  claimedAtMs: number | null;
}

function timestampMs(value: unknown): number | null {
  if (value instanceof Timestamp) return value.toMillis();
  if (value instanceof Date) return value.getTime();
  return null;
}

/** `null` quand le champ est absent ou mal formé : il se traite comme absent. */
export function parseStoredEstimatedTimes(value: unknown): StoredEstimatedTimes | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const record = value as Record<string, unknown>;
  const status = record.status;
  if (status !== "done" && status !== "pending") return null;
  const fingerprint = asString(record.fingerprint);
  if (!fingerprint) return null;
  return {
    status,
    fingerprint,
    prep: positiveMinutes(record.prep),
    cook: positiveMinutes(record.cook),
    claimId: asString(record.claim_id) || null,
    claimedAtMs: timestampMs(record.claimed_at),
  };
}

/** Ce que l'écriture d'une recette demande pour ses durées estimées. */
export type EstimatedTimesDecision =
  | { kind: "none"; reason: "complete" | "up_to_date" | "pending" | "no_content" }
  | { kind: "clear" }
  | { kind: "estimate"; fingerprint: string };

/**
 * Décide, sans rien lire d'autre que la recette.
 *
 * - Les deux durées sont lues : rien à estimer ; une estimation restée là est
 *   effacée (une durée saisie à la main remplace l'estimation).
 * - Il en manque une : on estime, sauf si une estimation existe déjà pour ce
 *   contenu, ou si une réservation récente est en cours.
 */
export function decideEstimatedTimes(
  data: Record<string, unknown>,
  nowMs: number,
): EstimatedTimesDecision {
  const read = readRecipeDurations(data);
  const hasField = data.estimated_times !== undefined;
  if (read.prep != null && read.cook != null) {
    return hasField ? { kind: "clear" } : { kind: "none", reason: "complete" };
  }
  if (estimateContent(data).length === 0 && asString(data.titre).trim().length === 0) {
    return { kind: "none", reason: "no_content" };
  }
  const fingerprint = estimateFingerprint(data);
  const stored = parseStoredEstimatedTimes(data.estimated_times);
  if (stored && stored.fingerprint === fingerprint) {
    if (stored.status === "done") return { kind: "none", reason: "up_to_date" };
    const claimedAt = stored.claimedAtMs ?? 0;
    if (nowMs - claimedAt < PENDING_TTL_MS) return { kind: "none", reason: "pending" };
  }
  return { kind: "estimate", fingerprint };
}

/**
 * Le champ écrit pour une estimation rendue.
 *
 * Une composante que la recette donne déjà (`data`, relue dans la
 * transaction d'écriture) est mise à `null` : une estimation n'est jamais
 * conservée pour une durée lue, ni dans le texte, ni dans `tags`. Le client
 * peut ainsi afficher et compter ce champ sans le confronter au texte.
 */
export function doneEstimatedTimes(
  fingerprint: string,
  estimate: TimeEstimate,
  data: Record<string, unknown>,
) {
  const read = readRecipeDurations(data);
  return {
    status: "done",
    fingerprint,
    prep: read.prep == null ? estimate.prep : null,
    cook: read.cook == null ? estimate.cook : null,
    estimated_at: FieldValue.serverTimestamp(),
  };
}

/**
 * Pose ou efface `estimated_times`. Ne lève jamais : l'échec est journalisé,
 * et la réservation expirée laisse la recette à reprendre.
 */
export async function syncRecipeEstimatedTimes(args: {
  recipeRef: DocumentReference;
  data: Record<string, unknown>;
  correlationId: string;
  scanId?: string;
}): Promise<void> {
  const { recipeRef, data, correlationId, scanId } = args;
  const userId = recipeBudgetUserId(data.created_by);
  const first = decideEstimatedTimes(data, Date.now());
  if (first.kind === "none") return;

  const logFailure = (message: string, err: unknown) =>
    logError({
      message,
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "DESIGN",
      correlationId,
      scanId,
      userId,
      feature: TIME_ESTIMATE_FEATURE,
      extra: { recipeId: recipeRef.id },
    });

  if (first.kind === "clear") {
    try {
      await recipeRef.update({ estimated_times: FieldValue.delete() });
    } catch (err) {
      await logFailure("syncRecipeEstimatedTimes: estimation non effacée", err);
    }
    return;
  }

  // Réservation : relue dans une transaction, pour qu'un seul réveil appelle
  // le modèle quand plusieurs arrivent ensemble.
  const claimId = randomUUID();
  let claimed: { fingerprint: string; data: Record<string, unknown> } | null = null;
  try {
    claimed = await getFirestore().runTransaction(async (tx) => {
      const snap = await tx.get(recipeRef);
      if (!snap.exists) return null;
      const current = snap.data() as Record<string, unknown>;
      const decision = decideEstimatedTimes(current, Date.now());
      if (decision.kind !== "estimate") return null;
      tx.update(recipeRef, {
        estimated_times: {
          status: "pending",
          fingerprint: decision.fingerprint,
          claim_id: claimId,
          claimed_at: Timestamp.now(),
        },
      });
      return { fingerprint: decision.fingerprint, data: current };
    });
  } catch (err) {
    await logFailure("syncRecipeEstimatedTimes: réservation impossible", err);
    return;
  }
  if (!claimed) return;

  let estimate: TimeEstimate | undefined;
  try {
    const answers = await estimateRecipeTimes(
      [
        {
          titre: asString(claimed.data.titre),
          content: estimateContent(claimed.data),
          portions: typeof claimed.data.portions === "number" ? claimed.data.portions : null,
        },
      ],
      {
        correlationId,
        userId,
        scanId,
        feature: TIME_ESTIMATE_FEATURE,
        moduleType: "DESIGN",
        timeoutMs: 30_000,
      },
    );
    estimate = answers.get(0);
  } catch (err) {
    // La réservation reste : elle expire après dix minutes, et évite qu'une
    // salve d'échos rappelle un modèle en panne.
    await logFailure("syncRecipeEstimatedTimes: échec de l'estimation", err);
    return;
  }
  // Le modèle a répondu sans traiter la recette : enregistré comme « ne sait
  // pas », pour ne pas la refacturer à chaque écriture du même contenu.
  const result = estimate ?? { prep: null, cook: null };

  try {
    const written = await getFirestore().runTransaction(async (tx) => {
      const snap = await tx.get(recipeRef);
      if (!snap.exists) return null;
      const current = snap.data() as Record<string, unknown>;
      const stored = parseStoredEstimatedTimes(current.estimated_times);
      // Le contenu a changé, ou la réservation a été effacée pendant
      // l'appel : la réponse ne vaut plus pour cette recette.
      if (!stored || stored.claimId !== claimId) return null;
      const field = doneEstimatedTimes(claimed.fingerprint, result, current);
      tx.update(recipeRef, { estimated_times: field });
      return field;
    });
    if (!written || (written.prep == null && written.cook == null)) {
      await logInfo({
        message: written
          ? "syncRecipeEstimatedTimes: aucune durée estimée à retenir"
          : "syncRecipeEstimatedTimes: recette modifiée pendant l'estimation, réponse écartée",
        correlationId,
        scanId,
        userId,
        moduleType: "DESIGN",
        feature: TIME_ESTIMATE_FEATURE,
        extra: { recipeId: recipeRef.id },
      });
    }
  } catch (err) {
    await logFailure("syncRecipeEstimatedTimes: estimation non écrite", err);
  }
}
