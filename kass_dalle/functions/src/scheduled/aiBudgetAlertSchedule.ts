/**
 * Alerte de dépense mensuelle.
 *
 * Le plafond quotidien borne ce qu'un compte peut dépenser en une journée. Il ne
 * dit rien de la somme : cinq comptes à un dollar par jour font cent cinquante
 * dollars au bout du mois sans qu'aucune limite n'ait jamais été atteinte.
 *
 * Cette vérification tourne **tous les jours**, et pas le 1er du mois suivant :
 * une alerte qui arrive après la facture n'est pas une alerte, c'est un
 * constat. Elle compare le cumul du mois en cours au seuil réglé dans
 * *Admin › Coûts*, et n'écrit qu'une fois par mois — une alerte répétée chaque
 * matin cesse d'être lue au troisième jour.
 */

import { onSchedule } from "firebase-functions/v2/scheduler";
import { getFirestore, FieldValue } from "firebase-admin/firestore";

import { COLL_AI_USAGE_MONTHLY, COLL_APP_CONFIG, REGION } from "../config";
import { logError, logInfo, logWarn } from "../logging";
import { getAiBudgetPolicy } from "../ai/budget";
import { periodOf } from "../billing/periods";

/** Où l'on retient qu'une alerte a déjà été émise, et pour quel mois. */
export const AI_BUDGET_ALERT_DOC_ID = "ai_budget_alert";

/**
 * Faut-il alerter ? Fonction pure, testée seule.
 *
 * Trois raisons de se taire : aucun seuil réglé, seuil non franchi, ou alerte
 * déjà émise pour ce mois-ci.
 */
export function shouldAlert(args: {
  monthlyAlertUsd: number;
  spentUsd: number;
  alreadyAlertedPeriod: string | null;
  period: string;
}): boolean {
  if (!(args.monthlyAlertUsd > 0)) return false;
  if (args.spentUsd < args.monthlyAlertUsd) return false;
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
      const [policy, monthly, alertDoc] = await Promise.all([
        getAiBudgetPolicy(),
        db.collection(COLL_AI_USAGE_MONTHLY).doc(period).get(),
        db.collection(COLL_APP_CONFIG).doc(AI_BUDGET_ALERT_DOC_ID).get(),
      ]);

      const spentUsd = Number(monthly.data()?.total_cost_usd ?? 0);
      // Les appels non chiffrés ne s'additionnent pas au montant — ils le
      // rendent incomplet. Une alerte qui se tait parce qu'une panne de grille
      // a rendu le mois illisible serait un silence trompeur : on le dit.
      const unpricedCalls = Number(monthly.data()?.total_unpriced_calls ?? 0);
      const alreadyAlertedPeriod = (alertDoc.data()?.period as string | undefined)?.trim() || null;

      if (
        !shouldAlert({
          monthlyAlertUsd: policy.monthlyAlertUsd,
          spentUsd,
          alreadyAlertedPeriod,
          period,
        })
      ) {
        await logInfo({
          message: `Alerte de budget : rien à signaler (${period})`,
          extra: { spentUsd, threshold: policy.monthlyAlertUsd, unpricedCalls },
        });
        return;
      }

      await logWarn({
        message:
          `Dépense d'IA du mois ${period} : ${spentUsd.toFixed(2)} $ — ` +
          `seuil d'alerte ${policy.monthlyAlertUsd.toFixed(2)} $ franchi`,
        extra: { period, spentUsd, threshold: policy.monthlyAlertUsd, unpricedCalls },
      });

      // Le drapeau est écrit APRÈS l'alerte : si l'écriture du journal échoue,
      // l'alerte sera retentée demain plutôt que perdue en silence.
      await db.collection(COLL_APP_CONFIG).doc(AI_BUDGET_ALERT_DOC_ID).set(
        {
          period,
          spent_usd: spentUsd,
          threshold_usd: policy.monthlyAlertUsd,
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
