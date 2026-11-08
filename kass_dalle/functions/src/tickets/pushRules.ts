/**
 * Règles pures des notifications push de tickets aux administrateurs.
 *
 * Trois événements : analyse publiée (statut `analyzed`), analyse qui s'arrête
 * sur des compléments (réponse attendue) et développement livré (`delivered`).
 */

import { containsEmailAddress } from "./rules";

export type TicketPushKind = "ticket_analyzed" | "ticket_needs_reply" | "ticket_delivered";

export const TICKET_PUSH_TITLE_MAX = 60;

/** Début d'un commentaire d'analyse qui s'arrête sur une question ou un blocage. */
export const NEEDS_REPLY_PREFIX = "## Analyse — compléments";

/** Un commentaire de compléments plus ancien n'est plus notifié (reprise après déploiement). */
export const NEEDS_REPLY_MAX_AGE_MS = 6 * 3_600_000;

/** Notification due par un passage de statut, ou `null`. */
export function pushKindForTransition(current: string, next: string): TicketPushKind | null {
  if (current === next) return null;
  if (next === "analyzed") return "ticket_analyzed";
  if (next === "delivered") return "ticket_delivered";
  return null;
}

/**
 * Titre du ticket pour la notification : texte de membre, tronqué à 60
 * caractères ; une adresse e-mail ou un lien le remplace par un titre générique.
 */
export function pushTicketTitle(title: unknown): string {
  const text = typeof title === "string" ? title.replace(/\s+/g, " ").trim() : "";
  if (text === "" || containsEmailAddress(text) || /https?:|www\./i.test(text)) return "Ticket";
  const chars = Array.from(text);
  return chars.length <= TICKET_PUSH_TITLE_MAX
    ? text
    : `${chars.slice(0, TICKET_PUSH_TITLE_MAX - 1).join("")}…`;
}

export function ticketPushText(
  kind: TicketPushKind,
  title: unknown,
): { title: string; body: string } {
  const name = pushTicketTitle(title);
  switch (kind) {
    case "ticket_analyzed":
      return { title: "Ticket analysé", body: `${name} — à valider ou refuser` };
    case "ticket_needs_reply":
      return { title: "Ticket à compléter", body: `${name} — une réponse est attendue` };
    case "ticket_delivered":
      return { title: "Ticket livré", body: `${name} — développement livré` };
  }
}

/**
 * Commentaire de compléments à notifier parmi les analyses relevées : le plus
 * récent, récent (moins de 6 h) et différent du dernier déjà notifié.
 */
export function needsReplyToNotify(
  analyses: ReadonlyArray<{ comment_id: number | null; body: string; created_at: string | null }>,
  lastNotifiedId: number | null,
  nowMs: number,
): number | null {
  let latest: { comment_id: number | null; created_at: string | null } | null = null;
  for (const a of analyses) {
    if (a.body.normalize("NFC").trimStart().startsWith(NEEDS_REPLY_PREFIX)) latest = a;
  }
  if (latest === null || latest.comment_id === null) return null;
  if (latest.comment_id === lastNotifiedId) return null;
  const created = latest.created_at === null ? Number.NaN : Date.parse(latest.created_at);
  if (Number.isNaN(created) || nowMs - created > NEEDS_REPLY_MAX_AGE_MS) return null;
  return latest.comment_id;
}
