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
 * Le plafond se règle en **euros**, la monnaie du foyer. Les fournisseurs, eux,
 * facturent en dollars, et c'est en dollars que le coût d'un appel est calculé
 * puis stocké : la comparaison passe donc par le taux de change relevé sur la
 * facture (`app_config/currency_rate`).
 *
 * Deux choses peuvent manquer, et chacune ouvrirait le plafond en grand :
 *
 *  - **la grille tarifaire**, sans laquelle le projet refuse de chiffrer — les
 *    appels sont alors enregistrés sans montant ;
 *  - **le taux de change**, sans lequel une dépense en dollars ne se compare à
 *    aucun plafond en euros. Le projet interdit d'inventer un taux : un montant
 *    faux vaut moins qu'un montant absent.
 *
 * D'où un second plafond, en **nombre d'appels**, qui ne dépend ni d'un prix ni
 * d'un taux. C'est lui qui tient pendant ces deux pannes, et le premier des
 * deux atteint ferme la porte.
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
import { getAuth } from "firebase-admin/auth";

import { COLL_AI_DAILY_SPEND, COLL_APP_CONFIG } from "../config";
import { logError, logWarn } from "../logging";
import { FOUNDER_EMAIL } from "../triggers/founderRole";

export const AI_BUDGET_POLICY_DOC_ID = "ai_budget_policy";

/**
 * Le compte fondateur dispose de cent fois le plafond commun.
 *
 * Règle codée en dur, et volontairement : elle dit que le propriétaire du
 * projet est aussi celui qui l'éprouve — c'est lui qui importe des livres
 * entiers, régénère des séries de visuels et essaie les moteurs. La poser en
 * base la rendrait modifiable par n'importe quel administrateur, ce qui en
 * ferait un privilège transmissible plutôt qu'une caractéristique du
 * propriétaire.
 *
 * Passé de cinq à dix le 19 août 2026 : mettre au point l'extraction demande de
 * rescanner la même page des dizaines de fois, et le plafond se fermait au
 * milieu d'une session d'essais — le seul moment où l'on a besoin d'appeler
 * beaucoup, et le seul où être coupé ne protège de rien.
 *
 * Passé de dix à cent le 26 septembre 2026, à la demande du propriétaire :
 * l'import d'un livre entier crée une centaine de jobs, chacun déclenchant
 * plusieurs appels d'IA, et le plafond se refermait avant la fin du livre.
 *
 * Elle ne dispense de rien : le fondateur reste plafonné, cent fois plus haut —
 * deux cents euros et quarante mille appels par jour avec les défauts. Une
 * boucle atteint deux cents euros aussi vite que deux.
 */
export const FOUNDER_DAILY_BUDGET_MULTIPLIER = 100;

/**
 * Compte retenu quand l'appel n'est rattaché à personne (uid absent ou vide).
 * Même clé que la ligne d'usage (`ai_usage.uid`) et que l'écran des plafonds —
 * un seul nom pour la même dépense.
 */
export const UNATTRIBUTED = "system_unattributed";

/**
 * Compte auquel s'impute une recette sans propriétaire (`created_by` absent ou
 * vide).
 *
 * Les déclencheurs d'une recette imputent la dépense à son `created_by`. Un
 * `created_by` vide passait l'appel hors de tout plafond : un lecteur vidait le
 * champ de sa recette, puis la réécrivait autant de fois qu'il voulait. Les
 * règles Firestore figent désormais ce champ ; ce compte couvre les documents
 * antérieurs et toute écriture serveur qui l'oublierait. Plafond commun
 * (multiplicateur 1), partagé par toutes les recettes orphelines.
 */
export const ORPHAN_RECIPE_USER_ID = "system_recipe_without_owner";

/**
 * Multiplicateur du compte `UNATTRIBUTED` : celui du fondateur.
 *
 * Y tombent les appels de modèle passés **sans aucun uid** — un traitement
 * serveur qui n'en transmet pas. Le rattrapage nutrition nocturne n'en fait
 * pas partie : il impute chaque recette à son `created_by`, ou à
 * `ORPHAN_RECIPE_USER_ID` (×1). L'enrichissement des référentiels
 * (`nutrition/aiEnrichment.ts`, `nutrition/fryAbsorption.ts`) remplace un uid
 * absent par la chaîne littérale `"system"` : ce compte-là est un compte
 * ordinaire pour le plafond (×1), distinct de `UNATTRIBUTED`.
 *
 * Plafonné quand même — deux cents euros et quarante mille appels par jour
 * avec les défauts : une boucle s'arrête aussi.
 */
export const SYSTEM_DAILY_BUDGET_MULTIPLIER = FOUNDER_DAILY_BUDGET_MULTIPLIER;

/** Le compte de plafond d'un appel : l'uid s'il existe, le compte système sinon. */
export function budgetUserId(userId: string | null | undefined): string {
  const uid = (userId ?? "").trim();
  return uid.length > 0 ? uid : UNATTRIBUTED;
}

/**
 * Le compte auquel s'impute une recette : son `created_by`, ou le compte des
 * recettes orphelines. Jamais vide, donc jamais hors plafond.
 */
export function recipeBudgetUserId(createdBy: unknown): string {
  const uid = typeof createdBy === "string" ? createdBy.trim() : "";
  return uid.length > 0 ? uid : ORPHAN_RECIPE_USER_ID;
}

export interface AiBudgetPolicy {
  /** Plafond quotidien par compte, en **euros**. `0` désactive ce plafond. */
  dailyCostEurPerUser: number;
  /**
   * Plafond quotidien d'appels par compte. `0` le désactive.
   *
   * C'est lui qui tient quand la grille tarifaire ou le taux de change
   * manquent, et qu'aucun montant n'est comparable.
   */
  dailyCallsPerUser: number;
  /** Seuil d'alerte mensuel, tous comptes confondus, en euros. `0` = aucune. */
  monthlyAlertEur: number;
  /** Coupe les deux plafonds sans les effacer — le temps d'un import massif. */
  enabled: boolean;
}

/**
 * Défauts : larges pour un usage familial, étroits face à une boucle.
 *
 * Deux euros par jour et par compte, c'est une soixantaine de visuels de
 * dressage ou des milliers d'appels de texte — personne ne les atteindra en
 * cuisinant. Une boucle les atteint en quelques secondes, et c'est tout
 * l'intérêt.
 */
export const DEFAULT_AI_BUDGET_POLICY: AiBudgetPolicy = {
  dailyCostEurPerUser: 2,
  dailyCallsPerUser: 400,
  monthlyAlertEur: 25,
  enabled: true,
};

/** Dépense d'un compte sur une journée. Le montant est en **dollars**. */
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
  /** `import` : le plafond fixé pour un livre entier, voir `importBudget.ts`. */
  reason: "cost" | "calls" | "import";
  message: string;
}

/**
 * Décision pure — testée seule, sans Firestore ni compte Auth.
 *
 * `usdToEur` vaut `null` quand aucun taux n'est disponible : le plafond en
 * euros est alors **inapplicable**, et seul le plafond d'appels décide. Le taux
 * ne s'invente pas, et fermer l'application faute de taux transformerait un
 * incident de conversion en panne totale.
 *
 * `multiplier` porte la règle du fondateur. Il multiplie **les deux** plafonds :
 * n'agir que sur l'argent laisserait le compteur d'appels bloquer précisément
 * celui qui a le droit d'en faire cinq fois plus.
 */
export function budgetDenial(args: {
  spend: DailySpend;
  policy: AiBudgetPolicy;
  usdToEur: number | null;
  multiplier?: number;
}): BudgetDenial | null {
  const { spend, policy, usdToEur } = args;
  const multiplier = args.multiplier && args.multiplier > 0 ? args.multiplier : 1;
  if (!policy.enabled) return null;

  const costLimitEur = policy.dailyCostEurPerUser * multiplier;
  const callsLimit = policy.dailyCallsPerUser * multiplier;

  if (costLimitEur > 0 && usdToEur != null && usdToEur > 0) {
    const spentEur = spend.costUsd * usdToEur;
    if (spentEur >= costLimitEur) {
      return {
        reason: "cost",
        message:
          "Plafond de dépense IA atteint pour aujourd'hui. " +
          "Les fonctions d'IA se rouvrent demain, ou dès qu'un administrateur relève le plafond.",
      };
    }
  }

  if (callsLimit > 0 && spend.calls >= callsLimit) {
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
      dailyCostEurPerUser: readPositive(
        data?.daily_cost_eur_per_user,
        DEFAULT_AI_BUDGET_POLICY.dailyCostEurPerUser,
      ),
      dailyCallsPerUser: readPositive(
        data?.daily_calls_per_user,
        DEFAULT_AI_BUDGET_POLICY.dailyCallsPerUser,
      ),
      monthlyAlertEur: readPositive(
        data?.monthly_alert_eur,
        DEFAULT_AI_BUDGET_POLICY.monthlyAlertEur,
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

let cachedRate: { value: number | null; readAt: number } | null = null;

/**
 * Taux dollar → euro relevé sur la facturation, ou `null`.
 *
 * `null` n'est pas une erreur : c'est l'état d'un projet dont aucune facture
 * n'a encore livré son taux. Aucun repli figé — le projet a déjà retiré un
 * « 0,92 » qui dormait dans le code, pour la raison qui vaut ici : un plafond
 * appliqué au mauvais taux refuse ou laisse passer sans que personne ne le sache.
 */
export async function getUsdToEurRate(): Promise<number | null> {
  if (cachedRate && Date.now() - cachedRate.readAt < POLICY_TTL_MS) {
    return cachedRate.value;
  }
  try {
    const snap = await getFirestore().collection(COLL_APP_CONFIG).doc("currency_rate").get();
    const data = snap.data() as Record<string, unknown> | undefined;
    // `usd_to_account_rate` est le taux constaté sur la facture Google, écrit
    // par la réconciliation ; `usd_to_eur` est l'ancien nom, encore présent sur
    // les projets amorcés avant lui. Le premier des deux qui tient debout gagne.
    const raw = Number(data?.usd_to_account_rate ?? data?.usd_to_eur);
    const value = Number.isFinite(raw) && raw > 0 ? raw : null;
    cachedRate = { value, readAt: Date.now() };
    return value;
  } catch (err) {
    await logError({
      message: "getUsdToEurRate: lecture impossible, plafond en euros inapplicable",
      errorDescription: err instanceof Error ? err.message : String(err),
    });
    return null;
  }
}

let cachedFounderUid: { value: string | null; readAt: number } | null = null;
/** Une heure : l'identifiant du fondateur ne change jamais en pratique. */
const FOUNDER_UID_TTL_MS = 3_600_000;

/**
 * L'identifiant du compte fondateur, résolu depuis **Auth**.
 *
 * Pas depuis le champ `email` du document utilisateur : un administrateur peut
 * l'écrire, et un privilège ne se fonde pas sur une donnée qu'un tiers peut
 * poser. Auth fait autorité, et la réponse est gardée en mémoire une heure —
 * une lecture par instance froide, pas une par appel.
 */
export async function founderUid(): Promise<string | null> {
  if (cachedFounderUid && Date.now() - cachedFounderUid.readAt < FOUNDER_UID_TTL_MS) {
    return cachedFounderUid.value;
  }
  try {
    const user = await getAuth().getUserByEmail(FOUNDER_EMAIL);
    cachedFounderUid = { value: user.uid, readAt: Date.now() };
    return user.uid;
  } catch {
    // Compte absent — projet neuf, ou adresse jamais connectée. Sans identifiant,
    // personne n'obtient le multiplicateur : c'est le sens qui protège.
    cachedFounderUid = { value: null, readAt: Date.now() };
    return null;
  }
}

/**
 * Le multiplicateur de plafond d'un compte : cent pour le fondateur et pour le
 * compte système, un sinon — recettes orphelines comprises.
 */
export async function budgetMultiplierFor(userId: string): Promise<number> {
  if (userId === UNATTRIBUTED) return SYSTEM_DAILY_BUDGET_MULTIPLIER;
  return (await founderUid()) === userId ? FOUNDER_DAILY_BUDGET_MULTIPLIER : 1;
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
 * Un appel sans uid s'impute au compte système (`UNATTRIBUTED`), plafonné cent
 * fois plus haut. Il passait
 * auparavant sans aucun contrôle : tout chemin qui perdait l'uid de l'appelant
 * (une recette au `created_by` vidé) sortait du plafond.
 */
export async function assertWithinDailyBudget(
  userId: string | null | undefined,
  feature: string,
): Promise<void> {
  const uid = budgetUserId(userId);

  const [policy, spend, usdToEur, multiplier] = await Promise.all([
    getAiBudgetPolicy(),
    readDailySpend(uid),
    getUsdToEurRate(),
    budgetMultiplierFor(uid),
  ]);

  // Un plafond en euros qu'aucun taux ne permet d'évaluer doit se voir : sans
  // cette trace, la protection paraîtrait active alors que seul le compteur
  // d'appels tient encore.
  if (usdToEur == null && policy.enabled && policy.dailyCostEurPerUser > 0) {
    await logWarn({
      message: "Plafond en euros inapplicable : aucun taux de change relevé",
      userId: uid,
      feature,
      extra: { calls: spend.calls, limitCalls: policy.dailyCallsPerUser * multiplier },
    });
  }

  const denial = budgetDenial({ spend, policy, usdToEur, multiplier });
  if (!denial) return;

  await logWarn({
    message: `Plafond de dépense atteint (${denial.reason}) — appel refusé`,
    userId: uid,
    feature,
    extra: {
      spentUsd: spend.costUsd,
      spentEur: usdToEur != null ? spend.costUsd * usdToEur : null,
      calls: spend.calls,
      unpricedCalls: spend.unpricedCalls,
      limitEur: policy.dailyCostEurPerUser * multiplier,
      limitCalls: policy.dailyCallsPerUser * multiplier,
      multiplier,
    },
  });

  throw new BudgetExceededError(denial);
}
