/**
 * Invitations par e-mail : les règles, sans Firestore ni SMTP.
 *
 * Tout ce qui décide se trouve ici et se teste sans émulateur : la clé d'une
 * adresse, le statut effectif d'une invitation, le refus d'une adresse qui a
 * déjà un compte, le message par défaut et la composition de l'e-mail. La
 * callable (`callable/invitationsCallable.ts`) et le déclencheur
 * (`triggers/invitationSignup.ts`) ne font qu'appliquer ces décisions.
 *
 * Logique **serveur seule** : le client envoie l'adresse brute et ne fait
 * qu'un contrôle de forme. Il n'existe pas de jumeau Dart de
 * `normalizeEmailKey`, et il ne faut pas en écrire un (CLAUDE.md, « La
 * duplication est un coût, pas une méthode »).
 */

/** Durée de validité d'une invitation, comptée depuis son dernier envoi. */
export const INVITATION_TTL_DAYS = 30;

/** Envois (créations et renvois) autorisés par administrateur et par jour UTC. */
export const INVITATION_DAILY_LIMIT = 20;

/** Longueur maximale du message libre. */
export const INVITATION_MESSAGE_MAX = 500;

/** Longueur maximale d'une adresse (RFC 5321). */
export const EMAIL_MAX_LENGTH = 254;

/** Les rôles qu'une invitation peut donner. Jamais `admin`. */
export const INVITABLE_ROLES = ["reader", "editor"] as const;
export type InvitableRole = (typeof INVITABLE_ROLES)[number];

/** L'adresse publique de l'application, citée dans l'e-mail. */
export const APP_URL = "https://kassdale-6d948.web.app";

/** L'APK Android servi par le Hosting (`firebase.json`, `app_update_service.dart`). */
export const APK_URL = `${APP_URL}/app-release.apk`;

/** Statuts stockés. `expired` n'est jamais écrit : il se calcule à la lecture. */
export type StoredInvitationStatus = "sent" | "send_failed" | "accepted" | "cancelled";
export type EffectiveInvitationStatus = StoredInvitationStatus | "expired";

export function isInvitableRole(value: unknown): value is InvitableRole {
  return typeof value === "string" && (INVITABLE_ROLES as readonly string[]).includes(value);
}

/**
 * Forme simple d'une adresse : une partie locale, un `@`, un domaine avec un
 * point, ni espace ni chevron. Le contrôle fin appartient au serveur SMTP ;
 * celui-ci écarte les saisies manifestement fausses et les tentatives
 * d'injection d'en-tête (retour à la ligne, virgule, chevrons).
 */
const EMAIL_SHAPE = /^[^\s@<>(),;:"\\]+@[^\s@<>(),;:"\\]+\.[^\s@<>(),;:"\\]+$/;

/** L'adresse nettoyée (espaces retirés, minuscules), ou `null` si sa forme est fausse. */
export function cleanEmail(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const email = raw.trim().toLowerCase();
  if (email.length === 0 || email.length > EMAIL_MAX_LENGTH) return null;
  return EMAIL_SHAPE.test(email) ? email : null;
}

/**
 * La clé de comparaison d'une adresse, ou `null` si sa forme est fausse.
 *
 * Espaces retirés, minuscules. Pour Gmail (`gmail.com` et `googlemail.com`),
 * Google ignore les points de la partie locale et tout ce qui suit un `+` :
 * `Jean.Dupont+cuisine@googlemail.com` et `jeandupont@gmail.com` désignent la
 * même boîte, donc le même compte Google. Les autres domaines gardent leur
 * partie locale telle quelle : un point y peut distinguer deux boîtes.
 */
export function normalizeEmailKey(raw: unknown): string | null {
  const email = cleanEmail(raw);
  if (email === null) return null;
  const at = email.lastIndexOf("@");
  let local = email.slice(0, at);
  let domain = email.slice(at + 1);
  if (domain === "googlemail.com") domain = "gmail.com";
  if (domain === "gmail.com") {
    const plus = local.indexOf("+");
    if (plus >= 0) local = local.slice(0, plus);
    local = local.replace(/\./g, "");
    if (local.length === 0) return null;
  }
  return `${local}@${domain}`;
}

/** Une date lue dans Firestore (Timestamp, Date, nombre) ou `null`. */
export function asDate(value: unknown): Date | null {
  if (value instanceof Date) return Number.isNaN(value.getTime()) ? null : value;
  if (typeof value === "number" && Number.isFinite(value)) return new Date(value);
  if (value && typeof (value as { toDate?: unknown }).toDate === "function") {
    const d = (value as { toDate: () => Date }).toDate();
    return d instanceof Date && !Number.isNaN(d.getTime()) ? d : null;
  }
  return null;
}

/**
 * Le statut à afficher et à appliquer.
 *
 * Une invitation `sent` ou `send_failed` dont la date d'expiration est passée
 * est `expired`. Une date absente ou illisible compte comme expirée : une
 * invitation dont on ne sait pas jusqu'à quand elle vaut ne donne pas de rôle.
 */
export function effectiveStatus(
  data: Record<string, unknown> | undefined | null,
  now: Date,
): EffectiveInvitationStatus {
  const status = data?.status;
  if (status === "accepted" || status === "cancelled") return status;
  const stored: StoredInvitationStatus = status === "sent" ? "sent" : "send_failed";
  const expires = asDate(data?.expires_at);
  if (expires === null || expires.getTime() <= now.getTime()) return "expired";
  return stored;
}

/** Vrai si l'invitation peut encore donner un rôle (envoyée ou en échec, non expirée). */
export function isActiveInvitation(
  data: Record<string, unknown> | undefined | null,
  now: Date,
): boolean {
  const s = effectiveStatus(data, now);
  return s === "sent" || s === "send_failed";
}

/** La date d'expiration d'un envoi fait à `sentAt`. */
export function expiryFrom(sentAt: Date): Date {
  return new Date(sentAt.getTime() + INVITATION_TTL_DAYS * 24 * 60 * 60 * 1000);
}

/**
 * Parmi des invitations pour une même adresse, celle qui s'applique : la
 * plus récemment envoyée des actives. `null` si aucune n'est active.
 */
export function pickActiveInvitation<T extends { data: Record<string, unknown> }>(
  candidates: T[],
  now: Date,
): T | null {
  let best: T | null = null;
  let bestAt = -Infinity;
  for (const c of candidates) {
    if (!isActiveInvitation(c.data, now)) continue;
    const at = asDate(c.data.last_sent_at)?.getTime() ?? 0;
    if (best === null || at > bestAt) {
      best = c;
      bestAt = at;
    }
  }
  return best;
}

/** Ce qu'il faut savoir d'un compte existant pour refuser l'invitation. */
export interface ExistingAccount {
  role: string | null;
  isRevoked: boolean;
  isFounder: boolean;
}

/** Pourquoi une adresse ne peut pas être invitée. */
export type AccountRefusalReason =
  "account_active" | "account_pending" | "account_revoked" | "founder";

const ROLE_LABELS: Record<string, string> = {
  admin: "administrateur",
  editor: "éditeur",
  reader: "lecteur",
};

/**
 * Le refus à opposer à une adresse qui a déjà un compte, ou `null` si aucun
 * compte n'existe. Une invitation n'agit que sur un compte neuf : un compte
 * existant change de rôle dans l'onglet Comptes, et entre dans un groupe par
 * l'invitation de groupe.
 */
export function accountRefusal(
  account: ExistingAccount | null,
): { reason: AccountRefusalReason; message: string } | null {
  if (account === null) return null;
  if (account.isFounder) {
    return { reason: "founder", message: "Cette adresse est celle du compte fondateur." };
  }
  if (account.isRevoked) {
    return {
      reason: "account_revoked",
      message: "Cette adresse a un compte révoqué. Rétablissez son accès dans l'onglet Comptes.",
    };
  }
  if (account.role === "pending" || account.role === null) {
    return { reason: "account_pending", message: "Ce compte attend déjà un rôle." };
  }
  const label = ROLE_LABELS[account.role] ?? account.role;
  return {
    reason: "account_active",
    message:
      `Cette adresse a déjà un compte (${label}). Changez son rôle dans l'onglet ` +
      "Comptes, et invitez-le depuis le groupe.",
  };
}

/** Le message prérempli, tel que le formulaire le propose. */
export function defaultInvitationMessage(groupName: string): string {
  return (
    `Je t'invite dans mon groupe familial « ${groupName} » sur Kass'Dalle, pour suivre ` +
    "et noter tes repas préférés. Tu auras aussi accès aux recettes que le groupe partage."
  );
}

/**
 * Le message libre, borné : espaces de bord retirés, retours à la ligne
 * normalisés, 500 caractères au plus. Vide → message par défaut.
 */
export function cleanMessage(raw: unknown, groupName: string): string {
  const text = typeof raw === "string" ? raw.replace(/\r\n?/g, "\n").trim() : "";
  if (text.length === 0) return defaultInvitationMessage(groupName);
  return Array.from(text).slice(0, INVITATION_MESSAGE_MAX).join("");
}

/** Échappe un texte pour le corps HTML de l'e-mail. */
export function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

/**
 * Un nom propre à l'en-tête `From` : ni retour à la ligne, ni guillemet, ni
 * chevron, 60 caractères au plus. Vide → « Kass'Dalle ».
 */
export function headerSafeName(name: string): string {
  const cleaned = name
    .replace(/[\r\n"<>\\]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  return Array.from(cleaned).slice(0, 60).join("").trim() || "Kass'Dalle";
}

/** Date au format jj/mm/aaaa, heure de Paris. */
export function formatDateFr(date: Date): string {
  return new Intl.DateTimeFormat("fr-FR", {
    timeZone: "Europe/Paris",
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
  }).format(date);
}

export interface InvitationEmailInput {
  inviterName: string;
  groupName: string;
  message: string;
  toEmail: string;
  expiresAt: Date;
}

export interface InvitationEmail {
  /** Nom affiché de l'expéditeur : « {Invitant} via Kass'Dalle ». */
  fromName: string;
  subject: string;
  text: string;
  html: string;
}

/**
 * L'e-mail d'invitation, en texte et en HTML simple.
 *
 * Le message libre, le nom de l'invitant et celui du groupe sont échappés
 * dans le HTML : ils viennent d'une saisie. Le pied (lien, APK, adresse à
 * utiliser, expiration, signature) n'est pas modifiable.
 */
export function buildInvitationEmail(input: InvitationEmailInput): InvitationEmail {
  const inviter = headerSafeName(input.inviterName);
  const group = input.groupName.replace(/[\r\n]+/g, " ").trim();
  const expires = formatDateFr(input.expiresAt);
  const subject = `${inviter} t'invite dans « ${group} » sur Kass'Dalle`;
  const accountLine =
    `Connecte-toi avec le compte Google ${input.toEmail}. Avec une autre adresse, ` +
    "ton accès devra être validé à la main.";
  const expiryLine = `Cette invitation expire le ${expires}.`;

  const text = [
    input.message,
    "",
    `Ouvrir Kass'Dalle : ${APP_URL}`,
    `Sur Android, l'application se télécharge ici : ${APK_URL}`,
    "",
    accountLine,
    expiryLine,
    "",
    inviter,
  ].join("\n");

  const paragraphs = input.message
    .split(/\n{2,}/)
    .map((p) => `<p style="margin:0 0 12px">${escapeHtml(p).replace(/\n/g, "<br>")}</p>`)
    .join("");
  const muted = "color:#5f5f5f;font-size:14px;margin:0 0 8px";
  const html =
    '<div style="font-family:Arial,Helvetica,sans-serif;font-size:16px;line-height:1.5;' +
    'color:#1f1f1f;max-width:560px">' +
    paragraphs +
    '<p style="margin:24px 0">' +
    `<a href="${APP_URL}" style="background:#6b7b3a;color:#ffffff;padding:12px 20px;` +
    "border-radius:8px;text-decoration:none;display:inline-block\">Ouvrir Kass'Dalle</a>" +
    "</p>" +
    `<p style="${muted}">Sur Android, l'application se télécharge ici : ` +
    `<a href="${APK_URL}">${APK_URL}</a></p>` +
    `<p style="${muted}">${escapeHtml(accountLine)}</p>` +
    `<p style="${muted}">${escapeHtml(expiryLine)}</p>` +
    `<p style="margin:16px 0 0">${escapeHtml(inviter)}</p>` +
    "</div>";

  return { fromName: `${inviter} via Kass'Dalle`, subject, text, html };
}

/** Le message d'erreur SMTP à montrer à l'administrateur : une ligne, 300 caractères. */
export function readableSendError(err: unknown): string {
  const raw = err instanceof Error ? err.message : String(err);
  const line = raw.replace(/\s+/g, " ").trim();
  const text = line.length > 0 ? line : "Erreur inconnue.";
  return Array.from(text).slice(0, 300).join("");
}
