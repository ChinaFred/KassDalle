/**
 * Tickets : logique pure.
 *
 * - corps de l'Issue publiée sur un dépôt public : aucune donnée privée,
 *   écran sans identifiant, mentions `@` neutralisées ;
 * - correspondance état GitHub → statut, non-recul, réouverture ;
 * - filtre de la réponse de l'administrateur (`reply_text`) ;
 * - signature HMAC du webhook ;
 * - jour du plafond (Europe/Paris) et lecture des plafonds ;
 * - événements du webhook → mises à jour.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";

import {
  DEFAULT_TICKET_LIMITS,
  TicketInputError,
  buildIssueBody,
  buildIssueTitle,
  closingIssueNumbers,
  creationLabels,
  globalQuotaDocId,
  memberQuotaDocId,
  neutralizeMentions,
  nextTicketStatus,
  parisDay,
  quotaMessage,
  quotaRefusal,
  readTicketInput,
  readTicketLimits,
  replyFromComment,
  routeTemplateOrNull,
  screenshotPaths,
  statusFromIssue,
  verifyGithubSignature,
  type IssueState,
  type TicketStatus,
} from "../tickets/rules";
import { classifyGithubFailure, labelNames, readRemoteIssue } from "../tickets/github";
import { updatesFromEvent } from "../tickets/webhook";

const REPO = "ChinaFred/KassDalle";
/** Espace sans chasse, écrite par son code pour rester visible dans le source. */
const ZWSP = String.fromCharCode(0x200b);

function validInput(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    type: "bug",
    title: "La liste de courses se vide",
    description: "Ce que vous faisiez : …\nCe qui s'est passé : …",
    screen: "/recipes/:recipeId",
    app_version: "0.23.53+400",
    platform: "android",
    ...overrides,
  };
}

// ── Entrées ─────────────────────────────────────────────────────────────────

describe("readTicketInput", () => {
  test("accepte une entrée valide et nettoie le titre", () => {
    const input = readTicketInput(validInput({ title: "  Titre\nsur  deux lignes " }));
    assert.equal(input.title, "Titre sur deux lignes");
    assert.equal(input.screen, "/recipes/:recipeId");
    assert.equal(input.screenReplaced, false);
  });

  test("refuse un type inconnu, un titre trop court ou trop long", () => {
    assert.throws(() => readTicketInput(validInput({ type: "spam" })), TicketInputError);
    assert.throws(() => readTicketInput(validInput({ title: "abcd" })), /au moins 5/);
    assert.throws(() => readTicketInput(validInput({ title: "x".repeat(101) })), /100/);
  });

  test("refuse une description vide ou de plus de 2 000 caractères", () => {
    assert.throws(() => readTicketInput(validInput({ description: "   " })), TicketInputError);
    assert.throws(
      () => readTicketInput(validInput({ description: "x".repeat(2001) })),
      TicketInputError,
    );
    assert.equal(
      readTicketInput(validInput({ description: "x".repeat(2000) })).description.length,
      2000,
    );
  });

  test("retire les caractères de contrôle de la description, garde les retours à la ligne", () => {
    const input = readTicketInput(validInput({ description: "a\u0000b\r\nc\td" }));
    assert.equal(input.description, "ab\nc\td");
  });

  test("refuse une plateforme ou une version invalide", () => {
    assert.throws(() => readTicketInput(validInput({ platform: "linux" })), TicketInputError);
    assert.throws(
      () => readTicketInput(validInput({ app_version: "1.0 <script>" })),
      TicketInputError,
    );
  });

  test("remplace un écran qui n'est pas un modèle de route par « inconnu »", () => {
    const input = readTicketInput(validInput({ screen: "/recipes/aB3xYz9QpL" }));
    assert.equal(input.screen, "inconnu");
    assert.equal(input.screenReplaced, true);
  });
});

describe("routeTemplateOrNull", () => {
  test("accepte les modèles de route, « autre » et « inconnu »", () => {
    for (const s of [
      "/",
      "/recipes/:recipeId/edit",
      "/book-pages/:pageId",
      "/admin/ai-routing",
      "/planning/staples",
      "autre",
      "inconnu",
    ]) {
      assert.equal(routeTemplateOrNull(s), s);
    }
  });

  test("refuse un identifiant, une requête, un fragment, une adresse complète", () => {
    for (const s of [
      "/recipes/aB3xYz9QpL",
      "/recipes/123",
      "/search?q=gratin",
      "/planning#lundi",
      "https://kassdale-6d948.web.app/recipes/x",
      "recipes",
      "/recipes//edit",
    ]) {
      assert.equal(routeTemplateOrNull(s), null, s);
    }
  });
});

// ── Corps de l'Issue ────────────────────────────────────────────────────────

describe("buildIssueBody", () => {
  const body = buildIssueBody({
    ticketId: "tK7abc",
    type: "feature",
    description: "Prévenir @maman et @ChinaFred/famille, écrire à jean@exemple.fr",
    screen: "/planning",
    app_version: "0.23.53",
    platform: "web",
  });

  test("porte type, écran, version, plateforme et référence opaque", () => {
    assert.match(body, /\*\*Type :\*\* Nouvelle fonctionnalité/);
    assert.match(body, /\*\*Écran :\*\* `\/planning`/);
    assert.match(body, /\*\*Version :\*\* 0\.23\.53/);
    assert.match(body, /\*\*Plateforme :\*\* Web/);
    assert.match(body, /\*\*Référence :\*\* `tK7abc`/);
    assert.match(body, /Capture éventuelle disponible dans Admin › Tickets/);
  });

  test("ne contient aucune mention active", () => {
    assert.doesNotMatch(body, /@[A-Za-z0-9-]/);
    assert.ok(body.includes(`@${ZWSP}maman`));
  });

  test("ne contient ni uid, ni nom, ni chemin de capture", () => {
    assert.doesNotMatch(body, /author|uid|screenshot|tickets\//i);
  });

  test("écrit « Autre écran » et « Non précisé » en clair", () => {
    const other = buildIssueBody({
      ticketId: "x",
      type: "bug",
      description: "d",
      screen: "autre",
      app_version: "1",
      platform: "ios",
    });
    assert.match(other, /\*\*Écran :\*\* Autre écran/);
    assert.match(other, /\*\*Plateforme :\*\* iOS/);
  });

  test("le titre perd ses mentions et ses retours à la ligne", () => {
    assert.equal(buildIssueTitle("Aide @ChinaFred\nsvp"), `Aide @${ZWSP}ChinaFred svp`);
  });

  test("neutralizeMentions laisse un @ isolé intact", () => {
    assert.equal(neutralizeMentions("a @ b"), "a @ b");
  });

  test("étiquettes de création", () => {
    assert.deepEqual(creationLabels("bug"), ["source:app", "type:bug", "statut:à-analyser"]);
  });
});

// ── Statuts ─────────────────────────────────────────────────────────────────

function issue(over: Partial<IssueState>): IssueState {
  return { state: "open", stateReason: null, labels: [], hasOpenClosingPr: false, ...over };
}

describe("statusFromIssue", () => {
  test("Issue ouverte : étiquettes et PR", () => {
    assert.equal(statusFromIssue(issue({ labels: ["source:app"] }), "bug"), "received");
    assert.equal(statusFromIssue(issue({ labels: ["statut:analysé"] }), "bug"), "analyzed");
    assert.equal(
      statusFromIssue(issue({ labels: ["statut:analysé", "validé"] }), "bug"),
      "validated",
    );
    assert.equal(statusFromIssue(issue({ hasOpenClosingPr: true }), "bug"), "in_progress");
  });

  test("Issue fermée : livré, répondu, refusé", () => {
    const completed = issue({ state: "closed", stateReason: "completed" });
    assert.equal(statusFromIssue(completed, "bug"), "delivered");
    assert.equal(statusFromIssue(completed, "question"), "answered");
    assert.equal(
      statusFromIssue(issue({ state: "closed", stateReason: "not_planned" }), "feature"),
      "refused",
    );
    assert.equal(
      statusFromIssue(issue({ state: "closed", stateReason: "duplicate" }), "question"),
      "refused",
    );
  });
});

describe("nextTicketStatus", () => {
  const cases: Array<[TicketStatus, TicketStatus, TicketStatus]> = [
    ["sending", "received", "received"],
    ["received", "analyzed", "analyzed"],
    ["validated", "analyzed", "validated"], // étiquette retirée : pas de recul
    ["in_progress", "validated", "in_progress"], // webhook d'Issue sans PR connue
    ["in_progress", "received", "in_progress"],
    ["analyzed", "delivered", "delivered"],
    ["received", "refused", "refused"],
    ["delivered", "validated", "validated"], // réouverture
    ["answered", "received", "received"], // réouverture
    ["delivered", "refused", "refused"], // refermée autrement
    ["refused", "refused", "refused"],
  ];
  for (const [current, github, expected] of cases) {
    test(`${current} + ${github} → ${expected}`, () => {
      assert.equal(nextTicketStatus(current, github), expected);
    });
  }
});

describe("closingIssueNumbers", () => {
  test("lit les mots-clés de fermeture de GitHub", () => {
    assert.deepEqual(closingIssueNumbers("Closes #12", REPO), [12]);
    assert.deepEqual(closingIssueNumbers("fixes: #3 et resolved #4\nCLOSE #3", REPO), [3, 4]);
    assert.deepEqual(closingIssueNumbers("Fixes ChinaFred/KassDalle#7", REPO), [7]);
  });

  test("ignore une simple mention et un autre dépôt", () => {
    assert.deepEqual(closingIssueNumbers("Voir #12", REPO), []);
    assert.deepEqual(closingIssueNumbers("Closes autre/depot#12", REPO), []);
    assert.deepEqual(closingIssueNumbers(null, REPO), []);
  });
});

// ── Réponse ─────────────────────────────────────────────────────────────────

describe("replyFromComment", () => {
  test("garde un commentaire de ChinaFred qui commence par « Réponse : »", () => {
    assert.equal(
      replyFromComment(
        { authorLogin: "ChinaFred", body: "Réponse : oui, c'est prévu." },
        "ChinaFred",
      ),
      "oui, c'est prévu.",
    );
  });

  test("tolère l'espace insécable, l'absence d'espace et le é décomposé", () => {
    assert.equal(
      replyFromComment(
        { authorLogin: "ChinaFred", body: `Réponse${String.fromCharCode(0xa0)}: A` },
        "ChinaFred",
      ),
      "A",
    );
    assert.equal(
      replyFromComment({ authorLogin: "ChinaFred", body: "Réponse:B" }, "ChinaFred"),
      "B",
    );
    assert.equal(
      replyFromComment(
        { authorLogin: "ChinaFred", body: `Re${String.fromCharCode(0x301)}ponse : C` },
        "ChinaFred",
      ),
      "C",
    );
  });

  test("ignore un autre auteur, un autre préfixe et une réponse vide", () => {
    assert.equal(
      replyFromComment({ authorLogin: "quelquun", body: "Réponse : non" }, "ChinaFred"),
      null,
    );
    assert.equal(
      replyFromComment({ authorLogin: "chinafred", body: "Réponse : non" }, "ChinaFred"),
      null,
    );
    assert.equal(
      replyFromComment({ authorLogin: "ChinaFred", body: "Analyse : à faire" }, "ChinaFred"),
      null,
    );
    assert.equal(
      replyFromComment({ authorLogin: "ChinaFred", body: "Merci. Réponse : x" }, "ChinaFred"),
      null,
    );
    assert.equal(
      replyFromComment({ authorLogin: "ChinaFred", body: "Réponse :  " }, "ChinaFred"),
      null,
    );
    assert.equal(replyFromComment({ authorLogin: null, body: "Réponse : x" }, "ChinaFred"), null);
  });
});

// ── Signature ───────────────────────────────────────────────────────────────

describe("verifyGithubSignature", () => {
  const secret = "s3cret";
  const body = Buffer.from('{"action":"labeled"}');
  const sign = (b: Buffer, s: string) =>
    `sha256=${createHmac("sha256", s).update(b).digest("hex")}`;

  test("accepte la bonne signature", () => {
    assert.equal(verifyGithubSignature(body, sign(body, secret), secret), true);
  });

  test("refuse un autre secret, un autre corps, un en-tête absent ou mal formé", () => {
    assert.equal(verifyGithubSignature(body, sign(body, "autre"), secret), false);
    assert.equal(
      verifyGithubSignature(Buffer.from('{"action":"closed"}'), sign(body, secret), secret),
      false,
    );
    assert.equal(verifyGithubSignature(body, undefined, secret), false);
    assert.equal(verifyGithubSignature(body, "sha1=abc", secret), false);
    assert.equal(verifyGithubSignature(body, "sha256=abcd", secret), false);
  });

  test("refuse tout quand le secret est vide", () => {
    assert.equal(verifyGithubSignature(body, sign(body, ""), ""), false);
  });
});

// ── Plafonds ────────────────────────────────────────────────────────────────

describe("parisDay", () => {
  test("change de jour à minuit heure de Paris, été comme hiver", () => {
    // Été (UTC+2) : 21 h 59 UTC = 23 h 59 à Paris ; 22 h 00 UTC = minuit.
    assert.equal(parisDay(new Date("2026-07-14T21:59:00Z")), "20260714");
    assert.equal(parisDay(new Date("2026-07-14T22:00:00Z")), "20260715");
    // Hiver (UTC+1).
    assert.equal(parisDay(new Date("2026-12-31T22:59:00Z")), "20261231");
    assert.equal(parisDay(new Date("2026-12-31T23:00:00Z")), "20270101");
  });

  test("jours de changement d'heure", () => {
    assert.equal(parisDay(new Date("2026-03-29T01:30:00Z")), "20260329");
    assert.equal(parisDay(new Date("2026-10-25T22:30:00Z")), "20261025");
    assert.equal(parisDay(new Date("2026-10-25T23:00:00Z")), "20261026");
  });

  test("identifiants des compteurs", () => {
    assert.equal(memberQuotaDocId("uid1", "20261013"), "uid1_20261013");
    assert.equal(globalQuotaDocId("20261013"), "_global_20261013");
  });
});

describe("readTicketLimits et quotaRefusal", () => {
  test("document absent : réglage par défaut", () => {
    assert.deepEqual(readTicketLimits(undefined), DEFAULT_TICKET_LIMITS);
    assert.deepEqual(readTicketLimits({}), DEFAULT_TICKET_LIMITS);
  });

  test("valeurs réglées, ou refus si illisibles", () => {
    assert.deepEqual(readTicketLimits({ per_member_per_day: 3, global_per_day: 10 }), {
      per_member_per_day: 3,
      global_per_day: 10,
    });
    assert.equal(readTicketLimits({ per_member_per_day: "5" }), null);
    assert.equal(readTicketLimits({ global_per_day: 0 }), null);
    assert.equal(readTicketLimits({ per_member_per_day: 2.5 }), null);
  });

  test("plafond membre, plafond famille, administrateur exempté", () => {
    const limits = { per_member_per_day: 5, global_per_day: 30 };
    assert.equal(quotaRefusal({ isAdmin: false, memberCount: 4, globalCount: 29, limits }), null);
    assert.deepEqual(quotaRefusal({ isAdmin: false, memberCount: 5, globalCount: 0, limits }), {
      reason: "member_daily_limit",
      limit: 5,
    });
    assert.deepEqual(quotaRefusal({ isAdmin: false, memberCount: 0, globalCount: 30, limits }), {
      reason: "global_daily_limit",
      limit: 30,
    });
    assert.equal(quotaRefusal({ isAdmin: true, memberCount: 99, globalCount: 99, limits }), null);
  });

  test("messages", () => {
    assert.equal(
      quotaMessage("member_daily_limit", 5),
      "Vous avez envoyé 5 tickets aujourd'hui, réessayez demain.",
    );
    assert.match(quotaMessage("global_daily_limit", 30), /par la famille/);
  });

  test("chemins de capture admis", () => {
    assert.deepEqual(screenshotPaths("u", "t"), [
      "tickets/u/t/screenshot.png",
      "tickets/u/t/screenshot.jpg",
    ]);
  });
});

// ── Client GitHub (parties pures) ───────────────────────────────────────────

describe("client GitHub", () => {
  test("classe les échecs", () => {
    assert.equal(classifyGithubFailure(401, null, false), "token");
    assert.equal(classifyGithubFailure(403, "0", false), "rate_limit");
    assert.equal(classifyGithubFailure(403, "12", false), "token");
    assert.equal(classifyGithubFailure(429, null, false), "rate_limit");
    assert.equal(classifyGithubFailure(404, null, true), "token");
    assert.equal(classifyGithubFailure(404, null, false), "not_found");
    assert.equal(classifyGithubFailure(502, null, false), "other");
  });

  test("lit une Issue", () => {
    assert.deepEqual(labelNames([{ name: "validé" }, "x", null, { id: 1 }]), ["validé", "x"]);
    assert.deepEqual(
      readRemoteIssue({ state: "closed", state_reason: "completed", labels: [{ name: "a" }] }),
      { state: "closed", stateReason: "completed", labels: ["a"], isPullRequest: false },
    );
  });
});

// ── Webhook ─────────────────────────────────────────────────────────────────

describe("updatesFromEvent", () => {
  const repository = { full_name: REPO };

  test("issues : statut dérivé des étiquettes et de l'état", () => {
    const [u] = updatesFromEvent("issues", {
      action: "labeled",
      repository,
      issue: { number: 4, state: "open", labels: [{ name: "validé" }] },
    });
    assert.equal(u.issueNumber, 4);
    assert.equal(u.update.statusFor?.("bug"), "validated");

    const [closed] = updatesFromEvent("issues", {
      action: "closed",
      repository,
      issue: { number: 4, state: "closed", state_reason: "completed", labels: [] },
    });
    assert.equal(closed.update.statusFor?.("question"), "answered");
  });

  test("issue_comment : seule la réponse de ChinaFred passe", () => {
    const ok = updatesFromEvent("issue_comment", {
      action: "created",
      repository,
      issue: { number: 9 },
      comment: { user: { login: "ChinaFred" }, body: "Réponse : c'est en place." },
    });
    assert.deepEqual(
      ok.map((u) => [u.issueNumber, u.update.reply]),
      [[9, "c'est en place."]],
    );
    assert.deepEqual(
      updatesFromEvent("issue_comment", {
        action: "created",
        repository,
        issue: { number: 9 },
        comment: { user: { login: "intrus" }, body: "Réponse : faux" },
      }),
      [],
    );
    // Commentaire sur une PR : ignoré.
    assert.deepEqual(
      updatesFromEvent("issue_comment", {
        action: "created",
        repository,
        issue: { number: 9, pull_request: {} },
        comment: { user: { login: "ChinaFred" }, body: "Réponse : x" },
      }),
      [],
    );
  });

  test("pull_request ouverte qui ferme des Issues : en cours", () => {
    const updates = updatesFromEvent("pull_request", {
      action: "opened",
      repository,
      pull_request: { state: "open", body: "Closes #5\nFixes #6" },
    });
    assert.deepEqual(
      updates.map((u) => [u.issueNumber, u.update.openClosingPr]),
      [
        [5, true],
        [6, true],
      ],
    );
  });

  test("autre dépôt, autre événement, action non suivie : rien", () => {
    assert.deepEqual(
      updatesFromEvent("issues", {
        action: "labeled",
        repository: { full_name: "autre/depot" },
        issue: { number: 1, state: "open", labels: [] },
      }),
      [],
    );
    assert.deepEqual(updatesFromEvent("star", { action: "created", repository }), []);
    assert.deepEqual(
      updatesFromEvent("issues", {
        action: "assigned",
        repository,
        issue: { number: 1, state: "open", labels: [] },
      }),
      [],
    );
  });
});
