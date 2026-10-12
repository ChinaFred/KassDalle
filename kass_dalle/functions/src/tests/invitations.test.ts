/**
 * Invitations par e-mail : clé d'adresse, statut effectif, refus d'un compte
 * existant, message et composition de l'e-mail. Logique pure, serveur seul.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import {
  APK_URL,
  APP_URL,
  INVITATION_MESSAGE_MAX,
  INVITATION_TTL_DAYS,
  accountRefusal,
  buildInvitationEmail,
  cleanEmail,
  cleanMessage,
  defaultInvitationMessage,
  effectiveStatus,
  escapeHtml,
  expiryFrom,
  headerSafeName,
  isActiveInvitation,
  isInvitableRole,
  normalizeEmailKey,
  pickActiveInvitation,
  readableSendError,
} from "../invitations/rules";
import { MailNotConfiguredError, mailCredentials } from "../invitations/mailer";
import { awaitsRole } from "../triggers/invitationSignup";

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
  test("message par défaut avec le nom du groupe", () => {
    assert.equal(
      defaultInvitationMessage("Les Kassbi"),
      "Je t'invite dans mon groupe familial « Les Kassbi » sur Kass'Dalle, pour suivre et " +
        "noter tes repas préférés. Tu auras aussi accès aux recettes que le groupe partage.",
    );
  });

  test("vide → message par défaut ; borné à 500 caractères", () => {
    assert.equal(cleanMessage("   ", "G"), defaultInvitationMessage("G"));
    assert.equal(cleanMessage("x".repeat(800), "G").length, INVITATION_MESSAGE_MAX);
    assert.equal(cleanMessage("a\r\nb", "G"), "a\nb");
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
});
