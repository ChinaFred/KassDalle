/**
 * Plafond de dépense — ce qui borne la facture, là où le reste borne l'accès.
 *
 * Le projet mesurait la dépense au centime sans jamais la limiter. Le contrôle
 * d'accès dit *qui* appelle, App Check dit *quel programme* appelle ; aucun des
 * deux ne dit **combien de fois**. Restaient donc entiers : un jeton égaré sur
 * l'appareil d'un membre de la famille, un membre qui s'amuse, et surtout une
 * boucle dans notre propre code — celle-là, aucune attestation ne l'arrêtera.
 *
 * ── Deux plafonds, parce qu'un seul ne tient pas toujours ────────────────────
 *
 * Le plafond naturel est en dollars. Mais la grille tarifaire peut être
 * illisible, et le projet refuse alors de chiffrer : les appels sont enregistrés
 * **sans montant**, comptés dans `total_unpriced_calls`. Un plafond uniquement
 * monétaire s'ouvrirait donc en grand exactement pendant la panne où plus rien
 * n'est chiffré. D'où un second plafond, en **nombre d'appels**, qui ne dépend
 * d'aucun prix. Le premier des deux atteint ferme la porte.
 *
 * ── Un défaut dans le code, et c'est assumé ─────────────────────────────────
 *
 * Le projet interdit les valeurs de repli figées pour les *mesures* — un prix,
 * un taux de change : une constante y produit un montant faux présenté comme
 * vrai. Un plafond n'est pas une mesure, c'est une **décision**. Sans défaut,
 * l'absence de document Firestore signifierait « aucune limite », c'est-à-dire
 * précisément la situation qu'on corrige. Le défaut protège avant qu'on ait
 * réglé quoi que ce soit ; il s'ajuste ensuite depuis Admin, sans déploiement.
 */

import { getFirestore, FieldValue } from "firebase-admin/firestore";

import { COLL_AI_DAILY_SPEND, COLL_APP_CONFIG } from "../config";
import { logError, logWarn } from "../logging";

export const AI_BUDGET_POLICY_DOC_ID = "ai_budget_policy";

export interface AiBudgetPolicy {
  /** Plafond quotidien par compte, en dollars. `0` désactive ce plafond. */
  dailyCostUsdPerUser: number;
  /**
   * Plafond quotidien d'appels par compte. `0` le désactive.
   *
   * C'est lui qui tient quand la grille tarifaire est en panne et qu'aucun
   * appel n'est chiffré.
   */
  dailyCallsPerUser: number;
  /** Seuil d'alerte mensuel, tous comptes confondus, en dollars. `0` = aucune. */
  monthlyAlertUsd: number;
  /** Coupe les deux plafonds sans les effacer — le temps d'un import massif. */
  enabled: boolean;
}

/**
 * Défauts : larges pour un usage familial, étroits face à une boucle.
 *
 * Deux dollars par jour et par compte, c'est une soixantaine de visuels de
 * dressage ou des milliers d'appels de texte — personne ne les atteindra en
 * cuisinant. Une boucle les atteint en quelques secondes, et c'est tout
 * l'intérêt.
 */
export const DEFAULT_AI_BUDGET_POLICY: AiBudgetPolicy = {
  dailyCostUsdPerUser: 2,
  dailyCallsPerUser: 400,
  monthlyAlertUsd: 25,
  enabled: true,
};

/** Dépense d'un compte sur une journée. */
export interface DailySpend {
  costUsd: number;
  calls: number;
  /** Appels passés pendant une panne de grille : comptés, jamais chiffrés. */
  unpricedCalls: number;
}

export const EMPTY_DAILY_SPEND: DailySpend = { costUsd: 0, calls: 0, unpricedCalls: 0 };

/** Jour civil UTC, `AAAA-MM-JJ` — même convention que la période mensuelle. */
export function spendDay(date: Date): string {
  return date.toISOString().slice(0, 10);
}

/**
 * Identifiant du document de dépense : `{uid}_{AAAA-MM-JJ}`.
 *
 * Un document par compte et par jour plutôt qu'un compteur dans le profil :
 * la remise à zéro quotidienne n'a alors besoin d'aucune tâche planifiée — le
 * jour suivant écrit ailleurs — et l'historique reste lisible tel quel.
 */
export function dailySpendDocId(userId: string, day: string): string {
  return `${userId}_${day}`;
}

/** Ce que le plafond décide. `null` quand l'appel peut passer. */
export interface BudgetDenial {
  reason: "cost" | "calls";
  message: string;
}

/**
 * Décision pure — testée seule, sans Firestore.
 *
 * Le message est destiné à un membre de la famille, pas à un journal : il dit
 * ce qui est atteint et quand cela se rouvre, sans jargon ni montant du
 * plafond d'autrui.
 */
export function budgetDenial(spend: DailySpend, policy: AiBudgetPolicy): BudgetDenial | null {
  if (!policy.enabled) return null;

  if (policy.dailyCostUsdPerUser > 0 && spend.costUsd >= policy.dailyCostUsdPerUser) {
    return {
      reason: "cost",
      message:
        "Plafond de dépense IA atteint pour aujourd'hui. " +
        "Les fonctions d'IA se rouvrent demain, ou dès qu'un administrateur relève le plafond.",
    };
  }

  if (policy.dailyCallsPerUser > 0 && spend.calls >= policy.dailyCallsPerUser) {
    return {
      reason: "calls",
      message:
        "Nombre maximal d'appels d'IA atteint pour aujourd'hui. " +
        "Les fonctions d'IA se rouvrent demain, ou dès qu'un administrateur relève le plafond.",
    };
  }

  return null;
}

/** Lit un nombre positif, ou rend `fallback` si la valeur ne tient pas debout. */
function readPositive(value: unknown, fallback: number): number {
  const n = Number(value);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
}

let cachedPolicy: { value: AiBudgetPolicy; readAt: number } | null = null;
const POLICY_TTL_MS = 60_000;

export function invalidateAiBudgetPolicyCache(): void {
  cachedPolicy = null;
}

export async function getAiBudgetPolicy(): Promise<AiBudgetPolicy> {
  if (cachedPolicy && Date.now() - cachedPolicy.readAt < POLICY_TTL_MS) {
    return cachedPolicy.value;
  }

  try {
    const snap = await getFirestore()
      .collection(COLL_APP_CONFIG)
      .doc(AI_BUDGET_POLICY_DOC_ID)
      .get();
    const data = snap.data() as Record<string, unknown> | undefined;
    const policy: AiBudgetPolicy = {
      dailyCostUsdPerUser: readPositive(
        data?.daily_cost_usd_per_user,
        DEFAULT_AI_BUDGET_POLICY.dailyCostUsdPerUser,
      ),
      dailyCallsPerUser: readPositive(
        data?.daily_calls_per_user,
        DEFAULT_AI_BUDGET_POLICY.dailyCallsPerUser,
      ),
      monthlyAlertUsd: readPositive(
        data?.monthly_alert_usd,
        DEFAULT_AI_BUDGET_POLICY.monthlyAlertUsd,
      ),
      enabled: data?.enabled !== false,
    };
    cachedPolicy = { value: policy, readAt: Date.now() };
    return policy;
  } catch (err) {
    // Une politique illisible ne doit ni tout fermer ni tout ouvrir : on
    // retombe sur les défauts, qui protègent, et l'incident reste visible.
    await logError({
      message: "getAiBudgetPolicy: lecture impossible, plafonds par défaut appliqués",
      errorDescription: err instanceof Error ? err.message : String(err),
    });
    return DEFAULT_AI_BUDGET_POLICY;
  }
}

/** Dépense du jour d'un compte. Document absent = rien dépensé. */
export async function readDailySpend(userId: string, at = new Date()): Promise<DailySpend> {
  const snap = await getFirestore()
    .collection(COLL_AI_DAILY_SPEND)
    .doc(dailySpendDocId(userId, spendDay(at)))
    .get();
  const data = snap.data();
  if (!data) return EMPTY_DAILY_SPEND;
  return {
    costUsd: readPositive(data.cost_usd, 0),
    calls: readPositive(data.calls, 0),
    unpricedCalls: readPositive(data.unpriced_calls, 0),
  };
}

/**
 * Ajoute un appel à la dépense du jour.
 *
 * Appelé depuis `recordUsage`, donc **après** l'appel : le coût exact n'est
 * connu qu'une fois la réponse reçue. C'est aussi pourquoi le plafond se
 * vérifie sur le déjà-dépensé — un appel peut donc dépasser légèrement la
 * limite, jamais la doubler.
 */
export async function addToDailySpend(args: {
  userId: string;
  costUsd: number | null;
  at?: Date;
}): Promise<void> {
  const day = spendDay(args.at ?? new Date());
  await getFirestore()
    .collection(COLL_AI_DAILY_SPEND)
    .doc(dailySpendDocId(args.userId, day))
    .set(
      {
        uid: args.userId,
        day,
        calls: FieldValue.increment(1),
        cost_usd: FieldValue.increment(args.costUsd ?? 0),
        unpriced_calls: FieldValue.increment(args.costUsd == null ? 1 : 0),
        updated_at: FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
}

/**
 * Erreur levée quand un plafond est atteint.
 *
 * Un type à part plutôt qu'une `HttpsError` : ce module est appelé depuis le
 * routeur d'IA comme depuis le pipeline asynchrone, où « HTTPS » ne veut rien
 * dire. Chaque appelant la traduit dans sa propre langue.
 */
export class BudgetExceededError extends Error {
  readonly reason: BudgetDenial["reason"];

  constructor(denial: BudgetDenial) {
    super(denial.message);
    this.name = "BudgetExceededError";
    this.reason = denial.reason;
  }
}

/**
 * Refuse l'appel si le compte a déjà atteint son plafond du jour.
 *
 * Les appels non rattachés à un compte — tâches planifiées, rattrapages — ne
 * sont pas plafonnés : ils ne viennent de personne, et les borner reviendrait
 * à laisser une maintenance nocturne fermer l'application au premier réveil.
 */
export async function assertWithinDailyBudget(
  userId: string | null | undefined,
  feature: string,
): Promise<void> {
  const uid = (userId ?? "").trim();
  if (!uid) return;

  const [policy, spend] = await Promise.all([getAiBudgetPolicy(), readDailySpend(uid)]);
  const denial = budgetDenial(spend, policy);
  if (!denial) return;

  await logWarn({
    message: `Plafond de dépense atteint (${denial.reason}) — appel refusé`,
    userId: uid,
    feature,
    extra: {
      spentUsd: spend.costUsd,
      calls: spend.calls,
      unpricedCalls: spend.unpricedCalls,
      limitUsd: policy.dailyCostUsdPerUser,
      limitCalls: policy.dailyCallsPerUser,
    },
  });

  throw new BudgetExceededError(denial);
}
