/**
 * Unités standard — sème dans `nutrition_units` les unités de
 * `DEFAULT_NUTRITION_UNITS` qui manquent, et complète celles qui existent sans
 * grammage, volume, libellé ou type. Sans appel de modèle.
 *
 * Remplace l'icône « Initialiser les unités par défaut » de l'écran Unités de
 * mesure, qui écrivait depuis le client (retirée en v0.24.40) : une écriture
 * de masse passe par Admin › Backfills.
 *
 * Réentrante : chaque unité est lue et écrite dans une transaction, une valeur
 * présente n'est jamais écrasée, et une unité complète n'est pas réécrite.
 * Relancer ne refait rien. La liste compte quarante unités : un
 * passage la parcourt en entier, sans curseur. Bornée par le délai et par
 * trois échecs de suite.
 */

import { onCall } from "firebase-functions/v2/https";
import { FieldValue, getFirestore } from "firebase-admin/firestore";

import { COLL_NUTRITION_UNITS, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { logError, logInfo } from "../logging";
import { DEFAULT_NUTRITION_UNITS, defaultUnitPlan } from "../nutrition/defaultUnits";
import { requireAdmin, type AuthContext } from "./_auth";
import { runBackfillFromCallable } from "../backfills/runner";
import type { PassSummary } from "../backfills/schedule";
import {
  BackfillReview,
  shortErrorMessage,
  type BackfillReviewList,
  withoutReviewList,
} from "./_backfillReview";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const FEATURE = "default_units_backfill";

/** Marge gardée sur le délai de la fonction. */
const DEADLINE_MARGIN_MS = 30_000;
/** Trois échecs de suite : une panne, pas trois unités difficiles. */
const MAX_CONSECUTIVE_FAILURES = 3;

interface BackfillDefaultUnitsRequest {
  /** Version de l'application qui lance, pour l'état du backfill. */
  appVersion?: string;
}

export interface BackfillDefaultUnitsResponse {
  /** Unités standard de la liste. */
  total: number;
  examinees: number;
  /** Document absent, créé. */
  creees: number;
  /** Document présent, champs manquants complétés. */
  completees: number;
  /** Rien de manquant, rien d'écrit. */
  dejaAJour: number;
  echouees: number;
  /** Unités non examinées ou en échec : à reprendre au passage suivant. */
  restantes: number;
  stoppedByDeadline: boolean;
  stoppedByErrors: boolean;
  /** Vrai quand toute la liste a été examinée sans échec. */
  completed: boolean;
  /** Unités en échec dans ce passage, nommées, avec la raison. */
  aRevoir: BackfillReviewList;
}

export const backfillDefaultUnitsFn = onCall<BackfillDefaultUnitsRequest>(
  {
    region: REGION,
    timeoutSeconds: 540,
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req) => {
    const ctx = await requireAdmin(req, FEATURE);
    const deadlineMs = Date.now() + 8 * 60_000;
    return runBackfillFromCallable({
      key: "default_units",
      ctx,
      appVersion: req.data?.appVersion,
      run: () => runDefaultUnitsPass(ctx, deadlineMs),
      summarize: summarizeDefaultUnits,
    });
  },
);

/** Ce que l'état du backfill retient d'un passage (`backfills/runner.ts`). */
export function summarizeDefaultUnits(r: BackfillDefaultUnitsResponse): PassSummary {
  return {
    complete: r.completed,
    remaining: r.restantes,
    toReview: r.aRevoir.total,
    spendCapHit: false,
    unresolved: r.echouees,
  };
}

/** Un passage sur toute la liste des unités standard. */
export async function runDefaultUnitsPass(
  ctx: AuthContext,
  deadlineMs: number,
): Promise<BackfillDefaultUnitsResponse> {
  const db = getFirestore();
  const deadline = deadlineMs - DEADLINE_MARGIN_MS;
  const review = new BackfillReview();
  const response: BackfillDefaultUnitsResponse = {
    total: DEFAULT_NUTRITION_UNITS.length,
    examinees: 0,
    creees: 0,
    completees: 0,
    dejaAJour: 0,
    echouees: 0,
    restantes: 0,
    stoppedByDeadline: false,
    stoppedByErrors: false,
    completed: false,
    aRevoir: { items: [], total: 0 },
  };
  let consecutiveFailures = 0;

  for (const unit of DEFAULT_NUTRITION_UNITS) {
    if (Date.now() > deadline) {
      response.stoppedByDeadline = true;
      break;
    }
    if (consecutiveFailures >= MAX_CONSECUTIVE_FAILURES) {
      response.stoppedByErrors = true;
      break;
    }
    response.examinees += 1;
    const ref = db.collection(COLL_NUTRITION_UNITS).doc(unit.normalizedUnit);
    try {
      const action = await db.runTransaction(async (tx) => {
        const snap = await tx.get(ref);
        const plan = defaultUnitPlan(
          snap.exists ? ((snap.data() ?? {}) as Record<string, unknown>) : null,
          unit,
        );
        const now = FieldValue.serverTimestamp();
        if (plan.action === "create") {
          tx.create(ref, {
            ...plan.fields,
            first_seen_at: now,
            last_seen_at: now,
            updated_at: now,
            created_at: now,
          });
        } else if (plan.action === "patch") {
          tx.update(ref, { ...plan.fields, updated_at: now });
        }
        return plan.action;
      });
      if (action === "create") response.creees += 1;
      else if (action === "patch") response.completees += 1;
      else response.dejaAJour += 1;
      consecutiveFailures = 0;
    } catch (e) {
      response.echouees += 1;
      consecutiveFailures += 1;
      review.add({
        kind: "unit",
        id: unit.normalizedUnit,
        label: unit.displayLabel,
        reason: `Échec d'écriture : ${shortErrorMessage(e)}`,
      });
      await logError("Unités standard — échec sur une unité", {
        correlationId: ctx.correlationId,
        userId: ctx.userId,
        moduleType: "DESIGN",
        feature: FEATURE,
        errorDescription: e instanceof Error ? e.message : String(e),
        extra: { unitId: unit.normalizedUnit, consecutiveFailures },
      });
    }
  }

  response.restantes = response.total - response.creees - response.completees - response.dejaAJour;
  response.completed = response.restantes === 0;
  response.aRevoir = review.toJSON();

  await logInfo({
    message: "Unités standard — semis",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    moduleType: "DESIGN",
    feature: FEATURE,
    extra: { ...withoutReviewList(response) },
  });

  return response;
}
