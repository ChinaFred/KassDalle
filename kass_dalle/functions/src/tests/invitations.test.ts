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
  accountRefusal,
  buildInvitationEmail,
  cleanEmail,
  cleanMessage,
  effectiveStatus,
  escapeHtml,
  expiryFrom,
  headerSafeName,
  isActiveInvitation,
  isInvitableRole,
  isPermanentRecipientRejection,
  maskEmails,
  normalizeEmailKey,
  pickActiveInvitation,
  readableSendError,
} from "../invitations/rules";
import { MailNotConfiguredError, mailCredentials } from "../invitations/mailer";
import { awaitsRole, inviterStillAdmin, inviterUidOf } from "../triggers/invitationSignup";
import { stateAfterReread } from "../triggers/userClaimsSync";

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
    );
    assert.equal(picked?.id, "new");
    assert.equal(
      pickActiveInvitation([{ id: "x", data: { status: "sent", expires_at: EARLIER } }], NOW),
      null,
    );
  });
});

describe("compte existant", () => {
  test("aucun compte : pas de refus", () => {
    assert.equal(accountRefusal(null), null);
  });

  test("compte actif : refus avec le rôle", () => {
    const r = accountRefusal({ role: "editor", isRevoked: false, isFounder: false });
    assert.equal(r?.reason, "account_active");
    assert.equal(
      r?.message,
      "Cette adresse a déjà un compte (éditeur). Changez son rôle dans l'onglet Comptes, " +
        "et invitez-le depuis le groupe.",
    );
  });

  test("compte en attente", () => {
    const r = accountRefusal({ role: "pending", isRevoked: false, isFounder: false });
    assert.equal(r?.reason, "account_pending");
    assert.equal(r?.message, "Ce compte attend déjà un rôle.");
  });

  test("compte révoqué et fondateur", () => {
    assert.equal(
      accountRefusal({ role: "reader", isRevoked: true, isFounder: false })?.reason,
      "account_revoked",
    );
    assert.equal(
      accountRefusal({ role: "admin", isRevoked: false, isFounder: true })?.reason,
      "founder",
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
    });
    assert.equal(isPermanentRecipientRejection(env), true);
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
