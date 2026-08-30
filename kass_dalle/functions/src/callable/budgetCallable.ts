/**
 * Dépense par utilisateur, et pilotage du plafond.
 *
 * Deux questions, un seul appel, parce qu'elles ne se lisent bien qu'ensemble :
 * « qui a dépensé quoi » et « jusqu'où peut-il aller ». La première se regarde
 * sur une période — un mois, un an, tout l'historique —, la seconde sur la
 * journée en cours, seule unité où un plafond quotidien a du sens.
 *
 * Les plafonds vivent dans Firestore et se règlent depuis l'écran : le jour où
 * un import massif se fait couper au milieu, il faut pouvoir relever la limite
 * en une minute, pas en un déploiement. Même moule que le routage d'IA, la
 * grille tarifaire et l'attestation.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

import {
  REGION,
  COLL_APP_CONFIG,
  COLL_AI_DAILY_SPEND,
  COLL_AI_USAGE_MONTHLY,
  COLL_USERS,
  MAX_CALLABLE_INSTANCES,
} from "../config";
import { requireAdmin } from "./_auth";
import {
  AI_BUDGET_POLICY_DOC_ID,
  DEFAULT_AI_BUDGET_POLICY,
  FOUNDER_DAILY_BUDGET_MULTIPLIER,
  founderUid,
  getAiBudgetPolicy,
  getUsdToEurRate,
  invalidateAiBudgetPolicyCache,
  spendDay,
  type AiBudgetPolicy,
} from "../ai/budget";
import { periodOf } from "../billing/periods";

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

/**
 * Les périodes demandées, de la plus ancienne à la plus récente.
 *
 * `depth` compte les mois, `null` veut dire « depuis le début » — la même
 * convention que l'écran des coûts, pour que les trois onglets se lisent avec
 * le même sélecteur. Sans borne, on remonte jusqu'au premier mois enregistré.
 */
export function periodsToRead(depth: number | null, existing: string[]): string[] {
  const sorted = [...existing].sort();
  if (depth == null) return sorted;
  // Une profondeur nulle ou negative n est pas « aucun mois » : c est une
  // saisie qui n a pas de sens, et rendre une liste vide se lirait « rien
  // depense ». Le mois en cours est le minimum.
  const months = Math.max(1, Math.trunc(depth));

  // Recul mois par mois en UTC, comme `periodOf`. Passer par des dates plutôt
  // que par des soustractions de chaînes évite le piège de janvier.
  const wanted: string[] = [];
  const cursor = new Date();
  cursor.setUTCDate(1);
  for (let i = 0; i < months; i++) {
    wanted.push(periodOf(cursor));
    cursor.setUTCMonth(cursor.getUTCMonth() - 1);
  }
  const wantedSet = new Set(wanted);
  return sorted.filter((p) => wantedSet.has(p));
}

/** Dépense d'un compte sur la période, ventilée par poste. */
interface UserSpendRow {
  uid: string;
  costUsd: number;
  calls: number;
  byFeature: Record<string, { costUsd: number; calls: number }>;
}

function toNumber(value: unknown): number {
  const n = Number(value);
  return Number.isFinite(n) ? n : 0;
}

/**
 * Le jour demandé par l'écran, ou aujourd'hui.
 *
 * Cette chaîne entre dans une requête Firestore : elle est vérifiée sur sa
 * forme (`AAAA-MM-JJ`), sur son existence — `2026-02-31` se normaliserait en
 * mars et rendrait les dépenses d'un autre jour — et sur son sens : un jour à
 * venir n'a rien dépensé, et l'afficher comme vide se lirait « aucun appel »
 * alors que la question n'a pas encore de réponse.
 *
 * Tout ce qui ne passe pas retombe sur aujourd'hui, jamais sur une erreur :
 * l'écran doit s'ouvrir même si le client envoie n'importe quoi.
 */
export function resolveSpendDay(raw: unknown, now = new Date()): string {
  const today = spendDay(now);
  if (typeof raw !== "string") return today;
  const asked = raw.trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(asked)) return today;
  const parsed = new Date(`${asked}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime()) || spendDay(parsed) !== asked) return today;
  return asked > today ? today : asked;
}

export const getAiBudgetFn = onCall<{ depth?: number | null; day?: string | null }>(
  callableOpts,
  async (req) => {
    await requireAdmin(req, "ai_budget_policy");
    const db = getFirestore();

    const rawDepth = req.data?.depth;
    const depth =
      rawDepth == null ? null : Math.max(1, Math.min(120, Math.trunc(Number(rawDepth) || 1)));

    // Le jour regardé : celui que l'écran demande, aujourd'hui par défaut.
    const day = resolveSpendDay(req.data?.day);

    const [policy, usdToEur, founder, monthlySnap, dailySnap, usersSnap] = await Promise.all([
      getAiBudgetPolicy(),
      getUsdToEurRate(),
      founderUid(),
      db.collection(COLL_AI_USAGE_MONTHLY).get(),
      db.collection(COLL_AI_DAILY_SPEND).where("day", "==", day).get(),
      // Les identifiants ne disent rien à personne : l'écran affiche des noms.
      db.collection(COLL_USERS).get(),
    ]);

    const periods = periodsToRead(
      depth,
      monthlySnap.docs.map((d) => d.id),
    );
    const wanted = new Set(periods);

    // Agrégation par compte, puis par poste dans le compte. La ventilation vient
    // de `by_user.{uid}.by_feature`, écrite depuis la v0.20.21 : un mois plus
    // ancien n'a que son total, et l'écran le dit plutôt que d'afficher un vide
    // qui se lirait « rien dépensé ».
    const byUser = new Map<string, UserSpendRow>();
    const periodsWithoutBreakdown: string[] = [];

    for (const doc of monthlySnap.docs) {
      if (!wanted.has(doc.id)) continue;
      const users = (doc.data().by_user ?? {}) as Record<string, Record<string, unknown>>;
      let sawBreakdown = false;

      for (const [uid, raw] of Object.entries(users)) {
        const row = byUser.get(uid) ?? { uid, costUsd: 0, calls: 0, byFeature: {} };
        row.costUsd += toNumber(raw.cost_usd);
        row.calls += toNumber(raw.calls);

        const features = (raw.by_feature ?? {}) as Record<string, Record<string, unknown>>;
        for (const [feature, values] of Object.entries(features)) {
          sawBreakdown = true;
          const entry = (row.byFeature[feature] ??= { costUsd: 0, calls: 0 });
          entry.costUsd += toNumber(values.cost_usd);
          entry.calls += toNumber(values.calls);
        }
        byUser.set(uid, row);
      }

      if (!sawBreakdown && Object.keys(users).length > 0) periodsWithoutBreakdown.push(doc.id);
    }

    const names: Record<string, string> = {};
    for (const doc of usersSnap.docs) {
      const data = doc.data();
      const label = (data.display_name as string) || (data.email as string) || "";
      if (label) names[doc.id] = label;
    }

    const spends = [...byUser.values()].sort((a, b) => b.costUsd - a.costUsd || b.calls - a.calls);

    const today = dailySnap.docs.map((d) => {
      const data = d.data();
      return {
        uid: typeof data.uid === "string" ? data.uid : d.id,
        costUsd: toNumber(data.cost_usd),
        calls: toNumber(data.calls),
        unpricedCalls: toNumber(data.unpriced_calls),
      };
    });
    today.sort((a, b) => b.costUsd - a.costUsd || b.calls - a.calls);

    return {
      policy,
      defaults: DEFAULT_AI_BUDGET_POLICY,
      // Sans taux, l'écran affiche les dollars tels quels plutôt qu'une
      // conversion inventée — et le plafond en euros est alors inapplicable.
      usdToEur,
      founderUid: founder,
      founderMultiplier: FOUNDER_DAILY_BUDGET_MULTIPLIER,
      day,
      // Le jour courant voyage à côté du jour regardé : sans lui, l'écran ne
      // peut pas savoir s'il montre aujourd'hui ou un jour passé, et un plafond
      // affiché sur une journée close se lirait comme un plafond en cours.
      currentDay: spendDay(new Date()),
      periods,
      periodsWithoutBreakdown,
      names,
      spends,
      today,
    };
  },
);

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
    dailyCostEurPerUser: readLimit(
      next.dailyCostEurPerUser ?? DEFAULT_AI_BUDGET_POLICY.dailyCostEurPerUser,
      "le plafond quotidien en euros",
    ),
    dailyCallsPerUser: Math.trunc(
      readLimit(
        next.dailyCallsPerUser ?? DEFAULT_AI_BUDGET_POLICY.dailyCallsPerUser,
        "le plafond quotidien d'appels",
      ),
    ),
    monthlyAlertEur: readLimit(
      next.monthlyAlertEur ?? DEFAULT_AI_BUDGET_POLICY.monthlyAlertEur,
      "le seuil d'alerte mensuel",
    ),
    enabled: next.enabled !== false,
  };

  await getFirestore().collection(COLL_APP_CONFIG).doc(AI_BUDGET_POLICY_DOC_ID).set(
    {
      daily_cost_eur_per_user: policy.dailyCostEurPerUser,
      daily_calls_per_user: policy.dailyCallsPerUser,
      monthly_alert_eur: policy.monthlyAlertEur,
      enabled: policy.enabled,
      updated_at: FieldValue.serverTimestamp(),
      updated_by: ctx.userId,
    },
    { merge: true },
  );

  invalidateAiBudgetPolicyCache();
  return { policy };
});
