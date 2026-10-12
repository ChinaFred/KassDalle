/**
 * Invitations par e-mail : les règles, sans Firestore ni SMTP.
 *
 * Tout ce qui décide se trouve ici et se teste sans émulateur : la clé d'une
 * adresse, le statut effectif d'une invitation, le compte qu'elle vise (neuf
 * ou révoqué), le refus d'une adresse qui a déjà un compte actif, la
 * composition de l'e-mail et la lecture d'une erreur SMTP. La callable
 * (`callable/invitationsCallable.ts`) et les deux déclencheurs
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
 * Le compte qu'une invitation vise, fixé à sa création :
 *  - `new` : un compte qui n'existe pas encore. Il s'applique à la création
 *    d'un compte `pending` sous l'adresse (`applyEmailInvitation`). Une
 *    invitation antérieure au champ `target` est de ce type ;
 *  - `revoked` : le compte révoqué `target_uid`, qui porte l'adresse. Il
 *    s'applique à la reconnexion de ce compte-là, et de lui seul
 *    (`applyRevokedInvitation`).
 */
export type InvitationTarget = "new" | "revoked";

/** Le type de compte visé par une invitation stockée. */
export function invitationTargetOf(
  data: Record<string, unknown> | undefined | null,
): InvitationTarget {
  return data?.target === "revoked" ? "revoked" : "new";
}

/** L'uid du compte révoqué visé, ou `null` (invitation d'un compte neuf, ou champ illisible). */
export function targetUidOf(data: Record<string, unknown> | undefined | null): string | null {
  if (invitationTargetOf(data) !== "revoked") return null;
  const v = data?.target_uid;
  return typeof v === "string" && v.trim() && !v.includes("/") ? v.trim() : null;
}

/** Le compte pour lequel on cherche une invitation à appliquer. */
export type InvitationSeeker = { kind: "new" } | { kind: "revoked"; uid: string };

/**
 * L'invitation peut-elle s'appliquer à ce compte ? Une invitation de compte
 * neuf ne rétablit jamais un compte révoqué, et une invitation de compte
 * révoqué ne nomme ni un compte neuf, ni un autre compte révoqué qui aurait la
 * même clé d'adresse.
 */
export function invitationFits(
  data: Record<string, unknown> | undefined | null,
  seeker: InvitationSeeker,
): boolean {
  const target = invitationTargetOf(data);
  if (seeker.kind === "new") return target === "new";
  return target === "revoked" && targetUidOf(data) === seeker.uid;
}

/**
 * Parmi des invitations pour une même adresse, celle qui s'applique à
 * `seeker` : la plus récemment envoyée des actives qui le visent. `null` si
 * aucune.
 */
export function pickActiveInvitation<T extends { data: Record<string, unknown> }>(
  candidates: T[],
  now: Date,
  seeker: InvitationSeeker,
): T | null {
  let best: T | null = null;
  let bestAt = -Infinity;
  for (const c of candidates) {
    if (!isActiveInvitation(c.data, now)) continue;
    if (!invitationFits(c.data, seeker)) continue;
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
export type AccountRefusalReason = "account_active" | "account_pending" | "founder";

const ROLE_LABELS: Record<string, string> = {
  admin: "administrateur",
  editor: "éditeur",
  reader: "lecteur",
};

/** Ce que permet le compte qui porte l'adresse. */
export type AccountDecision =
  | { kind: "new" }
  | { kind: "revoked" }
  | { kind: "refused"; reason: AccountRefusalReason; message: string };

/**
 * Le type d'invitation que permet le compte qui porte déjà l'adresse :
 *  - aucun compte : invitation d'un compte neuf ;
 *  - compte révoqué (hors fondateur) : invitation de retour. Le compte reste
 *    révoqué à l'envoi ; son accès est rétabli à sa reconnexion ;
 *  - fondateur, compte actif ou en attente : refus. Un compte actif change
 *    de rôle dans l'onglet Comptes et entre dans un groupe par l'invitation de
 *    groupe.
 */
export function accountDecision(account: ExistingAccount | null): AccountDecision {
  if (account === null) return { kind: "new" };
  if (account.isFounder) {
    return {
      kind: "refused",
      reason: "founder",
      message: "Cette adresse est celle du compte fondateur.",
    };
  }
  if (account.isRevoked) return { kind: "revoked" };
  if (account.role === "pending" || account.role === null) {
    return {
      kind: "refused",
      reason: "account_pending",
      message: "Ce compte attend déjà un rôle.",
    };
  }
  const label = ROLE_LABELS[account.role] ?? account.role;
  return {
    kind: "refused",
    reason: "account_active",
    message:
      `Cette adresse a déjà un compte (${label}). Changez son rôle dans l'onglet ` +
      "Comptes, et invitez-le depuis le groupe.",
  };
}

/** Message du refus d'un renvoi dont le compte visé a changé depuis l'envoi. */
export const TARGET_CHANGED_MESSAGE =
  "Le compte de cette adresse a changé depuis l'invitation. Annulez-la, puis invitez de nouveau.";

/**
 * Peut-on renvoyer cette invitation, vu le compte qui porte l'adresse
 * aujourd'hui ? Le renvoi garde le type fixé à la création : une invitation
 * de compte neuf exige toujours qu'aucun compte n'existe, et une invitation
 * de retour exige que le même compte soit toujours révoqué. `null` : renvoi
 * permis.
 */
export function resendRefusal(
  invitation: Record<string, unknown>,
  existing: { uid: string; account: ExistingAccount } | null,
): { reason: AccountRefusalReason | "target_changed"; message: string } | null {
  const decision = accountDecision(existing?.account ?? null);
  if (decision.kind === "refused") return { reason: decision.reason, message: decision.message };
  const target = invitationTargetOf(invitation);
  if (decision.kind === "new" && target === "new") return null;
  if (
    decision.kind === "revoked" &&
    target === "revoked" &&
    existing?.uid === targetUidOf(invitation)
  ) {
    return null;
  }
  return { reason: "target_changed", message: TARGET_CHANGED_MESSAGE };
}

/**
 * Plafond des invitations de groupe en attente (`invited_ids`), le même que
 * celui des règles Firestore (`boundedGroup`). Le dépasser bloquerait toute
 * écriture de gestion du groupe depuis le client.
 */
export const GROUP_INVITED_MAX = 50;

/**
 * Ce que devient le groupe au retour d'un compte révoqué invité par e-mail :
 *  - `invited` : son uid entre dans `invited_ids`, il accepte dans Groupes ;
 *  - `already_member` / `already_invited` : rien à écrire ;
 *  - `full` : 50 invitations déjà en attente, rien à écrire ;
 *  - `missing` : groupe supprimé entre-temps, ou invitant (`inviterUid`) qui
 *    n'en est plus ni propriétaire ni membre. Rien à écrire : l'invitant ne
 *    peut plus inviter dans ce groupe, et le serveur n'invite pas à sa place.
 * Le compte révoqué n'entre jamais directement dans `member_ids`.
 */
export type GroupInviteResult =
  "invited" | "already_member" | "already_invited" | "full" | "missing";

export function groupInviteFor(
  group: Record<string, unknown> | undefined | null,
  uid: string,
  inviterUid?: string | null,
): GroupInviteResult {
  if (!group) return "missing";
  const members = Array.isArray(group.member_ids) ? group.member_ids : [];
  if (group.owner_id === uid || members.includes(uid)) return "already_member";
  const invited = Array.isArray(group.invited_ids) ? group.invited_ids : [];
  if (invited.includes(uid)) return "already_invited";
  if (inviterUid !== undefined) {
    const inGroup =
      typeof inviterUid === "string" &&
      inviterUid.length > 0 &&
      (group.owner_id === inviterUid || members.includes(inviterUid));
    if (!inGroup) return "missing";
  }
  if (invited.length >= GROUP_INVITED_MAX) return "full";
  return "invited";
}

/** Vrai si l'invitation stockée vise le compte révoqué `uid` et peut encore s'appliquer. */
export function isOpenReturnInvitationFor(
  data: Record<string, unknown> | undefined | null,
  uid: string,
  now: Date,
): boolean {
  return invitationFits(data, { kind: "revoked", uid }) && isActiveInvitation(data, now);
}

/**
 * Vrai si l'écriture rétablit un compte : révoqué avant, présent et non
 * révoqué après. Pure, testée.
 */
export function isAccessRestored(
  before: Record<string, unknown> | undefined | null,
  after: Record<string, unknown> | undefined | null,
): boolean {
  if (!before || !after) return false;
  return before.is_revoked === true && after.is_revoked !== true;
}

/** Motif d'annulation d'une invitation de retour devenue sans objet : accès rétabli à la main. */
export const RESTORED_BY_HAND_MESSAGE = "Accès rétabli à la main : invitation sans objet.";

/** Motif d'annulation quand une autre invitation de retour a rétabli l'accès. */
export const RESTORED_BY_OTHER_INVITATION_MESSAGE =
  "Accès rétabli par une autre invitation : invitation sans objet.";

/**
 * Écart maximal entre le rétablissement d'un compte et l'acceptation d'une
 * invitation de retour pour attribuer ce rétablissement à l'invitation.
 * `applyRevokedInvitation` écrit les deux dans la même transaction : l'écart
 * réel est la durée de la transaction.
 */
export const RESTORED_BY_INVITATION_WINDOW_MS = 60_000;

/**
 * Les invitations de retour à annuler quand le compte `uid` est rétabli, et
 * le motif à écrire.
 *
 * Toute invitation encore active qui vise ce compte est sans objet une fois
 * l'accès rendu : laissée active, elle le rétablirait après une nouvelle
 * révocation. Celle qu'`applyRevokedInvitation` vient d'appliquer est déjà
 * `accepted` (même transaction que le rétablissement) et n'est pas reprise.
 * Le motif dit qui a rétabli : une invitation acceptée par ce compte à moins
 * de `RESTORED_BY_INVITATION_WINDOW_MS` du rétablissement, sinon la main d'un
 * administrateur (onglet Comptes). Pure, testée.
 */
export function staleReturnInvitations<T extends { id: string; data: Record<string, unknown> }>(
  candidates: T[],
  uid: string,
  restoredAt: Date,
): { stale: T[]; reason: string } {
  const stale = candidates.filter((c) => isOpenReturnInvitationFor(c.data, uid, restoredAt));
  const byInvitation = candidates.some((c) => {
    if (c.data.status !== "accepted" || c.data.accepted_uid !== uid) return false;
    if (invitationTargetOf(c.data) !== "revoked") return false;
    const at = asDate(c.data.accepted_at)?.getTime();
    return (
      at !== undefined && Math.abs(at - restoredAt.getTime()) <= RESTORED_BY_INVITATION_WINDOW_MS
    );
  });
  return {
    stale,
    reason: byInvitation ? RESTORED_BY_OTHER_INVITATION_MESSAGE : RESTORED_BY_HAND_MESSAGE,
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
  /** Invitation d'un compte révoqué : le pied annonce le rétablissement. */
  restoresAccess?: boolean;
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
 * utiliser, expiration, signature) n'est pas modifiable ; pour un compte
 * révoqué, sa ligne d'adresse annonce le rétablissement de l'accès et
 * l'invitation de groupe à accepter.
 */
export function buildInvitationEmail(input: InvitationEmailInput): InvitationEmail {
  const inviter = headerSafeName(input.inviterName);
  const group = input.groupName.replace(/[\r\n]+/g, " ").trim();
  const expires = formatDateFr(input.expiresAt);
  const subject = `${inviter} t'invite dans « ${group} » sur Kass'Dalle`;
  const accountLine = input.restoresAccess
    ? `Connecte-toi avec le compte Google ${input.toEmail} : ton accès sera rétabli, ` +
      `et l'invitation au groupe « ${group} » t'attendra dans Groupes familiaux.`
    : `Connecte-toi avec le compte Google ${input.toEmail}. Avec une autre adresse, ` +
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
 * Seul le code étendu `5.1.x` (adresse inexistante ou mal formée) compte :
 * un `5.4.x` ou `5.7.x` dit un quota ou une politique de Gmail, pas une
 * adresse fausse. Un 5xx sur une autre commande (`AUTH` 535 : mot de passe
 * d'application faux) est une erreur de configuration, et un 4xx une erreur
 * temporaire : l'invitation reste alors en `send_failed` et se renvoie.
 */
export function isPermanentRecipientRejection(err: unknown): boolean {
  if (err === null || typeof err !== "object") return false;
  const e = err as {
    responseCode?: unknown;
    command?: unknown;
    code?: unknown;
    response?: unknown;
    message?: unknown;
  };
  const code = typeof e.responseCode === "number" ? e.responseCode : null;
  if (code === null || code < 500 || code > 599) return false;
  const text = [e.response, e.message].filter((t) => typeof t === "string").join(" ");
  if (!/\b5\.1\.\d{1,3}\b/.test(text)) return false;
  if (e.code === "EENVELOPE") return true;
  return typeof e.command === "string" && /^RCPT\b/i.test(e.command.trim());
}
