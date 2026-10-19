/**
 * Invitations par e-mail : clé d'adresse, statut effectif, refus d'un compte
 * existant, message et composition de l'e-mail, lecture d'une erreur SMTP.
 * Logique pure. Le statut effectif rejoue aussi la fixture partagée avec Dart
 * (`test-fixtures/email_invitation_status.json`).
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import {
  APK_URL,
  APP_URL,
  INVITATION_MESSAGE_MAX,
  INVITATION_TTL_DAYS,
  ADDRESS_REJECTED_PREFIX,
  RESTORED_BY_HAND_MESSAGE,
  RESTORED_BY_OTHER_INVITATION_MESSAGE,
  GROUP_INVITED_MAX,
  TARGET_CHANGED_MESSAGE,
  accountDecision,
  buildInvitationEmail,
  cleanEmail,
  cleanMessage,
  effectiveStatus,
  escapeHtml,
  groupInviteFor,
  invitationGroupOf,
  resendGroupOwnerDecision,
  invitationFits,
  invitationTargetOf,
  expiryFrom,
  headerSafeName,
  isAccessRestored,
  isActiveInvitation,
  isInvitableRole,
  isOpenReturnInvitationFor,
  isStaleReturnInvitation,
  isPermanentRecipientRejection,
  maskEmails,
  normalizeEmailKey,
  pickActiveInvitation,
  readableSendError,
  resendRefusal,
  staleReturnInvitations,
  targetUidOf,
} from "../invitations/rules";
import { MailNotConfiguredError, mailCredentials } from "../invitations/mailer";
import {
  awaitsRole,
  inviterStillAdmin,
  inviterUidOf,
  isRevokedSignIn,
} from "../triggers/invitationSignup";
import { claimsFrom, shouldRevokeSessions, stateAfterReread } from "../triggers/userClaimsSync";
import { planningShareChanged } from "../triggers/planningReach";

const STATUS_FIXTURE = path.join(
  __dirname,
  "..",
  "..",
  "..",
  "test-fixtures",
  "email_invitation_status.json",
);

const statusFixture = JSON.parse(readFileSync(STATUS_FIXTURE, "utf8")) as {
  cases: {
    name: string;
    status: string;
    expires_at: string | null;
    now: string;
    expected: string;
    active: boolean;
  }[];
};

describe("statut effectif — fixture partagée avec Dart", () => {
  for (const c of statusFixture.cases) {
    test(c.name, () => {
      const data = {
        status: c.status,
        ...(c.expires_at === null ? {} : { expires_at: new Date(c.expires_at) }),
      };
      const now = new Date(c.now);
      assert.equal(effectiveStatus(data, now), c.expected);
      assert.equal(isActiveInvitation(data, now), c.active);
    });
  }
});

const NOW = new Date("2026-10-12T10:00:00Z");
const LATER = new Date("2026-10-20T10:00:00Z");
const EARLIER = new Date("2026-10-01T10:00:00Z");

describe("normalizeEmailKey", () => {
  test("espaces et casse", () => {
    assert.equal(normalizeEmailKey("  Marie.Durand@Example.FR "), "marie.durand@example.fr");
  });

  test("Gmail : points et suffixe + retirés", () => {
    assert.equal(normalizeEmailKey("Jean.Dupont+cuisine@gmail.com"), "jeandupont@gmail.com");
  });

  test("googlemail.com devient gmail.com", () => {
    assert.equal(normalizeEmailKey("jean.dupont@googlemail.com"), "jeandupont@gmail.com");
  });

  test("un autre domaine garde ses points et son +", () => {
    assert.equal(normalizeEmailKey("a.b+c@orange.fr"), "a.b+c@orange.fr");
  });

  test("formes refusées", () => {
    for (const bad of [
      "",
      "   ",
      "sans-arobase",
      "a@b",
      "a b@c.fr",
      "a@b.fr\nBcc: x@y.fr",
      "<a@b.fr>",
      "a@b.fr,c@d.fr",
      "+x@gmail.com",
      42,
      null,
    ]) {
      assert.equal(normalizeEmailKey(bad), null, String(bad));
    }
  });

  test("cleanEmail garde la partie locale telle quelle", () => {
    assert.equal(cleanEmail(" Jean.Dupont@Gmail.com "), "jean.dupont@gmail.com");
  });
});

describe("rôles invitables", () => {
  test("reader et editor, jamais admin", () => {
    assert.equal(isInvitableRole("reader"), true);
    assert.equal(isInvitableRole("editor"), true);
    assert.equal(isInvitableRole("admin"), false);
    assert.equal(isInvitableRole("pending"), false);
    assert.equal(isInvitableRole(undefined), false);
  });
});

describe("statut effectif", () => {
  test("envoyée non expirée", () => {
    assert.equal(effectiveStatus({ status: "sent", expires_at: LATER }, NOW), "sent");
    assert.equal(isActiveInvitation({ status: "sent", expires_at: LATER }, NOW), true);
  });

  test("échec d'envoi non expiré reste actif", () => {
    assert.equal(effectiveStatus({ status: "send_failed", expires_at: LATER }, NOW), "send_failed");
    assert.equal(isActiveInvitation({ status: "send_failed", expires_at: LATER }, NOW), true);
  });

  test("date passée : expirée", () => {
    assert.equal(effectiveStatus({ status: "sent", expires_at: EARLIER }, NOW), "expired");
    assert.equal(isActiveInvitation({ status: "sent", expires_at: EARLIER }, NOW), false);
  });

  test("date absente ou illisible : expirée", () => {
    assert.equal(effectiveStatus({ status: "sent" }, NOW), "expired");
    assert.equal(effectiveStatus({ status: "sent", expires_at: "demain" }, NOW), "expired");
  });

  test("Timestamp Firestore lu par toDate()", () => {
    const ts = { toDate: () => LATER };
    assert.equal(effectiveStatus({ status: "sent", expires_at: ts }, NOW), "sent");
  });

  test("acceptée et annulée ne changent pas avec le temps", () => {
    assert.equal(effectiveStatus({ status: "accepted", expires_at: EARLIER }, NOW), "accepted");
    assert.equal(effectiveStatus({ status: "cancelled", expires_at: LATER }, NOW), "cancelled");
    assert.equal(isActiveInvitation({ status: "accepted", expires_at: LATER }, NOW), false);
  });

  test("expiration à trente jours du dernier envoi", () => {
    const exp = expiryFrom(NOW);
    assert.equal((exp.getTime() - NOW.getTime()) / 86_400_000, INVITATION_TTL_DAYS);
  });

  test("la plus récemment envoyée des actives l'emporte", () => {
    const picked = pickActiveInvitation(
      [
        { id: "old", data: { status: "sent", expires_at: LATER, last_sent_at: EARLIER } },
        { id: "new", data: { status: "send_failed", expires_at: LATER, last_sent_at: NOW } },
        { id: "gone", data: { status: "cancelled", expires_at: LATER, last_sent_at: LATER } },
      ],
      NOW,
      { kind: "new" },
    );
    assert.equal(picked?.id, "new");
    assert.equal(
      pickActiveInvitation([{ id: "x", data: { status: "sent", expires_at: EARLIER } }], NOW, {
        kind: "new",
      }),
      null,
    );
  });
});

describe("compte visé par une invitation", () => {
  const active = { status: "sent", expires_at: LATER, last_sent_at: NOW };
  const legacy = { id: "legacy", data: { ...active } };
  const fresh = { id: "fresh", data: { ...active, target: "new", target_uid: null } };
  const back = { id: "back", data: { ...active, target: "revoked", target_uid: "gabriel" } };
  const other = { id: "other", data: { ...active, target: "revoked", target_uid: "autre" } };

  test("sans champ target : invitation de compte neuf", () => {
    assert.equal(invitationTargetOf(legacy.data), "new");
    assert.equal(invitationTargetOf(back.data), "revoked");
    assert.equal(invitationTargetOf({ target: "n'importe quoi" }), "new");
    assert.equal(targetUidOf(back.data), "gabriel");
    assert.equal(targetUidOf(fresh.data), null);
    assert.equal(targetUidOf({ target: "revoked", target_uid: "a/b" }), null);
    assert.equal(targetUidOf({ target: "revoked" }), null);
  });

  test("un compte neuf ne prend jamais une invitation de retour", () => {
    assert.equal(invitationFits(legacy.data, { kind: "new" }), true);
    assert.equal(invitationFits(fresh.data, { kind: "new" }), true);
    assert.equal(invitationFits(back.data, { kind: "new" }), false);
    assert.equal(pickActiveInvitation([back, other], NOW, { kind: "new" }), null);
  });

  test("un compte révoqué ne prend que l'invitation qui le vise", () => {
    assert.equal(invitationFits(back.data, { kind: "revoked", uid: "gabriel" }), true);
    assert.equal(invitationFits(other.data, { kind: "revoked", uid: "gabriel" }), false);
    assert.equal(invitationFits(fresh.data, { kind: "revoked", uid: "gabriel" }), false);
    assert.equal(invitationFits(legacy.data, { kind: "revoked", uid: "gabriel" }), false);
    assert.equal(
      pickActiveInvitation([legacy, other, back], NOW, { kind: "revoked", uid: "gabriel" })?.id,
      "back",
    );
    assert.equal(
      pickActiveInvitation([legacy, other], NOW, { kind: "revoked", uid: "gabriel" }),
      null,
    );
  });

  test("une invitation de retour expirée, annulée ou acceptée ne s'applique plus", () => {
    for (const data of [
      { ...back.data, expires_at: EARLIER },
      { ...back.data, status: "cancelled" },
      { ...back.data, status: "accepted" },
    ]) {
      assert.equal(
        pickActiveInvitation([{ id: "x", data }], NOW, { kind: "revoked", uid: "gabriel" }),
        null,
      );
    }
  });
});

describe("compte existant", () => {
  test("aucun compte : invitation de compte neuf", () => {
    assert.deepEqual(accountDecision(null), { kind: "new" });
  });

  test("compte actif : refus avec le rôle", () => {
    const r = accountDecision({ role: "editor", isRevoked: false, isFounder: false });
    assert.equal(r.kind, "refused");
    assert.equal(r.kind === "refused" ? r.reason : null, "account_active");
    assert.equal(
      r.kind === "refused" ? r.message : null,
      "Cette adresse a déjà un compte (éditeur). Changez son rôle dans l'onglet Comptes, " +
        "et invitez-le depuis le groupe.",
    );
  });

  test("compte en attente", () => {
    const r = accountDecision({ role: "pending", isRevoked: false, isFounder: false });
    assert.equal(r.kind === "refused" ? r.reason : null, "account_pending");
    assert.equal(r.kind === "refused" ? r.message : null, "Ce compte attend déjà un rôle.");
  });

  test("compte révoqué : invitation de retour", () => {
    assert.deepEqual(accountDecision({ role: "reader", isRevoked: true, isFounder: false }), {
      kind: "revoked",
    });
    assert.deepEqual(accountDecision({ role: "pending", isRevoked: true, isFounder: false }), {
      kind: "revoked",
    });
  });

  test("fondateur, révoqué ou non : refus", () => {
    for (const isRevoked of [false, true]) {
      const r = accountDecision({ role: "admin", isRevoked, isFounder: true });
      assert.equal(r.kind === "refused" ? r.reason : null, "founder");
    }
  });
});

describe("renvoi selon le compte visé", () => {
  const revoked = { role: "reader", isRevoked: true, isFounder: false };
  const active = { role: "reader", isRevoked: false, isFounder: false };
  const back = { target: "revoked", target_uid: "gabriel" };

  test("compte neuf : toujours sans compte", () => {
    assert.equal(resendRefusal({}, null), null);
    assert.equal(resendRefusal({ target: "new" }, null), null);
    assert.equal(resendRefusal({}, { uid: "x", account: active })?.reason, "account_active");
    assert.deepEqual(resendRefusal({}, { uid: "x", account: revoked }), {
      reason: "target_changed",
      message: TARGET_CHANGED_MESSAGE,
    });
  });

  test("compte révoqué : le même compte, toujours révoqué", () => {
    assert.equal(resendRefusal(back, { uid: "gabriel", account: revoked }), null);
    assert.equal(resendRefusal(back, { uid: "autre", account: revoked })?.reason, "target_changed");
    assert.equal(resendRefusal(back, null)?.reason, "target_changed");
    assert.equal(
      resendRefusal(back, { uid: "gabriel", account: active })?.reason,
      "account_active",
    );
  });
});

describe("groupe au retour d'un compte révoqué", () => {
  test("invitation de groupe, jamais d'entrée directe", () => {
    assert.equal(
      groupInviteFor({ owner_id: "o", member_ids: ["o"], invited_ids: [] }, "g"),
      "invited",
    );
    assert.equal(groupInviteFor({ owner_id: "o", member_ids: ["o"] }, "g"), "invited");
  });

  test("déjà membre, propriétaire ou déjà invité : rien à écrire", () => {
    assert.equal(groupInviteFor({ owner_id: "o", member_ids: ["o", "g"] }, "g"), "already_member");
    assert.equal(groupInviteFor({ owner_id: "g", member_ids: [] }, "g"), "already_member");
    assert.equal(
      groupInviteFor({ owner_id: "o", member_ids: ["o"], invited_ids: ["g"] }, "g"),
      "already_invited",
    );
  });

  test("plafond de 50 invitations en attente", () => {
    const full = Array.from({ length: GROUP_INVITED_MAX }, (_, i) => `u${i}`);
    assert.equal(
      groupInviteFor({ owner_id: "o", member_ids: ["o"], invited_ids: full }, "g"),
      "full",
    );
    assert.equal(
      groupInviteFor({ owner_id: "o", member_ids: ["o"], invited_ids: full.slice(1) }, "g"),
      "invited",
    );
  });

  test("groupe supprimé", () => {
    assert.equal(groupInviteFor(null, "g"), "missing");
    assert.equal(groupInviteFor(undefined, "g"), "missing");
  });

  test("invitant sorti du groupe : rien à écrire (missing)", () => {
    const group = { owner_id: "o", member_ids: ["o", "m"], invited_ids: [] };
    assert.equal(groupInviteFor(group, "g", "o"), "invited");
    assert.equal(groupInviteFor(group, "g", "m"), "invited");
    assert.equal(groupInviteFor(group, "g", "parti"), "missing");
    assert.equal(groupInviteFor(group, "g", null), "missing");
    assert.equal(groupInviteFor(group, "g", ""), "missing");
    // Le compte déjà membre ou déjà invité le reste, quel que soit l'invitant.
    assert.equal(
      groupInviteFor({ ...group, member_ids: ["o", "g"] }, "g", "parti"),
      "already_member",
    );
    assert.equal(groupInviteFor({ ...group, invited_ids: ["g"] }, "g", "parti"), "already_invited");
  });
});

describe("invitations de retour sans objet", () => {
  const now = new Date("2026-10-12T10:00:00Z");
  const future = new Date("2026-11-01T00:00:00Z");
  const open = (id: string, extra: Record<string, unknown> = {}) => ({
    id,
    data: {
      status: "sent",
      expires_at: future,
      target: "revoked",
      target_uid: "gab",
      ...extra,
    },
  });

  test("compte rétabli : révoqué avant, présent et non révoqué après", () => {
    assert.equal(isAccessRestored({ is_revoked: true }, { is_revoked: false }), true);
    assert.equal(isAccessRestored({ is_revoked: true }, {}), true);
    assert.equal(isAccessRestored({ is_revoked: true }, { is_revoked: true }), false);
    assert.equal(isAccessRestored({ is_revoked: false }, { is_revoked: false }), false);
    assert.equal(isAccessRestored({ is_revoked: true }, undefined), false);
    assert.equal(isAccessRestored(undefined, { is_revoked: false }), false);
  });

  test("invitation de retour ouverte : ce compte, active", () => {
    assert.equal(isOpenReturnInvitationFor(open("a").data, "gab", now), true);
    assert.equal(isOpenReturnInvitationFor(open("a").data, "autre", now), false);
    assert.equal(
      isOpenReturnInvitationFor(open("a", { status: "send_failed" }).data, "gab", now),
      true,
    );
    assert.equal(
      isOpenReturnInvitationFor(open("a", { status: "accepted" }).data, "gab", now),
      false,
    );
    assert.equal(
      isOpenReturnInvitationFor(open("a", { expires_at: new Date(0) }).data, "gab", now),
      false,
    );
    assert.equal(
      isOpenReturnInvitationFor(open("a", { target: "new", target_uid: null }).data, "gab", now),
      false,
    );
  });

  test("rétablissement à la main : les actives sont annulées", () => {
    const { stale, reason } = staleReturnInvitations(
      [
        open("active"),
        open("expiree", { expires_at: new Date(0) }),
        open("annulee", { status: "cancelled" }),
        open("autre", { target_uid: "autre" }),
      ],
      "gab",
      now,
    );
    assert.deepEqual(
      stale.map((s) => s.id),
      ["active"],
    );
    assert.equal(reason, RESTORED_BY_HAND_MESSAGE);
    assert.equal(reason, "Accès rétabli à la main : invitation sans objet.");
  });

  test("une invitation envoyée après le rétablissement n'est pas annulée", () => {
    const before = new Date(now.getTime() - 60_000);
    const after = new Date(now.getTime() + 60_000);
    const { stale } = staleReturnInvitations(
      [
        open("avant", { last_sent_at: before }),
        open("pile", { last_sent_at: now }),
        open("apres", { last_sent_at: after }),
        open("renvoyee", { created_at: before, last_sent_at: after }),
        open("creee-seule", { created_at: before }),
        open("sans-date"),
      ],
      "gab",
      now,
    );
    assert.deepEqual(
      stale.map((s) => s.id),
      ["avant", "pile", "creee-seule", "sans-date"],
    );
    // Relue dans la transaction, plus tard : la date d'envoi reste comparée
    // au rétablissement, pas à l'heure de la relecture.
    const later = new Date(now.getTime() + 120_000);
    assert.equal(
      isStaleReturnInvitation(open("apres", { last_sent_at: after }).data, "gab", now, later),
      false,
    );
    assert.equal(
      isStaleReturnInvitation(open("avant", { last_sent_at: before }).data, "gab", now, later),
      true,
    );
    assert.equal(isStaleReturnInvitation(undefined, "gab", now, later), false);
  });

  test("rétablissement par une invitation : elle est acceptée, les autres sont annulées", () => {
    const accepted = open("appliquee", {
      status: "accepted",
      accepted_uid: "gab",
      accepted_at: new Date(now.getTime() - 2_000),
    });
    const { stale, reason } = staleReturnInvitations([accepted], "gab", now);
    assert.deepEqual(stale, []);
    const other = staleReturnInvitations([accepted, open("doublon")], "gab", now);
    assert.deepEqual(
      other.stale.map((s) => s.id),
      ["doublon"],
    );
    assert.equal(other.reason, RESTORED_BY_OTHER_INVITATION_MESSAGE);
    assert.equal(reason, RESTORED_BY_OTHER_INVITATION_MESSAGE);
    // Une acceptation ancienne n'explique pas ce rétablissement-ci.
    const old = open("ancienne", {
      status: "accepted",
      accepted_uid: "gab",
      accepted_at: new Date("2026-01-01T00:00:00Z"),
    });
    assert.equal(
      staleReturnInvitations([old, open("x")], "gab", now).reason,
      RESTORED_BY_HAND_MESSAGE,
    );
  });
});

describe("message", () => {
  test("vide reste vide ; borné à 500 caractères", () => {
    assert.equal(cleanMessage("   "), "");
    assert.equal(cleanMessage(undefined), "");
    assert.equal(cleanMessage("x".repeat(800)).length, INVITATION_MESSAGE_MAX);
    assert.equal(cleanMessage("a\r\nb"), "a\nb");
  });

  test("message vide : l'e-mail part sans paragraphe personnel", () => {
    const mail = buildInvitationEmail({
      inviterName: "Fred",
      groupName: "Les Kassbi",
      message: "",
      toEmail: "marie@gmail.com",
      expiresAt: new Date("2026-11-11T10:00:00Z"),
    });
    assert.ok(mail.text.startsWith(`Ouvrir Kass'Dalle : ${APP_URL}`));
    assert.ok(!mail.html.includes('<p style="margin:0 0 12px">'));
    assert.ok(mail.html.includes("Ouvrir Kass'Dalle"));
  });
});

describe("e-mail", () => {
  const mail = buildInvitationEmail({
    inviterName: "Fred",
    groupName: "Les Kassbi",
    message: "Salut <b>toi</b> & les autres",
    toEmail: "marie@gmail.com",
    expiresAt: new Date("2026-11-11T10:00:00Z"),
  });

  test("objet et expéditeur", () => {
    assert.equal(mail.subject, "Fred t'invite dans « Les Kassbi » sur Kass'Dalle");
    assert.equal(mail.fromName, "Fred via Kass'Dalle");
  });

  test("le message libre est échappé dans le HTML, pas dans le texte", () => {
    assert.ok(mail.html.includes("Salut &lt;b&gt;toi&lt;/b&gt; &amp; les autres"));
    assert.ok(!mail.html.includes("<b>toi</b>"));
    assert.ok(mail.text.startsWith("Salut <b>toi</b> & les autres"));
  });

  test("pied fixe : lien, APK, adresse, expiration, signature", () => {
    for (const part of [
      APP_URL,
      APK_URL,
      "Connecte-toi avec le compte Google marie@gmail.com.",
      "ton accès devra être validé à la main.",
      "Cette invitation expire le 11/11/2026.",
    ]) {
      assert.ok(mail.text.includes(part), part);
    }
    assert.ok(mail.text.trimEnd().endsWith("Fred"));
    assert.ok(mail.html.includes("Ouvrir Kass'Dalle"));
  });

  test("compte révoqué : le pied annonce le rétablissement et le groupe à accepter", () => {
    const back = buildInvitationEmail({
      inviterName: "Fred",
      groupName: "Les Kassbi",
      message: "",
      toEmail: "gabriel@gmail.com",
      expiresAt: new Date("2026-11-11T10:00:00Z"),
      restoresAccess: true,
    });
    const line =
      "Connecte-toi avec le compte Google gabriel@gmail.com : ton accès sera rétabli, " +
      "et l'invitation au groupe « Les Kassbi » t'attendra dans Groupes familiaux.";
    assert.ok(back.text.includes(line));
    assert.ok(back.html.includes(escapeHtml(line)));
    assert.ok(!back.text.includes("validé à la main"));
    assert.ok(back.text.includes("Cette invitation expire le 11/11/2026."));
    assert.ok(back.text.trimEnd().endsWith("Fred"));
  });

  test("nom d'en-tête nettoyé", () => {
    assert.equal(headerSafeName('Ev"il\r\nBcc: x'), "Ev il Bcc: x");
    assert.equal(headerSafeName("   "), "Kass'Dalle");
  });

  test("escapeHtml", () => {
    assert.equal(
      escapeHtml(`<a href="x">'&'</a>`),
      "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;",
    );
  });

  test("erreur SMTP lisible, une ligne", () => {
    assert.equal(
      readableSendError(new Error("535-5.7.8 Username\n  and Password")),
      "535-5.7.8 Username and Password",
    );
    assert.equal(readableSendError("x".repeat(400)).length, 300);
  });

  test("adresses masquées dans l'erreur", () => {
    assert.equal(maskEmails("t@gmail.com"), "t***@gmail.com");
    assert.equal(
      readableSendError(
        new Error(
          "550-5.1.1 The email account that you tried to reach does not exist: toto@gmail.com",
        ),
      ),
      "550-5.1.1 The email account that you tried to reach does not exist: t***@gmail.com",
    );
    assert.equal(
      maskEmails("Can't send mail - all recipients were rejected: <Jean.Dupont+x@orange.fr>"),
      "Can't send mail - all recipients were rejected: <J***@orange.fr>",
    );
  });
});

describe("refus définitif du destinataire", () => {
  test("5xx sur RCPT TO, ou enveloppe rejetée : définitif", () => {
    const rcpt = Object.assign(new Error("550 5.1.1"), { responseCode: 550, command: "RCPT TO" });
    assert.equal(isPermanentRecipientRejection(rcpt), true);
    const env = Object.assign(new Error("rejected"), {
      code: "EENVELOPE",
      responseCode: 553,
      command: "RCPT TO",
      response: "553 5.1.3 The recipient address is not a valid address",
    });
    assert.equal(isPermanentRecipientRejection(env), true);
  });

  test("5xx de quota ou de politique sur RCPT TO : pas définitif", () => {
    const quota = Object.assign(new Error("550 5.4.5 Daily user sending limit exceeded"), {
      responseCode: 550,
      command: "RCPT TO",
    });
    const policy = Object.assign(new Error("rejected"), {
      code: "EENVELOPE",
      responseCode: 550,
      command: "RCPT TO",
      response: "550 5.7.1 Message rejected by policy",
    });
    assert.equal(isPermanentRecipientRejection(quota), false);
    assert.equal(isPermanentRecipientRejection(policy), false);
  });

  test("temporaire ou configuration : pas définitif", () => {
    const temp = Object.assign(new Error("450"), { responseCode: 450, command: "RCPT TO" });
    const auth = Object.assign(new Error("535"), { responseCode: 535, command: "AUTH PLAIN" });
    const noCode = Object.assign(new Error("no recipients"), { code: "EENVELOPE" });
    assert.equal(isPermanentRecipientRejection(temp), false);
    assert.equal(isPermanentRecipientRejection(auth), false);
    assert.equal(isPermanentRecipientRejection(noCode), false);
    assert.equal(isPermanentRecipientRejection(new MailNotConfiguredError()), false);
    assert.equal(isPermanentRecipientRejection("550"), false);
  });

  test("motif lisible préfixé", () => {
    assert.equal(ADDRESS_REJECTED_PREFIX, "Adresse refusée par Gmail : ");
  });
});

describe("secrets", () => {
  test("vide → envoi non configuré", () => {
    assert.throws(() => mailCredentials("", "abcd"), MailNotConfiguredError);
    assert.throws(() => mailCredentials("a@gmail.com", "   "), MailNotConfiguredError);
  });

  test("le mot de passe d'application perd ses espaces", () => {
    assert.deepEqual(mailCredentials(" a@gmail.com ", "abcd efgh ijkl mnop"), {
      sender: "a@gmail.com",
      appPassword: "abcdefghijklmnop",
    });
  });
});

describe("déclencheur de première connexion", () => {
  test("n'agit que sur un compte pending non révoqué", () => {
    assert.equal(awaitsRole({ role: "pending", is_revoked: false }), true);
    assert.equal(awaitsRole({ role: "pending", is_revoked: true }), false);
    assert.equal(awaitsRole({ role: "reader", is_revoked: false }), false);
    assert.equal(awaitsRole(undefined), false);
  });

  test("l'invitant est celui du dernier envoi, sinon le créateur", () => {
    assert.equal(inviterUidOf({ invited_by: "a", last_sent_by: "b" }), "b");
    assert.equal(inviterUidOf({ invited_by: "a" }), "a");
    assert.equal(inviterUidOf({ invited_by: "a", last_sent_by: "" }), "a");
    assert.equal(inviterUidOf({ invited_by: "x/y" }), null);
    assert.equal(inviterUidOf({}), null);
  });

  test("invitant encore administrateur et non révoqué, sinon rien n'est appliqué", () => {
    assert.equal(inviterStillAdmin({ role: "admin", is_revoked: false }), true);
    assert.equal(inviterStillAdmin({ role: "admin", is_revoked: true }), false);
    assert.equal(inviterStillAdmin({ role: "editor", is_revoked: false }), false);
    assert.equal(inviterStillAdmin({ role: "pending" }), false);
    assert.equal(inviterStillAdmin(undefined), false);
  });
});

describe("déclencheur de reconnexion d'un compte révoqué", () => {
  const t1 = new Date("2026-10-01T10:00:00Z");
  const t2 = new Date("2026-10-12T10:00:00Z");

  test("révoqué avant et après, last_seen_at changé : connexion", () => {
    assert.equal(
      isRevokedSignIn(
        { is_revoked: true, last_seen_at: t1 },
        { is_revoked: true, last_seen_at: t2 },
      ),
      true,
    );
    assert.equal(
      isRevokedSignIn({ is_revoked: true }, { is_revoked: true, last_seen_at: t2 }),
      true,
    );
  });

  test("toute autre écriture ne déclenche rien", () => {
    // Même instant : écriture d'un autre champ.
    assert.equal(
      isRevokedSignIn(
        { is_revoked: true, last_seen_at: t1 },
        { is_revoked: true, last_seen_at: t1 },
      ),
      false,
    );
    // Rétablissement (le déclencheur lui-même, ou l'onglet Comptes).
    assert.equal(
      isRevokedSignIn(
        { is_revoked: true, last_seen_at: t1 },
        { is_revoked: false, last_seen_at: t2 },
      ),
      false,
    );
    // Compte actif qui se connecte.
    assert.equal(
      isRevokedSignIn(
        { is_revoked: false, last_seen_at: t1 },
        { is_revoked: false, last_seen_at: t2 },
      ),
      false,
    );
    // Révocation au moment d'une connexion.
    assert.equal(
      isRevokedSignIn(
        { is_revoked: false, last_seen_at: t1 },
        { is_revoked: true, last_seen_at: t2 },
      ),
      false,
    );
    assert.equal(isRevokedSignIn(undefined, { is_revoked: true, last_seen_at: t2 }), false);
    assert.equal(
      isRevokedSignIn({ is_revoked: true, last_seen_at: t1 }, { is_revoked: true }),
      false,
    );
  });

  test("le rétablissement repose les claims sans couper la session", () => {
    const before = claimsFrom({ role: "reader", is_revoked: true });
    const after = claimsFrom({ role: "editor", is_revoked: false });
    assert.deepEqual(after, { role: "editor", revoked: false });
    assert.equal(shouldRevokeSessions(before, after, true), false);
  });

  test("le rétablissement d'un éditeur recalcule la portée de ses plannings", () => {
    assert.equal(
      planningShareChanged(
        { role: "editor", is_revoked: true },
        { role: "editor", is_revoked: false },
      ),
      true,
    );
    assert.equal(
      planningShareChanged(
        { role: "reader", is_revoked: true },
        { role: "reader", is_revoked: false },
      ),
      false,
    );
  });
});

describe("syncUserClaims — relecture du document", () => {
  const snapshot = { role: "reader", is_revoked: false };

  test("document trouvé : son contenu actuel", () => {
    const now = { role: "editor", is_revoked: false };
    assert.deepEqual(stateAfterReread(snapshot, { kind: "found", data: now }), {
      exists: true,
      data: now,
    });
  });

  test("document absent à la relecture : traité comme une suppression", () => {
    assert.deepEqual(stateAfterReread(snapshot, { kind: "missing" }), {
      exists: false,
      data: undefined,
    });
  });

  test("lecture en échec : repli sur l'instantané", () => {
    assert.deepEqual(stateAfterReread(snapshot, { kind: "failed" }), {
      exists: true,
      data: snapshot,
    });
  });
});

describe("groupe recréé sous le même identifiant (ticket #152)", () => {
  const inviteA = { group_id: "g1", group_owner_id: "A", invited_by: "A" };

  test("invitation de A, groupe recréé par E : l'invité n'entre pas dans member_ids", () => {
    const pirate = { owner_id: "E", member_ids: ["E"], invited_ids: [] };
    assert.equal(invitationGroupOf(pirate, inviteA), null);
    // Le trigger traite alors le groupe comme absent : rien d'écrit sur le
    // groupe, `group_missing: true`, et au retour d'un compte révoqué
    // `groupInviteFor(null, …)` rend `missing`.
    assert.equal(groupInviteFor(invitationGroupOf(pirate, inviteA), "invite", "A"), "missing");
  });

  test("groupe de A : rendu tel quel", () => {
    const group = { owner_id: "A", member_ids: ["A"] };
    assert.equal(invitationGroupOf(group, inviteA), group);
  });

  test("invitation sans group_owner_id (avant le backfill) : groupe absent", () => {
    const group = { owner_id: "A", member_ids: ["A"] };
    for (const value of [undefined, "", 3, null]) {
      assert.equal(invitationGroupOf(group, { ...inviteA, group_owner_id: value }), null);
    }
  });

  test("groupe supprimé : null", () => {
    assert.equal(invitationGroupOf(null, inviteA), null);
    assert.equal(invitationGroupOf(undefined, inviteA), null);
  });

  test("renvoi : champ absent posé, égal gardé, différent refusé", () => {
    assert.equal(resendGroupOwnerDecision({ invited_by: "A" }, "A"), "write");
    assert.equal(resendGroupOwnerDecision({ group_owner_id: "", invited_by: "A" }, "A"), "write");
    assert.equal(resendGroupOwnerDecision({ group_owner_id: "A" }, "A"), "keep");
    assert.equal(resendGroupOwnerDecision({ group_owner_id: "A" }, "E"), "refuse");
  });

  test("renvoi d'une invitation sans champ : l'auteur doit être le propriétaire relu", () => {
    assert.equal(resendGroupOwnerDecision({ invited_by: "X" }, "E"), "refuse");
    assert.equal(resendGroupOwnerDecision({}, "E"), "refuse");
  });
});
