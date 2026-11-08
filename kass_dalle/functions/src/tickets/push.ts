/**
 * Envoi des notifications push de tickets aux administrateurs.
 *
 * Appelé après la transaction qui a changé le statut ou relevé les
 * compléments : l'unicité vient de cette transaction, pas d'ici. Un échec
 * d'envoi est journalisé et n'annule aucune écriture.
 */

import { logError, logInfo } from "../logging";
import { adminDevices, sendToDevices } from "../release_notifications/adminPush";
import { ticketPushText, type TicketPushKind } from "./pushRules";

export async function notifyAdminsOfTicket(
  ticketId: string,
  kind: TicketPushKind,
  title: unknown,
): Promise<void> {
  const correlationId = `ticketPush:${ticketId}`;
  try {
    const devices = await adminDevices();
    if (devices.length === 0) {
      await logInfo({
        message: `ticketPush : ${kind} sans appareil administrateur enregistré`,
        correlationId,
        firestoreDocId: ticketId,
        feature: "tickets",
      });
      return;
    }
    const { success, removed } = await sendToDevices(
      devices,
      ticketPushText(kind, title),
      { type: kind, ticket_id: ticketId },
      "ticketPush",
      "tickets",
      correlationId,
    );
    await logInfo({
      message: `ticketPush : ${kind} envoyée à ${success}/${devices.length} appareil(s), ${removed} jeton(s) périmé(s) supprimé(s)`,
      correlationId,
      firestoreDocId: ticketId,
      feature: "tickets",
    });
  } catch (err) {
    await logError({
      message: `ticketPush : ${kind} non envoyée`,
      errorDescription: err instanceof Error ? err.message : String(err),
      correlationId,
      firestoreDocId: ticketId,
      feature: "tickets",
    });
  }
}
