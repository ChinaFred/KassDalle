/**
 * Envoi d'une notification push aux appareils Android des administrateurs.
 *
 * Commun à la notification de nouvelle version et à celles des tickets. Les
 * jetons sont `users/{uid}/devices/*`, ceux des seuls comptes dont le rôle
 * vaut `admin` et qui ne sont pas révoqués, lu dans Firestore à l'envoi.
 */

import { getFirestore } from "firebase-admin/firestore";

import { COLL_USERS } from "../config";
import { logError } from "../logging";
import { FCM_BATCH_SIZE, chunk, isStaleTokenCode } from "./rules";

export interface DeviceRef {
  token: string;
  path: string;
}

/** Jetons des administrateurs non révoqués, rôle relu dans Firestore. */
export async function adminDevices(): Promise<DeviceRef[]> {
  const db = getFirestore();
  const users = await db.collection(COLL_USERS).where("role", "==", "admin").get();
  const devices: DeviceRef[] = [];
  for (const user of users.docs) {
    if (user.data().is_revoked === true) continue;
    const snap = await user.ref.collection("devices").get();
    for (const doc of snap.docs) {
      const token = doc.data().token;
      if (typeof token === "string" && token !== "") devices.push({ token, path: doc.ref.path });
    }
  }
  return devices;
}

export interface PushResult {
  success: number;
  removed: number;
}

/**
 * Envoie `notification` et `data` à ces appareils, par lots. Les jetons
 * périmés sont supprimés ; tout autre refus est journalisé sous `logLabel`.
 */
export async function sendToDevices(
  devices: readonly DeviceRef[],
  notification: { title: string; body: string },
  data: Record<string, string>,
  logLabel: string,
  feature: string,
  correlationId: string,
): Promise<PushResult> {
  const { getMessaging } = await import("firebase-admin/messaging");
  const messaging = getMessaging();
  let success = 0;
  let removed = 0;
  for (const batch of chunk(devices, FCM_BATCH_SIZE)) {
    const res = await messaging.sendEachForMulticast({
      tokens: batch.map((d) => d.token),
      notification,
      data,
      android: { priority: "high" },
    });
    success += res.successCount;
    for (const [i, r] of res.responses.entries()) {
      if (r.success) continue;
      const device = batch[i];
      if (isStaleTokenCode(r.error?.code)) {
        try {
          await getFirestore().doc(device.path).delete();
          removed++;
        } catch (err) {
          await logError({
            message: `${logLabel} : jeton périmé non supprimé`,
            errorDescription: err instanceof Error ? err.message : String(err),
            correlationId,
            feature,
          });
        }
      } else {
        await logError({
          message: `${logLabel} : envoi refusé pour un appareil`,
          errorDescription: `${r.error?.code ?? "inconnu"} : ${r.error?.message ?? ""}`,
          correlationId,
          feature,
        });
      }
    }
  }
  return { success, removed };
}
