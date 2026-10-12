/**
 * Réglages d'Admin › Backfills : programmer un récurrent, marquer un ponctuel
 * terminé. Administrateurs seulement.
 *
 *  - `setBackfillScheduleFn` écrit l'entrée d'un récurrent dans
 *    `app_config/backfill_schedules` : `{ enabled, days, hour, timezone,
 *    programme_par_uid, updated_at }`. L'administrateur qui enregistre devient
 *    le compte imputé des passages programmés (plafond de dépense quotidien).
 *  - `setBackfillDoneFn` pose ou retire `termine_*` sur l'état d'un ponctuel
 *    (`app_config/backfill_run_<clé>`).
 *
 * Les règles Firestore laissent un administrateur écrire `app_config` ; ces
 * deux entrées passent pourtant par le serveur, pour que la forme stockée
 * soit celle que `scheduledBackfills` relit : jours ISO valides, heure 0–23,
 * auteur de la programmation pris dans le jeton et non dans la requête.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { FieldValue, getFirestore } from "firebase-admin/firestore";

import { COLL_APP_CONFIG, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { logError, logInfo } from "../logging";
import { backfillDefinition } from "../backfills/registry";
import { setBackfillDone } from "../backfills/runner";
import {
  BACKFILL_SCHEDULES_DOC_ID,
  BACKFILL_TIMEZONE,
  parseDays,
  parseHour,
  sanitizeAppVersion,
} from "../backfills/schedule";
import { requireAdmin } from "./_auth";
import { parseBoolean } from "./_backfillCursor";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

interface SetBackfillScheduleRequest {
  key?: unknown;
  enabled?: unknown;
  days?: unknown;
  hour?: unknown;
}

interface SetBackfillDoneRequest {
  key?: unknown;
  done?: unknown;
  appVersion?: unknown;
}

/** Programmation validée, prête à écrire. Pure, pour les tests. */
export function validateScheduleRequest(data: SetBackfillScheduleRequest | undefined): {
  key: string;
  enabled: boolean;
  days: number[];
  hour: number;
} {
  const def = backfillDefinition(data?.key);
  if (!def) throw new HttpsError("invalid-argument", "Backfill inconnu.");
  if (def.kind !== "recurrent") {
    throw new HttpsError("failed-precondition", "Un backfill ponctuel ne se programme pas.");
  }
  const enabled = parseBoolean(data?.enabled, false);
  const days = parseDays(data?.days) ?? [];
  const hour = parseHour(data?.hour);
  if (hour == null) throw new HttpsError("invalid-argument", "Heure invalide (0 à 23).");
  if (enabled && days.length === 0) {
    throw new HttpsError("invalid-argument", "Choisissez au moins un jour.");
  }
  return { key: def.key, enabled, days, hour };
}

export const setBackfillScheduleFn = onCall<SetBackfillScheduleRequest>(
  {
    region: REGION,
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req): Promise<{ ok: true }> => {
    const ctx = await requireAdmin(req, "programmation_backfill");
    const schedule = validateScheduleRequest(req.data);
    try {
      await getFirestore()
        .collection(COLL_APP_CONFIG)
        .doc(BACKFILL_SCHEDULES_DOC_ID)
        .set(
          {
            [schedule.key]: {
              enabled: schedule.enabled,
              days: schedule.days,
              hour: schedule.hour,
              timezone: BACKFILL_TIMEZONE,
              programme_par_uid: ctx.userId,
              updated_at: FieldValue.serverTimestamp(),
            },
          },
          { merge: true },
        );
    } catch (err) {
      await logError({
        message: "Programmation d'un backfill — écriture impossible",
        errorDescription: err instanceof Error ? err.message : String(err),
        correlationId: ctx.correlationId,
        userId: ctx.userId,
        moduleType: "DESIGN",
        extra: { ...schedule },
      });
      throw new HttpsError("internal", "Programmation non enregistrée.");
    }
    await logInfo({
      message: `Programmation d'un backfill — ${schedule.key}`,
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      extra: { ...schedule },
    });
    return { ok: true };
  },
);

export const setBackfillDoneFn = onCall<SetBackfillDoneRequest>(
  {
    region: REGION,
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req): Promise<{ ok: true }> => {
    const ctx = await requireAdmin(req, "backfill_termine");
    const def = backfillDefinition(req.data?.key);
    if (!def) throw new HttpsError("invalid-argument", "Backfill inconnu.");
    if (def.kind !== "ponctuel") {
      throw new HttpsError("failed-precondition", "Seul un backfill ponctuel se marque terminé.");
    }
    if (typeof req.data?.done !== "boolean") {
      throw new HttpsError("invalid-argument", "Paramètre « done » attendu (vrai ou faux).");
    }
    const done = req.data.done;
    try {
      await setBackfillDone({
        key: def.key,
        done,
        adminUid: ctx.userId,
        appVersion: sanitizeAppVersion(req.data?.appVersion),
      });
    } catch (err) {
      await logError({
        message: "Backfill marqué terminé — écriture impossible",
        errorDescription: err instanceof Error ? err.message : String(err),
        correlationId: ctx.correlationId,
        userId: ctx.userId,
        moduleType: "DESIGN",
        extra: { key: def.key, done },
      });
      throw new HttpsError("internal", "Changement non enregistré.");
    }
    await logInfo({
      message: `Backfill ${def.key} — ${done ? "marqué terminé" : "remis à lancer"}`,
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      moduleType: "DESIGN",
      extra: { key: def.key, done },
    });
    return { ok: true };
  },
);
