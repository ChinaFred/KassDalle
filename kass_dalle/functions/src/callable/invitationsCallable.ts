/**
 * Invitations par e-mail : création, renvoi, annulation.
 *
 * `manageInvitationFn` aiguille sur `action` (`create`, `resend`, `cancel`).
 * Réservée à un administrateur non révoqué (`requireAdmin`). La liste des
 * invitations ne passe pas par ici : l'écran la lit directement dans
 * Firestore, où les règles réservent `invitations` à l'administrateur.
 *
 * Ce que le serveur vérifie, et que le client ne peut pas contourner :
 *  - le rôle donné est `reader` ou `editor`, jamais `admin` ;
 *  - l'appelant appartient au groupe choisi (propriétaire ou membre) ;
 *  - l'adresse n'a pas de compte (comparée sur sa clé normalisée,
 *    `normalizeEmailKey`) ;
 *  - une seule invitation active par adresse ;
 *  - vingt envois par administrateur et par jour UTC, créations et renvois
 *    confondus (`invitation_sends_daily`).
 *
 * L'invitation est enregistrée **avant** l'envoi. Un échec SMTP, ou des
 * secrets vides, la laisse en `send_failed` avec `last_error` lisible, et la
 * callable rend `status: "send_failed"` au lieu de lever : l'invitation existe
 * et se renvoie depuis la liste. Les refus métier (adresse déjà inscrite,
 * doublon, plafond) sont des réponses `status: "refused"`, pas des erreurs.
 *
 * Aucun appel de modèle : pas de poste d'IA.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore, FieldValue, Timestamp } from "firebase-admin/firestore";

import {
  COLL_GROUPS,
  COLL_INVITATIONS,
  COLL_INVITATION_SENDS_DAILY,
  COLL_USERS,
  GMAIL_APP_PASSWORD,
  GMAIL_SENDER,
  MAX_CALLABLE_INSTANCES,
  REGION,
} from "../config";
import { requireAdmin, type AuthContext } from "./_auth";
import { spendDay } from "../ai/budget";
import { logError, logInfo } from "../logging";
import { FOUNDER_EMAIL, isFounderEmail } from "../triggers/founderRole";
import {
  INVITATION_DAILY_LIMIT,
  accountRefusal,
  buildInvitationEmail,
  cleanEmail,
  cleanMessage,
  effectiveStatus,
  expiryFrom,
  isActiveInvitation,
  isInvitableRole,
  normalizeEmailKey,
  readableSendError,
  type ExistingAccount,
} from "../invitations/rules";
import { mailCredentials, sendMail } from "../invitations/mailer";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

const opts = {
  region: REGION,
  cors: ALLOWED_ORIGINS,
  maxInstances: MAX_CALLABLE_INSTANCES,
  timeoutSeconds: 60,
  secrets: [GMAIL_SENDER, GMAIL_APP_PASSWORD],
};

/** Libellé provisoire d'un envoi pas encore confirmé par le serveur SMTP. */
const SENDING_PLACEHOLDER = "Envoi en cours ou interrompu.";

type Refusal = {
  status: "refused";
  reason: string;
  message: string;
  field: "email" | "group" | null;
  invitationId?: string;
  existingUid?: string;
};

type SendOutcome =
  | { status: "sent"; invitationId: string }
  | { status: "send_failed"; invitationId: string; error: string };

function refused(
  reason: string,
  message: string,
  field: Refusal["field"],
  extra: Partial<Refusal> = {},
): Refusal {
  return { status: "refused", reason, message, field, ...extra };
}

function readCount(data: FirebaseFirestore.DocumentData | undefined): number {
  const n = data?.count;
  return typeof n === "number" && Number.isFinite(n) && n > 0 ? n : 0;
}

function counterRef(uid: string, at: Date) {
  return getFirestore()
    .collection(COLL_INVITATION_SENDS_DAILY)
    .doc(`${uid}_${spendDay(at)}`);
}

const DAILY_LIMIT_MESSAGE =
  `Plafond atteint : ${INVITATION_DAILY_LIMIT} envois d'invitation par jour. ` +
  "Réessayez demain.";

/** Nom et adresse de l'administrateur qui envoie. */
async function inviterIdentity(
  uid: string,
  tokenEmail: unknown,
): Promise<{ name: string; email: string | null }> {
  const snap = await getFirestore().collection(COLL_USERS).doc(uid).get();
  const data = snap.data() ?? {};
  const pick = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : null);
  const email = pick(data.email) ?? pick(tokenEmail);
  const name = pick(data.preferred_name) ?? pick(data.display_name) ?? email ?? "Kass'Dalle";
  return { name, email };
}

/**
 * Le compte qui porte déjà cette adresse, ou `null`.
 *
 * Comparaison sur la clé normalisée : `users.email` est l'adresse du jeton
 * Google, que l'administrateur peut avoir saisie avec d'autres points ou un
 * suffixe `+…`. Une requête d'égalité ne les retrouverait pas ; la collection
 * d'une famille se lit entière, trois champs par document.
 */
async function existingAccountFor(
  key: string,
): Promise<{ uid: string; account: ExistingAccount } | null> {
  if (key === normalizeEmailKey(FOUNDER_EMAIL)) {
    return { uid: "", account: { role: "admin", isRevoked: false, isFounder: true } };
  }
  const snap = await getFirestore()
    .collection(COLL_USERS)
    .select("email", "role", "is_revoked")
    .get();
  for (const doc of snap.docs) {
    const email = doc.get("email");
    if (normalizeEmailKey(email) !== key) continue;
    const role = doc.get("role");
    return {
      uid: doc.id,
      account: {
        role: typeof role === "string" && role.trim() ? role.trim() : null,
        isRevoked: doc.get("is_revoked") === true,
        isFounder: isFounderEmail(typeof email === "string" ? email : null),
      },
    };
  }
  return null;
}

/** Envoie l'e-mail d'une invitation enregistrée, puis note le résultat. */
async function deliver(
  ctx: AuthContext,
  invitationId: string,
  mail: {
    to: string;
    inviterName: string;
    inviterEmail: string | null;
    groupName: string;
    message: string;
    expiresAt: Date;
  },
): Promise<SendOutcome> {
  const ref = getFirestore().collection(COLL_INVITATIONS).doc(invitationId);
  let error: string | null = null;
  try {
    const credentials = mailCredentials(GMAIL_SENDER.value(), GMAIL_APP_PASSWORD.value());
    const email = buildInvitationEmail({
      inviterName: mail.inviterName,
      groupName: mail.groupName,
      message: mail.message,
      toEmail: mail.to,
      expiresAt: mail.expiresAt,
    });
    await sendMail(credentials, {
      fromName: email.fromName,
      to: mail.to,
      replyTo: mail.inviterEmail,
      subject: email.subject,
      text: email.text,
      html: email.html,
    });
  } catch (err) {
    error = readableSendError(err);
    await logError({
      message: `manageInvitationFn: e-mail d'invitation non envoyé (${invitationId})`,
      errorDescription: error,
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      firestoreDocId: invitationId,
    });
  }

  try {
    await ref.update(
      error === null
        ? { status: "sent", last_error: null }
        : { status: "send_failed", last_error: error },
    );
  } catch (err) {
    // L'e-mail est parti (ou non) ; seul le statut n'a pas suivi. L'invitation
    // reste en `send_failed` « Envoi en cours ou interrompu » : elle donne
    // quand même le rôle, et un renvoi la remet d'aplomb.
    await logError({
      message: `manageInvitationFn: statut d'envoi non enregistré (${invitationId})`,
      errorDescription: err instanceof Error ? err.message : String(err),
      userId: ctx.userId,
      correlationId: ctx.correlationId,
      firestoreDocId: invitationId,
    });
  }

  return error === null
    ? { status: "sent", invitationId }
    : { status: "send_failed", invitationId, error };
}

async function createInvitation(
  ctx: AuthContext,
  data: Record<string, unknown>,
  tokenEmail: unknown,
): Promise<SendOutcome | Refusal> {
  const role = data.role;
  if (role === "admin") {
    throw new HttpsError(
      "invalid-argument",
      "Une invitation ne donne jamais le rôle administrateur.",
    );
  }
  if (!isInvitableRole(role)) {
    throw new HttpsError("invalid-argument", "role doit valoir reader ou editor.");
  }
  const groupId = typeof data.groupId === "string" ? data.groupId.trim() : "";
  if (groupId.length === 0 || groupId.includes("/")) {
    return refused("group_required", "Choisissez un groupe.", "group");
  }
  const email = cleanEmail(data.email);
  const key = normalizeEmailKey(data.email);
  if (email === null || key === null) {
    return refused("invalid_email", "Adresse e-mail invalide.", "email");
  }

  const db = getFirestore();
  const groupSnap = await db.collection(COLL_GROUPS).doc(groupId).get();
  if (!groupSnap.exists) {
    return refused("group_missing", "Ce groupe n'existe plus.", "group");
  }
  const ownerId = groupSnap.get("owner_id");
  const members = groupSnap.get("member_ids");
  const isMember =
    ownerId === ctx.userId || (Array.isArray(members) && members.includes(ctx.userId));
  if (!isMember) {
    return refused("group_not_member", "Vous n'appartenez pas à ce groupe.", "group");
  }
  const groupName =
    typeof groupSnap.get("name") === "string" ? (groupSnap.get("name") as string) : "";

  const existing = await existingAccountFor(key);
  const accountDenial = accountRefusal(existing?.account ?? null);
  if (accountDenial) {
    return refused(accountDenial.reason, accountDenial.message, "email", {
      ...(existing?.uid ? { existingUid: existing.uid } : {}),
    });
  }

  const message = cleanMessage(data.message, groupName);
  const inviter = await inviterIdentity(ctx.userId, tokenEmail);
  const now = new Date();
  const expiresAt = expiryFrom(now);
  const invitations = db.collection(COLL_INVITATIONS);
  const invRef = invitations.doc();
  const counter = counterRef(ctx.userId, now);

  const outcome = await db.runTransaction(async (tx) => {
    const sameKey = await tx.get(invitations.where("email_key", "==", key));
    const active = sameKey.docs.find((d) => isActiveInvitation(d.data(), now));
    if (active) {
      return refused(
        "duplicate",
        "Une invitation est déjà en attente pour cette adresse.",
        "email",
        { invitationId: active.id },
      );
    }
    const used = readCount((await tx.get(counter)).data());
    if (used >= INVITATION_DAILY_LIMIT) {
      return refused("daily_limit", DAILY_LIMIT_MESSAGE, null);
    }
    const at = Timestamp.fromDate(now);
    tx.set(
      counter,
      { uid: ctx.userId, day: spendDay(now), count: FieldValue.increment(1), updated_at: at },
      { merge: true },
    );
    tx.set(invRef, {
      email,
      email_key: key,
      role,
      group_id: groupId,
      group_name: groupName,
      message,
      invited_by: ctx.userId,
      invited_by_name: inviter.name,
      status: "send_failed",
      created_at: at,
      last_sent_at: at,
      last_sent_by: ctx.userId,
      expires_at: Timestamp.fromDate(expiresAt),
      send_count: 1,
      last_error: SENDING_PLACEHOLDER,
      accepted_uid: null,
      accepted_at: null,
      cancelled_by: null,
      cancelled_at: null,
      group_missing: false,
    });
    return null;
  });
  if (outcome) return outcome;

  await logInfo({
    message: `manageInvitationFn: invitation enregistrée (${role}, groupe ${groupId})`,
    userId: ctx.userId,
    correlationId: ctx.correlationId,
    firestoreDocId: invRef.id,
  });

  return deliver(ctx, invRef.id, {
    to: email,
    inviterName: inviter.name,
    inviterEmail: inviter.email,
    groupName,
    message,
    expiresAt,
  });
}

async function resendInvitation(
  ctx: AuthContext,
  invitationId: string,
  tokenEmail: unknown,
): Promise<SendOutcome | Refusal> {
  const db = getFirestore();
  const invitations = db.collection(COLL_INVITATIONS);
  const ref = invitations.doc(invitationId);
  const snap = await ref.get();
  if (!snap.exists) {
    return refused("not_found", "Cette invitation n'existe plus.", null);
  }
  const current = snap.data() ?? {};
  const key = typeof current.email_key === "string" ? current.email_key : null;
  const email = cleanEmail(current.email);
  if (key === null || email === null) {
    return refused("invalid_email", "Adresse e-mail de l'invitation illisible.", null);
  }

  // Un compte a pu naître entre-temps sous une autre adresse Google, ou sous
  // celle-ci avant que l'invitation n'ait été lue : il n'y a plus rien à envoyer.
  const existing = await existingAccountFor(key);
  const accountDenial = accountRefusal(existing?.account ?? null);
  if (accountDenial) {
    return refused(accountDenial.reason, accountDenial.message, null, {
      ...(existing?.uid ? { existingUid: existing.uid } : {}),
    });
  }

  const inviter = await inviterIdentity(ctx.userId, tokenEmail);
  const now = new Date();
  const expiresAt = expiryFrom(now);
  const counter = counterRef(ctx.userId, now);

  const outcome = await db.runTransaction(async (tx) => {
    const fresh = await tx.get(ref);
    const data = fresh.data() ?? {};
    const status = effectiveStatus(data, now);
    if (status === "accepted" || status === "cancelled") {
      return refused(
        "not_resendable",
        status === "accepted"
          ? "Cette invitation a déjà été acceptée."
          : "Cette invitation a été annulée.",
        null,
      );
    }
    const sameKey = await tx.get(invitations.where("email_key", "==", key));
    const other = sameKey.docs.find(
      (d) => d.id !== invitationId && isActiveInvitation(d.data(), now),
    );
    if (other) {
      return refused("duplicate", "Une autre invitation est en attente pour cette adresse.", null, {
        invitationId: other.id,
      });
    }
    const used = readCount((await tx.get(counter)).data());
    if (used >= INVITATION_DAILY_LIMIT) {
      return refused("daily_limit", DAILY_LIMIT_MESSAGE, null);
    }
    const at = Timestamp.fromDate(now);
    tx.set(
      counter,
      { uid: ctx.userId, day: spendDay(now), count: FieldValue.increment(1), updated_at: at },
      { merge: true },
    );
    tx.update(ref, {
      status: "send_failed",
      last_error: SENDING_PLACEHOLDER,
      last_sent_at: at,
      last_sent_by: ctx.userId,
      expires_at: Timestamp.fromDate(expiresAt),
      send_count: FieldValue.increment(1),
    });
    return null;
  });
  if (outcome) return outcome;

  await logInfo({
    message: `manageInvitationFn: invitation renvoyée (${invitationId})`,
    userId: ctx.userId,
    correlationId: ctx.correlationId,
    firestoreDocId: invitationId,
  });

  return deliver(ctx, invitationId, {
    to: email,
    inviterName: inviter.name,
    inviterEmail: inviter.email,
    groupName: typeof current.group_name === "string" ? current.group_name : "",
    message:
      typeof current.message === "string"
        ? current.message
        : cleanMessage("", String(current.group_name ?? "")),
    expiresAt,
  });
}

async function cancelInvitation(
  ctx: AuthContext,
  invitationId: string,
): Promise<{ status: "cancelled"; invitationId: string } | Refusal> {
  const db = getFirestore();
  const ref = db.collection(COLL_INVITATIONS).doc(invitationId);
  const outcome = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) return refused("not_found", "Cette invitation n'existe plus.", null);
    const status = snap.get("status");
    if (status === "accepted") {
      return refused("not_cancellable", "Cette invitation a déjà été acceptée.", null);
    }
    if (status === "cancelled") return null;
    tx.update(ref, {
      status: "cancelled",
      cancelled_by: ctx.userId,
      cancelled_at: Timestamp.now(),
    });
    return null;
  });
  if (outcome) return outcome;
  await logInfo({
    message: `manageInvitationFn: invitation annulée (${invitationId})`,
    userId: ctx.userId,
    correlationId: ctx.correlationId,
    firestoreDocId: invitationId,
  });
  return { status: "cancelled", invitationId };
}

export const manageInvitationFn = onCall(opts, async (req) => {
  const ctx = await requireAdmin(req, "invitation");
  const data = (req.data ?? {}) as Record<string, unknown>;
  const tokenEmail = (req.auth?.token as Record<string, unknown> | undefined)?.email;
  const invitationId = typeof data.invitationId === "string" ? data.invitationId.trim() : "";

  switch (data.action) {
    case "create":
      return createInvitation(ctx, data, tokenEmail);
    case "resend":
    case "cancel":
      if (invitationId.length === 0 || invitationId.includes("/")) {
        throw new HttpsError("invalid-argument", "invitationId manquant.");
      }
      return data.action === "resend"
        ? resendInvitation(ctx, invitationId, tokenEmail)
        : cancelInvitation(ctx, invitationId);
    default:
      throw new HttpsError("invalid-argument", "action doit valoir create, resend ou cancel.");
  }
});
