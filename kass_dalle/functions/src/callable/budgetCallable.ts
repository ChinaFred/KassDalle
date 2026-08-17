/**
 * Pilotage du plafond de dépense, et lecture de ce qui a été consommé aujourd'hui.
 *
 * Les plafonds vivent dans Firestore et se règlent depuis l'écran des coûts :
 * le jour où un import massif se fait couper au milieu, il faut pouvoir relever
 * la limite en une minute, pas en un déploiement. Même moule que le routage
 * d'IA, la grille tarifaire et l'attestation.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

import { REGION, COLL_APP_CONFIG, COLL_AI_DAILY_SPEND, MAX_CALLABLE_INSTANCES } from "../config";
import { requireAdmin } from "./_auth";
import {
  AI_BUDGET_POLICY_DOC_ID,
  DEFAULT_AI_BUDGET_POLICY,
  getAiBudgetPolicy,
  invalidateAiBudgetPolicyCache,
  spendDay,
  type AiBudgetPolicy,
} from "../ai/budget";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const callableOpts = {
  region: REGION,
  memory: "256MiB" as const,
  timeoutSeconds: 60,
  cors: ALLOWED_ORIGINS,
  maxInstances: MAX_CALLABLE_INSTANCES,
};

/** Dépense d'un compte aujourd'hui, telle que l'écran la liste. */
interface DailySpendRow {
  uid: string;
  costUsd: number;
  calls: number;
  unpricedCalls: number;
}

export const getAiBudgetFn = onCall(callableOpts, async (req) => {
  await requireAdmin(req, "ai_budget_policy");

  const day = spendDay(new Date());
  const snap = await getFirestore().collection(COLL_AI_DAILY_SPEND).where("day", "==", day).get();

  const spends: DailySpendRow[] = snap.docs
    .map((d) => {
      const data = d.data();
      return {
        uid: typeof data.uid === "string" ? data.uid : d.id,
        costUsd: Number(data.cost_usd ?? 0),
        calls: Number(data.calls ?? 0),
        unpricedCalls: Number(data.unpriced_calls ?? 0),
      };
    })
    // Le plus dépensier en tête : c'est la seule ligne qu'on regarde vraiment.
    .sort((a, b) => b.costUsd - a.costUsd || b.calls - a.calls);

  return { policy: await getAiBudgetPolicy(), day, spends, defaults: DEFAULT_AI_BUDGET_POLICY };
});

interface SetAiBudgetRequest {
  policy?: Partial<AiBudgetPolicy>;
}

export const setAiBudgetFn = onCall<SetAiBudgetRequest>(callableOpts, async (req) => {
  const ctx = await requireAdmin(req, "ai_budget_policy");

  const next = req.data?.policy;
  if (!next) throw new HttpsError("invalid-argument", "policy est requis.");

  // Une saisie invalide est refusée, jamais devinée : un plafond mal lu qui
  // retomberait sur zéro se lirait « aucune limite », et personne ne le verrait
  // avant la facture.
  const readLimit = (value: unknown, label: string): number => {
    const n = Number(value);
    if (!Number.isFinite(n) || n < 0) {
      throw new HttpsError("invalid-argument", `Valeur invalide pour ${label} : ${value}`);
    }
    return n;
  };

  const policy: AiBudgetPolicy = {
    dailyCostUsdPerUser: readLimit(
      next.dailyCostUsdPerUser ?? DEFAULT_AI_BUDGET_POLICY.dailyCostUsdPerUser,
      "le plafond quotidien en dollars",
    ),
    dailyCallsPerUser: Math.trunc(
      readLimit(
        next.dailyCallsPerUser ?? DEFAULT_AI_BUDGET_POLICY.dailyCallsPerUser,
        "le plafond quotidien d'appels",
      ),
    ),
    monthlyAlertUsd: readLimit(
      next.monthlyAlertUsd ?? DEFAULT_AI_BUDGET_POLICY.monthlyAlertUsd,
      "le seuil d'alerte mensuel",
    ),
    enabled: next.enabled !== false,
  };

  await getFirestore().collection(COLL_APP_CONFIG).doc(AI_BUDGET_POLICY_DOC_ID).set(
    {
      daily_cost_usd_per_user: policy.dailyCostUsdPerUser,
      daily_calls_per_user: policy.dailyCallsPerUser,
      monthly_alert_usd: policy.monthlyAlertUsd,
      enabled: policy.enabled,
      updated_at: FieldValue.serverTimestamp(),
      updated_by: ctx.userId,
    },
    { merge: true },
  );

  invalidateAiBudgetPolicyCache();
  return { policy };
});
