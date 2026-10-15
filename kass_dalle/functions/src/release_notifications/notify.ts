/**
 * Notification de nouvelle version aux administrateurs.
 *
 * Une passe lit `apk_release.json` sur Hosting, réserve le couple
 * (version, build) dans `app_config/apk_notification`, puis envoie aux jetons
 * `users/{uid}/devices/*` des seuls comptes dont le rôle vaut `admin` et qui ne
 * sont pas révoqués, lu dans Firestore à l'instant de l'envoi.
 */

import { getFirestore, Timestamp } from "firebase-admin/firestore";

import { COLL_APP_CONFIG, COLL_USERS } from "../config";
import { logError, logInfo } from "../logging";
import {
  FCM_BATCH_SIZE,
  chunk,
  isStaleTokenCode,
  notificationText,
  parseApkManifest,
  releaseKey,
  type ApkRelease,
} from "./rules";

const MANIFEST_URL = "https://kassdale-6d948.web.app/apk_release.json";
const DOC_PATH = `${COLL_APP_CONFIG}/apk_notification`;

export type NotifyOutcome =
  "manifest_unreadable" | "already_notified" | "no_device" | "sent" | "send_failed";

interface DeviceRef {
  token: string;
  path: string;
}

async function readManifest(correlationId: string): Promise<ApkRelease | null> {
  try {
    const res = await fetch(`${MANIFEST_URL}?t=${Date.now()}`, {
      headers: { "Cache-Control": "no-cache" },
      signal: AbortSignal.timeout(8000),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const release = parseApkManifest(await res.text());
    if (release === null) throw new Error("manifeste illisible");
    return release;
  } catch (err) {
    await logError({
      message: "releaseNotification : apk_release.json non lu",
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId,
      feature: "release_notifications",
    });
    return null;
  }
}

/**
 * Réserve le couple dans une transaction : deux passes qui se chevauchent ne
 * l'obtiennent pas toutes les deux. Retourne l'état précédent (pour le
 * restaurer si l'envoi échoue), ou "taken" si le couple est déjà réservé.
 */
async function reserve(key: string, release: ApkRelease): Promise<{ previous: unknown } | "taken"> {
  const db = getFirestore();
  const ref = db.doc(DOC_PATH);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (snap.exists && snap.data()?.key === key) return "taken" as const;
    tx.set(ref, {
      key,
      version: release.version,
      build: release.build,
      reserved_at: Timestamp.now(),
    });
    return { previous: snap.exists ? snap.data() : null };
  });
}

async function restore(previous: unknown): Promise<void> {
  const ref = getFirestore().doc(DOC_PATH);
  if (previous === null || typeof previous !== "object") await ref.delete();
  else await ref.set(previous as Record<string, unknown>);
}

/** Jetons des administrateurs non révoqués, rôle relu dans Firestore. */
async function adminDevices(): Promise<DeviceRef[]> {
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

export async function runReleaseNotification(correlationId: string): Promise<NotifyOutcome> {
  const release = await readManifest(correlationId);
  if (release === null) return "manifest_unreadable";

  const key = releaseKey(release);
  const reserved = await reserve(key, release);
  if (reserved === "taken") return "already_notified";

  try {
    const devices = await adminDevices();
    if (devices.length === 0) {
      await logInfo({
        message: `releaseNotification : ${key} sans appareil administrateur enregistré`,
        correlationId,
        feature: "release_notifications",
      });
      return "no_device";
    }

    const { getMessaging } = await import("firebase-admin/messaging");
    const messaging = getMessaging();
    const text = notificationText(release);
    let success = 0;
    let removed = 0;
    for (const batch of chunk(devices, FCM_BATCH_SIZE)) {
      const res = await messaging.sendEachForMulticast({
        tokens: batch.map((d) => d.token),
        notification: text,
        data: { type: "apk_release", version: release.version, build: release.build },
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
              message: "releaseNotification : jeton périmé non supprimé",
              errorDescription: err instanceof Error ? err.message : String(err),
              correlationId,
              feature: "release_notifications",
            });
          }
        } else {
          await logError({
            message: "releaseNotification : envoi refusé pour un appareil",
            errorDescription: `${r.error?.code ?? "inconnu"} : ${r.error?.message ?? ""}`,
            correlationId,
            feature: "release_notifications",
          });
        }
      }
    }

    await logInfo({
      message: `releaseNotification : ${key} envoyée à ${success}/${devices.length} appareil(s), ${removed} jeton(s) périmé(s) supprimé(s)`,
      correlationId,
      feature: "release_notifications",
    });
    if (success === 0 && removed < devices.length) {
      await restore(reserved.previous);
      return "send_failed";
    }
    return "sent";
  } catch (err) {
    await logError({
      message: `releaseNotification : envoi de ${key} interrompu`,
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId,
      feature: "release_notifications",
    });
    try {
      await restore(reserved.previous);
    } catch (restoreErr) {
      await logError({
        message: `releaseNotification : réservation de ${key} non libérée`,
        errorDescription: restoreErr instanceof Error ? restoreErr.message : String(restoreErr),
        correlationId,
        feature: "release_notifications",
      });
    }
    return "send_failed";
  }
}
