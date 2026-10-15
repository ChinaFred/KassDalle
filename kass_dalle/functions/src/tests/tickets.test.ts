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
  isTrustedPrAuthor,
  globalQuotaDocId,
  memberQuotaDocId,
  neutralizeIssueReferences,
  neutralizeMentions,
  nextTicketStatus,
  parisDay,
  quotaMessage,
  quotaRefusal,
  readTicketInput,
  readTicketLimits,
  replyFromComment,
  routeTemplateOrNull,
  screenshotBytesMatch,
  screenshotPaths,
  statusFromIssue,
  verifyGithubSignature,
  type IssueState,
  type TicketStatus,
} from "../tickets/rules";
import { classifyGithubFailure, labelNames, readRemoteIssue } from "../tickets/github";
import { SignatureRejectionLog, updatesFromEvent } from "../tickets/webhook";
import { GITHUB_TICKETS_MAINTAINER_ID } from "../config";

const REPO = "ChinaFred/KassDalle";
/** Identifiant numérique du compte ChinaFred. */
const MAINTAINER_ID = 16348852;
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

  test("neutralise les renvois #N et owner/repo#N, titre et description", () => {
    const withRefs = buildIssueBody({
      ticketId: "r",
      type: "bug",
      description: "Comme #12 et autre/depot#3, voir aussi (#4).",
      screen: "/planning",
      app_version: "1",
      platform: "web",
    });
    assert.doesNotMatch(withRefs, /#\d/);
    assert.ok(withRefs.includes(`#${ZWSP}12`));
    assert.ok(withRefs.includes(`autre/depot#${ZWSP}3`));
    assert.ok(withRefs.includes("### Description"));
    assert.equal(buildIssueTitle("Doublon de #7"), `Doublon de #${ZWSP}7`);
    assert.equal(neutralizeIssueReferences("# titre et C#"), "# titre et C#");
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
  test("le mainteneur est comparé par son identifiant numérique", () => {
    assert.equal(GITHUB_TICKETS_MAINTAINER_ID, MAINTAINER_ID);
  });

  test("garde un commentaire du mainteneur qui commence par « Réponse : »", () => {
    assert.equal(
      replyFromComment(
        { authorId: MAINTAINER_ID, body: "Réponse : oui, c'est prévu." },
        MAINTAINER_ID,
      ),
      "oui, c'est prévu.",
    );
  });

  test("tolère l'espace insécable, l'absence d'espace et le é décomposé", () => {
    assert.equal(
      replyFromComment(
        { authorId: MAINTAINER_ID, body: `Réponse${String.fromCharCode(0xa0)}: A` },
        MAINTAINER_ID,
      ),
      "A",
    );
    assert.equal(
      replyFromComment({ authorId: MAINTAINER_ID, body: "Réponse:B" }, MAINTAINER_ID),
      "B",
    );
    assert.equal(
      replyFromComment(
        { authorId: MAINTAINER_ID, body: `Re${String.fromCharCode(0x301)}ponse : C` },
        MAINTAINER_ID,
      ),
      "C",
    );
  });

  test("ignore un autre auteur, un autre préfixe et une réponse vide", () => {
    assert.equal(replyFromComment({ authorId: 1, body: "Réponse : non" }, MAINTAINER_ID), null);
    // Le login du mainteneur sous un autre identifiant (login repris) : ignoré.
    assert.equal(
      replyFromComment({ authorId: MAINTAINER_ID + 1, body: "Réponse : non" }, MAINTAINER_ID),
      null,
    );
    assert.equal(
      replyFromComment({ authorId: MAINTAINER_ID, body: "Analyse : à faire" }, MAINTAINER_ID),
      null,
    );
    assert.equal(
      replyFromComment({ authorId: MAINTAINER_ID, body: "Merci. Réponse : x" }, MAINTAINER_ID),
      null,
    );
    assert.equal(
      replyFromComment({ authorId: MAINTAINER_ID, body: "Réponse :  " }, MAINTAINER_ID),
      null,
    );
    assert.equal(replyFromComment({ authorId: null, body: "Réponse : x" }, MAINTAINER_ID), null);
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
      {
        state: "closed",
        stateReason: "completed",
        labels: ["a"],
        isPullRequest: false,
        updatedAt: null,
      },
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
      comment: {
        user: { login: "ChinaFred", id: MAINTAINER_ID },
        body: "Réponse : c'est en place.",
      },
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
        comment: { user: { login: "intrus", id: 99 }, body: "Réponse : faux" },
      }),
      [],
    );
    // Login du mainteneur sans son identifiant : ignoré.
    assert.deepEqual(
      updatesFromEvent("issue_comment", {
        action: "created",
        repository,
        issue: { number: 9 },
        comment: { user: { login: "ChinaFred", id: 99 }, body: "Réponse : faux" },
      }),
      [],
    );
    // Commentaire sur une PR : ignoré.
    assert.deepEqual(
      updatesFromEvent("issue_comment", {
        action: "created",
        repository,
        issue: { number: 9, pull_request: {} },
        comment: { user: { login: "ChinaFred", id: MAINTAINER_ID }, body: "Réponse : x" },
      }),
      [],
    );
  });

  test("pull_request ouverte qui ferme des Issues : en cours", () => {
    const updates = updatesFromEvent("pull_request", {
      action: "opened",
      repository,
      pull_request: {
        state: "open",
        body: "Closes #5\nFixes #6",
        user: { id: MAINTAINER_ID },
        author_association: "OWNER",
      },
    });
    assert.deepEqual(
      updates.map((u) => [u.issueNumber, u.update.openClosingPr]),
      [
        [5, true],
        [6, true],
      ],
    );
  });

  test("pull_request d'un autre compte (fork) : aucune mise à jour", () => {
    assert.deepEqual(
      updatesFromEvent("pull_request", {
        action: "opened",
        repository,
        pull_request: {
          state: "open",
          body: "Closes #5",
          user: { login: "ChinaFred", id: 4242 },
          author_association: "CONTRIBUTOR",
        },
      }),
      [],
    );
    assert.deepEqual(
      updatesFromEvent("pull_request", {
        action: "opened",
        repository,
        pull_request: { state: "open", body: "Closes #5", user: { id: 4242 } },
      }),
      [],
    );
    // Un collaborateur du dépôt compte.
    assert.equal(
      updatesFromEvent("pull_request", {
        action: "opened",
        repository,
        pull_request: {
          state: "open",
          body: "Closes #5",
          user: { id: 4242 },
          author_association: "COLLABORATOR",
        },
      }).length,
      1,
    );
  });

  test("isTrustedPrAuthor : mainteneur ou OWNER, MEMBER, COLLABORATOR", () => {
    assert.equal(isTrustedPrAuthor({ id: MAINTAINER_ID, association: null }, MAINTAINER_ID), true);
    for (const a of ["OWNER", "MEMBER", "COLLABORATOR"]) {
      assert.equal(isTrustedPrAuthor({ id: 1, association: a }, MAINTAINER_ID), true);
    }
    for (const a of ["CONTRIBUTOR", "FIRST_TIME_CONTRIBUTOR", "FIRST_TIMER", "NONE", null]) {
      assert.equal(isTrustedPrAuthor({ id: 1, association: a }, MAINTAINER_ID), false);
    }
    assert.equal(isTrustedPrAuthor({ id: null, association: undefined }, MAINTAINER_ID), false);
  });

  test("SignatureRejectionLog : un relevé par intervalle, avec le compte", () => {
    const log = new SignatureRejectionLog(60_000);
    assert.equal(log.record(0), 1);
    assert.equal(log.record(10_000), null);
    assert.equal(log.record(59_999), null);
    assert.equal(log.record(60_000), 3);
    assert.equal(log.record(60_001), null);
    assert.equal(log.record(200_000), 2);
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

// ── Capture ─────────────────────────────────────────────────────────────────

describe("screenshotBytesMatch", () => {
  const png = Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  const jpeg = Uint8Array.from([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46]);

  test("accepte un PNG et un JPEG annoncés comme tels", () => {
    assert.equal(screenshotBytesMatch(png, "image/png"), true);
    assert.equal(screenshotBytesMatch(jpeg, "image/jpeg"), true);
  });

  test("refuse un format croisé, un faux contenu, un objet trop court", () => {
    assert.equal(screenshotBytesMatch(png, "image/jpeg"), false);
    assert.equal(screenshotBytesMatch(jpeg, "image/png"), false);
    assert.equal(screenshotBytesMatch(Buffer.from("<svg onload=x>"), "image/png"), false);
    assert.equal(screenshotBytesMatch(Uint8Array.from([0xff, 0xd8]), "image/jpeg"), false);
    assert.equal(screenshotBytesMatch(png, "image/gif"), false);
  });
});
