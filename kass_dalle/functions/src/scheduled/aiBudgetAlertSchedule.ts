/**
 * Alerte de dépense mensuelle.
 *
 * Le plafond quotidien borne ce qu'un compte peut dépenser en une journée. Il ne
 * dit rien de la somme : cinq comptes à un euro par jour font cent cinquante
 * euros au bout du mois sans qu'aucune limite n'ait jamais été atteinte.
 *
 * Cette vérification tourne **tous les jours**, et pas le 1er du mois suivant :
 * une alerte qui arrive après la facture n'est pas une alerte, c'est un
 * constat. Elle compare le cumul du mois en cours au seuil réglé dans
 * *Admin › Dépense par utilisateur*, et n'écrit qu'une fois par mois — une
 * alerte répétée chaque matin cesse d'être lue au troisième jour.
 *
 * Le cumul est stocké en dollars, le seuil se règle en euros : la comparaison
 * passe par le taux relevé sur la facture. Sans taux, elle ne se fait pas — et
 * le dire vaut mieux que se taire, un silence se lisant « rien à signaler ».
 */

import { onSchedule } from "firebase-functions/v2/scheduler";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

import { COLL_AI_USAGE_MONTHLY, COLL_APP_CONFIG, REGION } from "../config";
import { logError, logInfo, logWarn } from "../logging";
import { getAiBudgetPolicy, getUsdToEurRate } from "../ai/budget";
import { periodOf } from "../billing/periods";

/** Où l'on retient qu'une alerte a déjà été émise, et pour quel mois. */
export const AI_BUDGET_ALERT_DOC_ID = "ai_budget_alert";

/**
 * Faut-il alerter ? Fonction pure, testée seule.
 *
 * Quatre raisons de se taire : aucun seuil réglé, dépense non convertible
 * (`spentEur` à `null`, faute de taux), seuil non franchi, ou alerte déjà émise
 * pour ce mois-ci.
 */
export function shouldAlert(args: {
  monthlyAlertEur: number;
  spentEur: number | null;
  alreadyAlertedPeriod: string | null;
  period: string;
}): boolean {
  if (!(args.monthlyAlertEur > 0)) return false;
  if (args.spentEur == null) return false;
  if (args.spentEur < args.monthlyAlertEur) return false;
  return args.alreadyAlertedPeriod !== args.period;
}

export const scheduledAiBudgetAlert = onSchedule(
  {
    // Tous les jours à 7 h, heure de Paris — après la nuit, avant la journée.
    schedule: "0 7 * * *",
    timeZone: "Europe/Paris",
    region: REGION,
    memory: "256MiB",
    timeoutSeconds: 120,
    retryCount: 1,
  },
  async () => {
    const db = getFirestore();
    const period = periodOf(new Date());

    try {
      const [policy, usdToEur, monthly, alertDoc] = await Promise.all([
        getAiBudgetPolicy(),
        getUsdToEurRate(),
        db.collection(COLL_AI_USAGE_MONTHLY).doc(period).get(),
        db.collection(COLL_APP_CONFIG).doc(AI_BUDGET_ALERT_DOC_ID).get(),
      ]);

      const spentUsd = Number(monthly.data()?.total_cost_usd ?? 0);
      const spentEur = usdToEur != null ? spentUsd * usdToEur : null;
      // Les appels non chiffrés ne s'additionnent pas au montant — ils le
      // rendent incomplet. Une alerte qui se tait parce qu'une panne de grille
      // a rendu le mois illisible serait un silence trompeur : on le dit.
      const unpricedCalls = Number(monthly.data()?.total_unpriced_calls ?? 0);
      const alreadyAlertedPeriod = (alertDoc.data()?.period as string | undefined)?.trim() || null;

      // Sans taux, le seuil en euros n'est pas évaluable. Se taire laisserait
      // croire que rien n'a été franchi ; on dit plutôt qu'on ne sait pas.
      if (spentEur == null && policy.monthlyAlertEur > 0) {
        await logWarn({
          message:
            "Alerte de budget non évaluable : aucun taux de change relevé, " +
            `dépense du mois ${period} connue en dollars seulement`,
          extra: { spentUsd, threshold: policy.monthlyAlertEur, unpricedCalls },
        });
        return;
      }

      if (
        !shouldAlert({
          monthlyAlertEur: policy.monthlyAlertEur,
          spentEur,
          alreadyAlertedPeriod,
          period,
        })
      ) {
        await logInfo({
          message: `Alerte de budget : rien à signaler (${period})`,
          extra: { spentUsd, spentEur, threshold: policy.monthlyAlertEur, unpricedCalls },
        });
        return;
      }

      await logWarn({
        message:
          `Dépense d'IA du mois ${period} : ${(spentEur ?? 0).toFixed(2)} € — ` +
          `seuil d'alerte ${policy.monthlyAlertEur.toFixed(2)} € franchi`,
        extra: { period, spentUsd, spentEur, threshold: policy.monthlyAlertEur, unpricedCalls },
      });

      // Le drapeau est écrit APRÈS l'alerte : si l'écriture du journal échoue,
      // l'alerte sera retentée demain plutôt que perdue en silence.
      await db.collection(COLL_APP_CONFIG).doc(AI_BUDGET_ALERT_DOC_ID).set(
        {
          period,
          spent_usd: spentUsd,
          spent_eur: spentEur,
          threshold_eur: policy.monthlyAlertEur,
          unpriced_calls: unpricedCalls,
          raised_at: FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
    } catch (err) {
      await logError({
        message: "Alerte de budget mensuel : vérification impossible",
        errorDescription: err instanceof Error ? err.message : String(err),
        extra: { period },
      });
    }
  },
);
