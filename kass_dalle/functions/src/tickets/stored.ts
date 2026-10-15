/**
 * Lecture des sous-documents `tickets/{id}/admin/*` et du verrou des
 * livraisons sans supposer leur forme.
 *
 * Partagé par les lancements (`tickets/launch.ts`), la réponse de
 * l'administrateur (`tickets/decisions.ts`) et la livraison
 * (`tickets/delivery.ts`). Module à part : `launch.ts` importe déjà
 * `decisions.ts`.
 */

import { Timestamp } from "firebase-admin/firestore";

import { lastDeliveryBlockedAtMs, type DeliveryLockView, type LaunchEntryView } from "./rules";

export function millis(raw: unknown): number | null {
  return raw instanceof Timestamp ? raw.toMillis() : null;
}

/** Les entrées de `launches`, lues sans supposer leur forme. */
export function readLaunchEntries(data: FirebaseFirestore.DocumentData | undefined): unknown[] {
  const raw = data?.launches;
  return Array.isArray(raw) ? raw : [];
}

/** Les entrées de `launches` lisibles par `launchRunState`. */
export function launchEntryViews(
  data: FirebaseFirestore.DocumentData | undefined,
): LaunchEntryView[] {
  const views: LaunchEntryView[] = [];
  for (const raw of readLaunchEntries(data)) {
    if (raw === null || typeof raw !== "object") continue;
    const e = raw as Record<string, unknown>;
    views.push({
      action: e.action,
      outcome: e.outcome,
      from_status: e.from_status,
      launched_at_ms: millis(e.launched_at),
      retry_after_ms: millis(e.retry_after),
    });
  }
  return views;
}

/** Date de la dernière analyse relevée (`kind` absent = analyse), ou `null`. */
export function lastAnalysisMillis(
  data: FirebaseFirestore.DocumentData | undefined,
): number | null {
  const raw = data?.analyses;
  if (!Array.isArray(raw)) return null;
  let best: number | null = null;
  for (const e of raw) {
    if (e === null || typeof e !== "object") continue;
    const entry = e as Record<string, unknown>;
    if (entry.kind !== undefined && entry.kind !== "analysis") continue;
    const ms = millis(entry.created_at);
    if (ms !== null && (best === null || ms > best)) best = ms;
  }
  return best;
}

/**
 * `validated_at` stocké : `undefined` si le champ manque (date inconnue),
 * `null` s'il ne porte aucune date, sinon la date en millisecondes.
 */
export function storedValidatedAt(
  data: FirebaseFirestore.DocumentData | undefined,
): number | null | undefined {
  if (data === undefined || !("validated_at" in data)) return undefined;
  return millis(data.validated_at);
}

/**
 * Date du dernier compte rendu « blocage » de `tickets/{id}/admin/delivery`
 * (`reports`), en millisecondes, ou `null`.
 */
export function deliveryBlockedAtMs(
  data: FirebaseFirestore.DocumentData | undefined,
): number | null {
  const raw = data?.reports;
  if (!Array.isArray(raw)) return null;
  return lastDeliveryBlockedAtMs(
    raw
      .filter((r): r is Record<string, unknown> => r !== null && typeof r === "object")
      .map((r) => ({ kind: r.kind, created_at_ms: millis(r.created_at) })),
  );
}

/**
 * `app_config/tickets_status.delivery_running`, ou `null` s'il est absent ou
 * n'est pas un objet.
 */
export function deliveryLockView(raw: unknown): DeliveryLockView | null {
  if (raw === null || typeof raw !== "object") return null;
  const lock = raw as Record<string, unknown>;
  return {
    ticketId: lock.ticket_id,
    issueNumber: lock.issue_number,
    launchedAtMs: millis(lock.launched_at),
    retryAfterMs: millis(lock.retry_after),
  };
}
