/**
 * Invitations par e-mail : les règles, sans Firestore ni SMTP.
 *
 * Tout ce qui décide se trouve ici et se teste sans émulateur : la clé d'une
 * adresse, le statut effectif d'une invitation, le refus d'une adresse qui a
 * déjà un compte, la composition de l'e-mail et la lecture d'une erreur SMTP. La
 * callable (`callable/invitationsCallable.ts`) et le déclencheur
 * (`triggers/invitationSignup.ts`) ne font qu'appliquer ces décisions.
 *
 * Logique **serveur seule**, sauf le statut effectif : le client envoie
 * l'adresse brute et ne fait qu'un contrôle de forme. Il n'existe pas de
 * jumeau Dart de `normalizeEmailKey`, et il ne faut pas en écrire un
 * (CLAUDE.md, « La duplication est un coût, pas une méthode »).
 *
 * `effectiveStatus` a un jumeau Dart (`EmailInvitation.statusAt`,
 * `email_invitation.dart`) : le client l'emploie pour afficher, le serveur
 * pour décider. Les deux rejouent `test-fixtures/email_invitation_status.json`.
 *
 * Le message par défaut n'existe que côté client, qui le prérempli : un
 * message vide part sans paragraphe personnel, le pied fixe suffit.
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

/**
 * Le message libre, borné : espaces de bord retirés, retours à la ligne
 * normalisés, 500 caractères au plus. Vide reste vide : l'e-mail part alors
 * sans paragraphe personnel.
 */
export function cleanMessage(raw: unknown): string {
  const text = typeof raw === "string" ? raw.replace(/\r\n?/g, "\n").trim() : "";
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

  const message = input.message.trim();
  const text = [
    ...(message.length > 0 ? [message, ""] : []),
    `Ouvrir Kass'Dalle : ${APP_URL}`,
    `Sur Android, l'application se télécharge ici : ${APK_URL}`,
    "",
    accountLine,
    expiryLine,
    "",
    inviter,
  ].join("\n");

  const paragraphs = (message.length > 0 ? message.split(/\n{2,}/) : [])
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

/**
 * Masque la partie locale des adresses e-mail d'un texte : premier caractère
 * gardé, le reste remplacé par `***` (`marie@gmail.com` → `m***@gmail.com`).
 * Une erreur SMTP cite l'adresse du destinataire ; elle part dans les journaux
 * et dans `last_error`, qu'il n'y a pas lieu de remplir d'adresses en clair.
 */
export function maskEmails(text: string): string {
  return text.replace(/([A-Za-z0-9._%+'-])[A-Za-z0-9._%+'-]*@([A-Za-z0-9-]+\.)/g, "$1***@$2");
}

/**
 * Le message d'erreur SMTP à montrer à l'administrateur : une ligne,
 * 300 caractères, adresses masquées.
 */
export function readableSendError(err: unknown): string {
  const raw = err instanceof Error ? err.message : String(err);
  const line = maskEmails(raw.replace(/\s+/g, " ").trim());
  const text = line.length > 0 ? line : "Erreur inconnue.";
  return Array.from(text).slice(0, 300).join("");
}

/** Préfixe du motif d'une invitation annulée parce que Gmail a refusé l'adresse. */
export const ADDRESS_REJECTED_PREFIX = "Adresse refusée par Gmail : ";

/**
 * Vrai si le serveur SMTP refuse **définitivement** le destinataire : un code
 * de réponse 5xx sur la commande `RCPT TO` (ex. `550 5.1.1`), ou une
 * enveloppe rejetée (`EENVELOPE`, que nodemailer lève quand tous les
 * destinataires sont refusés).
 *
 * Un 5xx sur une autre commande (`AUTH` 535 : mot de passe d'application
 * faux) est une erreur de configuration, et un 4xx une erreur temporaire :
 * l'invitation reste alors en `send_failed` et se renvoie.
 */
export function isPermanentRecipientRejection(err: unknown): boolean {
  if (err === null || typeof err !== "object") return false;
  const e = err as { responseCode?: unknown; command?: unknown; code?: unknown };
  const code = typeof e.responseCode === "number" ? e.responseCode : null;
  if (code === null || code < 500 || code > 599) return false;
  if (e.code === "EENVELOPE") return true;
  return typeof e.command === "string" && /^RCPT\b/i.test(e.command.trim());
}
