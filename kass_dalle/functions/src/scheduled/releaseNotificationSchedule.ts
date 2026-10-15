/**
 * `releaseNotificationSchedule` — notification Android aux administrateurs
 * quand un nouvel APK est publié, toutes les 10 minutes.
 *
 * Voir `release_notifications/notify.ts`. Aucune modification du workflow de
 * déploiement : la tâche lit le manifeste publié, ce qui couvre aussi
 * `deploy.ps1`.
 */

import { onSchedule } from "firebase-functions/v2/scheduler";

import { REGION } from "../config";
import { logError, newCorrelationId } from "../logging";
import { runReleaseNotification } from "../release_notifications/notify";

export const releaseNotificationSchedule = onSchedule(
  {
    schedule: "every 10 minutes",
    timeZone: "Europe/Paris",
    region: REGION,
    memory: "256MiB",
    timeoutSeconds: 120,
    retryCount: 0,
  },
  async () => {
    const correlationId = newCorrelationId("release_notification");
    try {
      await runReleaseNotification(correlationId);
    } catch (err) {
      await logError({
        message: "releaseNotificationSchedule : passe interrompue",
        errorDescription: err instanceof Error ? err.message : String(err),
        correlationId,
        feature: "release_notifications",
      });
    }
  },
);
