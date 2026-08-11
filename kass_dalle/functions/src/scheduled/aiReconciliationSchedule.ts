/**
 * Réconciliation comptable IA — exécution planifiée mensuelle.
 *
 * Compare, mois par mois, ce que le suivi interne a estimé (`ai_usage`, calculé
 * appel par appel avec la grille tarifaire) à ce que Google a réellement facturé
 * (export BigQuery). L'écart part dans `ai_reconciliation_monthly/{period}`.
 *
 * Pourquoi une tâche planifiée et pas seulement un bouton : le rapport ne sert
 * qu'à répondre à une question qu'on ne se pose pas — « est-ce que mon suivi de
 * coûts dit la vérité ? ». Une vérification qu'il faut penser à déclencher est
 * une vérification qui n'a pas lieu, et une dérive de tarification reste
 * invisible d'autant plus longtemps que le chiffre affiché reste plausible.
 * Le bouton manuel existe en plus, pour le jour où on veut regarder.
 *
 * Le rapport porte sur le MOIS ÉCOULÉ, pas sur le mois en cours : l'export de
 * facturation GCP se consolide avec un délai de quelques jours, et un mois
 * partiel produirait un écart qui ne dit rien. D'où l'exécution le 4 du mois.
 */

import { onSchedule } from "firebase-functions/v2/scheduler";

import { REGION } from "../config";
import { logError, logInfo } from "../logging";
import { runAiReconciliation } from "../callable/billingCallable";
import { previousPeriod } from "../billing/periods";

export const scheduledAiReconciliation = onSchedule(
  {
    // Le 4 de chaque mois à 6 h, heure de Paris.
    schedule: "0 6 4 * *",
    timeZone: "Europe/Paris",
    region: REGION,
    memory: "512MiB",
    timeoutSeconds: 300,
    retryCount: 2,
  },
  async () => {
    const period = previousPeriod();
    try {
      const report = await runAiReconciliation({ period, triggeredBy: null });

      // Le rapport est écrit quoi qu'il arrive ; ce log est ce qui rend
      // l'anomalie visible sans ouvrir l'écran d'administration.
      if (report.billingQueryFailed) {
        await logError({
          message: `scheduledAiReconciliation: ${period} — facturation GCP illisible`,
          errorDescription:
            "Le rapport est écrit mais son montant facturé ne veut rien dire. " +
            "Vérifier l'export BigQuery billing_export.",
          extra: { period },
        });
        return;
      }

      await logInfo({
        message: `scheduledAiReconciliation: ${period} réconcilié`,
        extra: {
          period,
          estimatedTraceableUsd: report.estimatedTraceableUsd,
          billedIaUsd: report.billedIaUsd,
          deltaUsd: report.deltaUsd,
          unattributedUsd: report.unattributedUsd,
        },
      });
    } catch (err) {
      // Cloud Scheduler retentera (retryCount), mais un échec répété doit
      // rester lisible : sans ce log, la réconciliation cesserait silencieusement.
      await logError({
        message: `scheduledAiReconciliation: échec sur ${period}`,
        errorDescription: err instanceof Error ? err.message : String(err),
        extra: { period },
      });
      throw err;
    }
  },
);
