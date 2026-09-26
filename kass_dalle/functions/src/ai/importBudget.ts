/**
 * Plafond de dépense d'un import de livre.
 *
 * Le plafond du jour borne un compte, pas un import. Celui du fondateur vaut
 * cent fois le plafond commun — deux cents euros par jour —, et l'import du livre
 * de Jamie Oliver (26 septembre 2026) a coûté 59,89 $ affichés, sans que rien ne
 * l'arrête ni ne le signale avant la fin. L'utilisateur fixe donc un plafond sur
 * l'écran de confirmation, et ce module le fait respecter.
 *
 * ── Un compteur par scan ─────────────────────────────────────────────────────
 *
 * Un import de livre est un seul scan qui déclenche une centaine de jobs. Chaque
 * appel d'IA ajoute son coût à `scan_spend/{scanId}` (`recordUsage`), et chaque
 * tranche relit ce document avant son premier appel. Le contrôle vaut pour le
 * pipeline d'import seulement : la nutrition calculée plus tard sur ces recettes
 * porte le même `scanId`, et un plafond atteint ne doit pas la bloquer.
 *
 * Comme le plafond du jour, il se vérifie sur le déjà-dépensé : les tranches qui
 * tournent en même temps peuvent le dépasser d'un appel chacune, jamais le doubler.
 *
 * ── Relancer relève le plafond ───────────────────────────────────────────────
 *
 * Une tranche arrêtée par le plafond se relance depuis la file. Sans issue, elle
 * échouerait au même endroit à chaque fois. Relancer une tranche, quand le
 * plafond est atteint, l'ouvre d'un palier de la taille du plafond initial
 * (`step_usd`) au-dessus de ce qui est déjà dépensé. Relancer est le geste par
 * lequel l'utilisateur dit qu'il accepte de dépenser davantage.
 *
 * Le plafond s'exprime en **dollars**, l'unité dans laquelle un coût est mesuré
 * et stocké. L'écran le montre en euros quand un taux est connu.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";

import { COLL_SCAN_SPEND } from "../config";
import { logInfo, logWarn } from "../logging";
import { BudgetExceededError, getUsdToEurRate, type BudgetDenial } from "./budget";

/**
 * Plafond proposé par tranche quand aucune mesure d'import passé n'existe.
 *
 * Une décision, pas une mesure — la même distinction que pour le plafond du
 * jour : sans défaut, l'absence d'estimation ouvrirait l'import en grand, ce
 * qu'on corrige. La valeur couvre trois à quatre fois le coût attendu d'une
 * tranche de trois pages. L'utilisateur la lit et la change sur l'écran.
 */
export const DEFAULT_IMPORT_BUDGET_PER_WINDOW_USD = 0.5;

/** Marge du plafond proposé sur l'estimation : la moitié en plus. */
export const IMPORT_BUDGET_MARGIN = 1.5;

/** Ce que le scan a dépensé, et le plafond qui le borne, en dollars. */
export interface ScanSpend {
  costUsd: number;
  calls: number;
  /** Appels passés pendant une panne de grille : comptés, jamais chiffrés. */
  unpricedCalls: number;
  /** `null` : ce scan n'a pas de plafond. */
  limitUsd: number | null;
  /** Taille du palier ajouté à chaque relance qui trouve le plafond atteint. */
  stepUsd: number | null;
}

export const EMPTY_SCAN_SPEND: ScanSpend = {
  costUsd: 0,
  calls: 0,
  unpricedCalls: 0,
  limitUsd: null,
  stepUsd: null,
};

function positive(value: unknown): number | null {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n : null;
}

/** Le plafond écrit sur un job, ou `null` s'il est absent ou ne tient pas debout. */
export function parseBudgetLimit(value: unknown): number | null {
  return typeof value === "number" || typeof value === "string" ? positive(value) : null;
}

/** Relit le document `scan_spend/{scanId}`. Document absent = rien dépensé, aucun plafond. */
export function readScanSpend(data: Record<string, unknown> | undefined): ScanSpend {
  if (!data) return EMPTY_SCAN_SPEND;
  const cost = Number(data.cost_usd);
  const calls = Number(data.calls);
  const unpriced = Number(data.unpriced_calls);
  return {
    costUsd: Number.isFinite(cost) && cost > 0 ? cost : 0,
    calls: Number.isFinite(calls) && calls > 0 ? calls : 0,
    unpricedCalls: Number.isFinite(unpriced) && unpriced > 0 ? unpriced : 0,
    limitUsd: positive(data.limit_usd),
    stepUsd: positive(data.step_usd),
  };
}

/**
 * Plafond à proposer sur l'écran de confirmation, en dollars entiers.
 *
 * L'estimation mesurée sur les imports passés, plus la moitié. Sans estimation,
 * `DEFAULT_IMPORT_BUDGET_PER_WINDOW_USD` par tranche. Arrondi au dollar
 * supérieur, et un dollar au moins : un plafond proposé à trois centimes ne
 * laisserait pas passer la première tranche.
 */
export function suggestImportBudgetUsd(args: {
  windows: number;
  estimatedCostUsd: number | null;
}): number {
  const raw =
    args.estimatedCostUsd != null && args.estimatedCostUsd > 0
      ? args.estimatedCostUsd * IMPORT_BUDGET_MARGIN
      : Math.max(0, args.windows) * DEFAULT_IMPORT_BUDGET_PER_WINDOW_USD;
  return Math.max(1, Math.ceil(raw));
}

/** Un montant en dollars, ou en euros quand un taux est connu — « 12,40 € ». */
export function formatBudgetAmount(usd: number, usdToEur: number | null): string {
  const useEur = usdToEur != null && usdToEur > 0;
  const value = useEur ? usd * usdToEur : usd;
  return `${value.toFixed(2).replace(".", ",")} ${useEur ? "€" : "$"}`;
}

/**
 * Décision pure : le plafond de l'import est-il atteint ?
 *
 * Un scan sans plafond passe toujours. Un appel non chiffré n'apporte aucun
 * montant et n'avance pas le compteur : le plafond ne peut pas le juger.
 */
export function importBudgetDenial(args: {
  spend: ScanSpend;
  usdToEur: number | null;
}): BudgetDenial | null {
  const { spend, usdToEur } = args;
  if (spend.limitUsd == null || spend.costUsd < spend.limitUsd) return null;
  return {
    reason: "import",
    message:
      `Plafond de cet import atteint : ${formatBudgetAmount(spend.costUsd, usdToEur)} dépensés ` +
      `pour ${formatBudgetAmount(spend.limitUsd, usdToEur)} autorisés. ` +
      "Relancer une tranche depuis la file ouvre un nouveau palier de la même taille.",
  };
}

/**
 * Nouveau plafond après une relance, ou `null` s'il n'y a rien à relever.
 *
 * On ne relève que si le plafond est atteint : relancer une tranche tombée pour
 * une autre raison, à mi-chemin du plafond, n'accorde aucun budget de plus.
 * Plusieurs relances à la suite convergent vers le même résultat : la première
 * relève, les suivantes trouvent un plafond qui n'est plus atteint.
 */
export function raisedImportLimit(spend: ScanSpend): number | null {
  if (spend.limitUsd == null || spend.stepUsd == null) return null;
  if (spend.costUsd < spend.limitUsd) return null;
  return spend.costUsd + spend.stepUsd;
}

/** Ajoute un appel au compteur du scan. Appelé depuis `recordUsage`, après l'appel. */
export async function addToScanSpend(args: {
  scanId: string;
  costUsd: number | null;
}): Promise<void> {
  await getFirestore()
    .collection(COLL_SCAN_SPEND)
    .doc(args.scanId)
    .set(
      {
        scan_id: args.scanId,
        calls: FieldValue.increment(1),
        cost_usd: FieldValue.increment(args.costUsd ?? 0),
        unpriced_calls: FieldValue.increment(args.costUsd == null ? 1 : 0),
        updated_at: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
}

/**
 * Pose le plafond d'un import, à l'ouverture du livre.
 *
 * Idempotent, et jamais à la baisse : un rejeu du job parent après une relance
 * qui a relevé le plafond ne doit pas le ramener au chiffre du départ.
 */
export async function setImportCeiling(args: {
  scanId: string;
  userId: string;
  limitUsd: number;
}): Promise<void> {
  const ref = getFirestore().collection(COLL_SCAN_SPEND).doc(args.scanId);
  await getFirestore().runTransaction(async (tx) => {
    const current = readScanSpend((await tx.get(ref)).data());
    tx.set(
      ref,
      {
        scan_id: args.scanId,
        user_id: args.userId,
        limit_usd: Math.max(current.limitUsd ?? 0, args.limitUsd),
        step_usd: current.stepUsd ?? args.limitUsd,
        limit_set_at: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  });
}

/** Relève le plafond d'un import quand une tranche est relancée. Rend `true` s'il a bougé. */
export async function raiseImportCeiling(args: {
  scanId: string;
  userId?: string;
  jobId?: string;
}): Promise<boolean> {
  const ref = getFirestore().collection(COLL_SCAN_SPEND).doc(args.scanId);
  const result = await getFirestore().runTransaction(async (tx) => {
    const spend = readScanSpend((await tx.get(ref)).data());
    const next = raisedImportLimit(spend);
    if (next == null) return null;
    tx.update(ref, { limit_usd: next, limit_raised_at: FieldValue.serverTimestamp() });
    return { from: spend.limitUsd, to: next, spent: spend.costUsd };
  });
  if (!result) return false;
  await logInfo({
    message: "Plafond de l'import relevé par une relance",
    moduleType: "IMPORT",
    scanId: args.scanId,
    userId: args.userId,
    jobId: args.jobId,
    extra: { limitUsdBefore: result.from, limitUsdAfter: result.to, spentUsd: result.spent },
  });
  return true;
}

/**
 * Refuse l'appel si l'import a atteint son plafond.
 *
 * À appeler avant le premier appel d'IA d'une tranche de livre. Un scan sans
 * plafond, ou sans document, passe.
 */
export async function assertWithinImportBudget(
  scanId: string | null | undefined,
  feature: string,
): Promise<void> {
  const id = (scanId ?? "").trim();
  if (!id) return;

  const snap = await getFirestore().collection(COLL_SCAN_SPEND).doc(id).get();
  const spend = readScanSpend(snap.data());
  if (spend.limitUsd == null) return;

  const usdToEur = await getUsdToEurRate();
  const denial = importBudgetDenial({ spend, usdToEur });
  if (!denial) return;

  await logWarn({
    message: "Plafond de l'import atteint — tranche arrêtée avant son appel d'IA",
    scanId: id,
    feature,
    moduleType: "IMPORT",
    extra: {
      spentUsd: spend.costUsd,
      limitUsd: spend.limitUsd,
      calls: spend.calls,
      unpricedCalls: spend.unpricedCalls,
    },
  });
  throw new BudgetExceededError(denial);
}
