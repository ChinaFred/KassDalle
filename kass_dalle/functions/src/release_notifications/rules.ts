/**
 * Règles pures de la notification de nouvelle version (`releaseNotificationSchedule`).
 *
 * Aucune dépendance : lecture du manifeste `apk_release.json`, clé d'une
 * livraison, texte de la notification, jetons à supprimer.
 */

/** Ce que la notification doit savoir d'un APK publié. */
export interface ApkRelease {
  version: string;
  build: string;
}

/**
 * Lit le manifeste `apk_release.json`. Retourne null quand le texte n'est pas
 * un manifeste : Hosting répond `index.html` pour un chemin inconnu, et un
 * JSON sans `version` ne décrit aucun APK.
 */
export function parseApkManifest(text: string): ApkRelease | null {
  let json: unknown;
  try {
    json = JSON.parse(text);
  } catch (err) {
    console.error("parseApkManifest : manifeste non JSON", err);
    return null;
  }
  if (typeof json !== "object" || json === null) return null;
  const { version, build_number: build } = json as Record<string, unknown>;
  if (typeof version !== "string" || !/^\d+\.\d+\.\d+$/.test(version.trim())) return null;
  const buildText =
    typeof build === "string" ? build.trim() : typeof build === "number" ? String(build) : "";
  return { version: version.trim(), build: buildText };
}

/** Un même couple (version, build) n'est notifié qu'une fois. */
export function releaseKey(release: ApkRelease): string {
  return `${release.version}+${release.build}`;
}

export function notificationText(release: ApkRelease): { title: string; body: string } {
  return {
    title: "Nouvelle version disponible",
    body: `Kass'Dalle v${release.version} est prête à installer.`,
  };
}

/** Codes FCM qui disent que le jeton ne sert plus : l'application est désinstallée. */
const STALE_TOKEN_CODES = new Set([
  "messaging/registration-token-not-registered",
  "messaging/invalid-registration-token",
]);

export function isStaleTokenCode(code: string | undefined): boolean {
  return code !== undefined && STALE_TOKEN_CODES.has(code);
}

/** FCM accepte 500 jetons par envoi groupé. */
export const FCM_BATCH_SIZE = 500;

export function chunk<T>(items: readonly T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}
