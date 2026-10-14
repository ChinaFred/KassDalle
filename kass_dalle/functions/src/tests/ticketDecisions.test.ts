/**
 * Tickets, lot A du ticket #73 : logique pure.
 *
 * - détection d'une analyse du mainteneur (auteur, préfixe), ordre, plafond
 *   de dix, troncature à la dernière ligne vide ;
 * - lecture du motif de refus et reconnaissance d'un motif déjà publié ;
 * - conditions de « Valider » et « Refuser », message d'un échec GitHub ;
 * - événement du webhook qui demande de relire les analyses ;
 * - lecture des arguments des callables.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { HttpsError } from "firebase-functions/v2/https";

import {
  ANALYSIS_MAX_CHARS,
  ANALYSIS_MAX_COUNT,
  REFUSAL_PARTIAL_REASON,
  TicketInputError,
  analysesFromComments,
  decisionGithubFailure,
  isAnalysisComment,
  readRefusalReason,
  refusalCommentBody,
  refusePrecondition,
  replyFromComment,
  sameReply,
  DEFAULT_LAUNCHES_PER_DAY,
  MAX_LAUNCHES_PER_DAY,
  launchRunState,
  shouldWriteValidated,
  ticketDecisions,
  truncateAnalysis,
  validatePrecondition,
  type AnalysisSourceComment,
  type TicketStatus,
  type TicketType,
} from "../tickets/rules";
import { readRemoteComment } from "../tickets/github";
import { analysisRefreshFromEvent, updatesFromEvent } from "../tickets/webhook";
import { readRefusalArg, readTicketIdArg } from "../callable/ticketsCallable";
import { GITHUB_TICKETS_MAINTAINER_ID } from "../config";

const MAINTAINER_ID = GITHUB_TICKETS_MAINTAINER_ID;
const REPO = "ChinaFred/KassDalle";
const ZWSP = String.fromCharCode(0x200b);

function comment(overrides: Partial<AnalysisSourceComment> = {}): AnalysisSourceComment {
  return {
    id: 1,
    authorId: MAINTAINER_ID,
    body: "## Analyse\n\nCause probable : …",
    createdAt: "2026-10-10T08:00:00Z",
    updatedAt: "2026-10-10T08:00:00Z",
    ...overrides,
  };
}

// ── Analyses ────────────────────────────────────────────────────────────────

describe("isAnalysisComment", () => {
  test("commentaire du mainteneur qui commence par « ## Analyse »", () => {
    assert.equal(isAnalysisComment(comment(), MAINTAINER_ID), true);
    assert.equal(
      isAnalysisComment(comment({ body: "## Analyse — compléments\n\nSuite." }), MAINTAINER_ID),
      true,
    );
    // Espaces et lignes vides de tête tolérés, fins de ligne Windows aussi.
    assert.equal(
      isAnalysisComment(comment({ body: "\r\n  ## Analyse\r\nTexte" }), MAINTAINER_ID),
      true,
    );
  });

  test("autre auteur, auteur inconnu ou autre titre : ignoré", () => {
    assert.equal(isAnalysisComment(comment({ authorId: 99 }), MAINTAINER_ID), false);
    assert.equal(isAnalysisComment(comment({ authorId: null }), MAINTAINER_ID), false);
    assert.equal(isAnalysisComment(comment({ body: "Réponse : non" }), MAINTAINER_ID), false);
    assert.equal(isAnalysisComment(comment({ body: "# Analyse" }), MAINTAINER_ID), false);
    assert.equal(isAnalysisComment(comment({ body: "Voir ## Analyse" }), MAINTAINER_ID), false);
    assert.equal(isAnalysisComment(comment({ body: null }), MAINTAINER_ID), false);
  });
});

describe("truncateAnalysis", () => {
  test("un texte sous la limite reste entier", () => {
    assert.deepEqual(truncateAnalysis("court"), { body: "court", truncated: false });
    const exact = "x".repeat(ANALYSIS_MAX_CHARS);
    assert.deepEqual(truncateAnalysis(exact), { body: exact, truncated: false });
  });

  test("coupe à la dernière ligne vide avant la limite", () => {
    const text = "Premier paragraphe.\n\nDeuxième paragraphe.\n\nTroisième, trop long.";
    const limit = text.indexOf("Troisième") + 3;
    assert.deepEqual(truncateAnalysis(text, limit), {
      body: "Premier paragraphe.\n\nDeuxième paragraphe.",
      truncated: true,
    });
  });

  test("une ligne faite d'espaces compte comme ligne vide", () => {
    const text = "Avant.\n   \nAprès, coupé.";
    assert.deepEqual(truncateAnalysis(text, text.length - 3), { body: "Avant.", truncated: true });
  });

  test("sans ligne vide avant la limite : coupe à la limite", () => {
    const text = "a".repeat(30);
    assert.deepEqual(truncateAnalysis(text, 10), { body: "a".repeat(10), truncated: true });
  });

  test("ne sépare pas une paire de substitution", () => {
    const text = "abc" + "😀" + "def";
    // La limite tombe entre les deux moitiés de l'émoji.
    assert.deepEqual(truncateAnalysis(text, 4), { body: "abc", truncated: true });
  });

  test("plafond réel : 20 000 caractères", () => {
    const text = "Intro.\n\n" + "y".repeat(ANALYSIS_MAX_CHARS + 50);
    const out = truncateAnalysis(text);
    assert.equal(out.truncated, true);
    assert.equal(out.body, "Intro.");
  });
});

describe("analysesFromComments", () => {
  test("garde les analyses du mainteneur, dans l'ordre chronologique", () => {
    const out = analysesFromComments(
      [
        comment({
          id: 3,
          body: "## Analyse — compléments\n\nB",
          createdAt: "2026-10-12T00:00:00Z",
        }),
        comment({ id: 2, authorId: 99, body: "## Analyse\n\nIntrus" }),
        comment({ id: 4, body: "Réponse : merci" }),
        comment({ id: 1, body: "## Analyse\n\nA", createdAt: "2026-10-11T00:00:00Z" }),
      ],
      MAINTAINER_ID,
    );
    assert.deepEqual(
      out.map((a) => a.comment_id),
      [1, 3],
    );
    assert.equal(out[0].body, "## Analyse\n\nA");
    assert.equal(out[0].created_at, "2026-10-11T00:00:00Z");
    assert.equal(out[0].truncated, false);
  });

  test("au plus dix analyses : les plus récentes", () => {
    const many = Array.from({ length: 13 }, (_, i) =>
      comment({
        id: i + 1,
        body: `## Analyse ${i + 1}`,
        createdAt: `2026-10-${String(i + 1).padStart(2, "0")}T00:00:00Z`,
      }),
    );
    const out = analysesFromComments(many, MAINTAINER_ID);
    assert.equal(out.length, ANALYSIS_MAX_COUNT);
    assert.deepEqual(
      out.map((a) => a.comment_id),
      [4, 5, 6, 7, 8, 9, 10, 11, 12, 13],
    );
  });

  test("tronque chaque analyse et le signale", () => {
    const long = "## Analyse\n\nIntro.\n\n" + "z".repeat(ANALYSIS_MAX_CHARS);
    const [a] = analysesFromComments([comment({ body: long })], MAINTAINER_ID);
    assert.equal(a.truncated, true);
    assert.equal(a.body, "## Analyse\n\nIntro.");
  });

  test("aucune analyse : liste vide", () => {
    assert.deepEqual(analysesFromComments([], MAINTAINER_ID), []);
    assert.deepEqual(
      analysesFromComments([comment({ authorId: 1, body: "## Analyse" })], MAINTAINER_ID),
      [],
    );
  });

  test("lit un commentaire de l'API GitHub", () => {
    assert.deepEqual(
      readRemoteComment({
        id: 77,
        user: { id: MAINTAINER_ID, login: "ChinaFred" },
        body: "## Analyse",
        created_at: "2026-10-10T08:00:00Z",
        updated_at: "2026-10-10T09:00:00Z",
      }),
      {
        id: 77,
        authorId: MAINTAINER_ID,
        body: "## Analyse",
        createdAt: "2026-10-10T08:00:00Z",
        updatedAt: "2026-10-10T09:00:00Z",
      },
    );
    assert.deepEqual(readRemoteComment({}), {
      id: null,
      authorId: null,
      body: null,
      createdAt: null,
      updatedAt: null,
    });
  });
});

// ── Motif de refus ──────────────────────────────────────────────────────────

describe("readRefusalReason", () => {
  test("nettoie, garde les retours à la ligne, neutralise mentions et renvois", () => {
    assert.equal(
      readRefusalReason("  Hors du périmètre.\r\nVoir @ChinaFred et #12.\u0007  "),
      `Hors du périmètre.\nVoir @${ZWSP}ChinaFred et #${ZWSP}12.`,
    );
  });

  test("refuse un motif absent, trop court ou trop long", () => {
    assert.throws(() => readRefusalReason(undefined), TicketInputError);
    assert.throws(() => readRefusalReason("  abcd  "), /au moins 5/);
    assert.throws(() => readRefusalReason("x".repeat(2001)), /2 000/);
    assert.equal(readRefusalReason("x".repeat(2000)).length, 2000);
    assert.equal(readRefusalReason("abcde"), "abcde");
  });

  test("le champ en erreur est `reason`", () => {
    try {
      readRefusalReason("abc");
      assert.fail("aurait dû lever");
    } catch (err) {
      assert.ok(err instanceof TicketInputError);
      assert.equal(err.field, "reason");
    }
  });

  test("le commentaire publié est reconnu comme réponse, motif identique", () => {
    const reason = readRefusalReason("Ce n'est pas prévu. Voir #4.");
    const body = refusalCommentBody(reason);
    assert.equal(body, `Réponse : ${reason}`);
    const reply = replyFromComment({ authorId: MAINTAINER_ID, body }, MAINTAINER_ID);
    assert.equal(sameReply(reply, reason), true);
  });

  test("sameReply : NFC, espaces de bord, fins de ligne ; absent ou autre texte : faux", () => {
    assert.equal(sameReply("Refusé\r\nfin ", "Refusé\nfin"), true);
    assert.equal(sameReply("Réponse", "Réponse"), true);
    assert.equal(sameReply(undefined, "motif"), false);
    assert.equal(sameReply(null, "motif"), false);
    assert.equal(sameReply("autre motif", "motif"), false);
  });
});

// ── Conditions des décisions ────────────────────────────────────────────────

describe("validatePrecondition", () => {
  const base = { status: "analyzed" as TicketStatus, type: "bug" as const, hasIssue: true };

  test("analysé, hors Question, avec Issue : permis", () => {
    assert.deepEqual(validatePrecondition(base), { kind: "ok" });
    assert.deepEqual(validatePrecondition({ ...base, type: "feature" }), { kind: "ok" });
  });

  test("déjà validé : succès sans rien changer", () => {
    assert.deepEqual(validatePrecondition({ ...base, status: "validated" }), { kind: "already" });
  });

  test("Reçu, Question, sans Issue, ou plus loin : refusé", () => {
    for (const status of [
      "sending",
      "received",
      "in_progress",
      "delivered",
      "refused",
      "answered",
    ] as TicketStatus[]) {
      assert.equal(validatePrecondition({ ...base, status }).kind, "refused", status);
    }
    const question = validatePrecondition({ ...base, type: "question" });
    assert.equal(question.kind, "refused");
    assert.match(
      (question as { message: string }).message,
      /Une question reçoit une réponse sur GitHub/,
    );
    assert.equal(validatePrecondition({ ...base, hasIssue: false }).kind, "refused");
  });
});

describe("refusePrecondition", () => {
  test("Reçu, Analysé, Validé, En cours avec Issue : permis", () => {
    for (const status of ["received", "analyzed", "validated", "in_progress"] as TicketStatus[]) {
      assert.equal(refusePrecondition({ status, hasIssue: true }), null, status);
    }
  });

  test("envoi en cours, fin, ou sans Issue : refusé", () => {
    for (const status of ["sending", "delivered", "refused", "answered"] as TicketStatus[]) {
      assert.notEqual(refusePrecondition({ status, hasIssue: true }), null, status);
    }
    assert.notEqual(refusePrecondition({ status: "received", hasIssue: false }), null);
  });
});

describe("decisionGithubFailure", () => {
  test("jeton refusé, Issue disparue, limite de débit, panne", () => {
    assert.deepEqual(decisionGithubFailure("token"), {
      code: "failed-precondition",
      message: "GitHub refuse le jeton. Rien n'a été modifié.",
      reason: "github_token",
    });
    assert.deepEqual(decisionGithubFailure("not_found"), {
      code: "not-found",
      message: "L'Issue n'existe plus sur GitHub.",
      reason: "issue_not_found",
    });
    assert.equal(decisionGithubFailure("rate_limit").code, "unavailable");
    assert.equal(decisionGithubFailure("network").reason, "github_unavailable");
    assert.equal(decisionGithubFailure("other").reason, "github_unavailable");
  });

  test("l'échec partiel a sa propre raison", () => {
    assert.equal(REFUSAL_PARTIAL_REASON, "reply_published_close_failed");
  });
});

// ── Webhook ─────────────────────────────────────────────────────────────────

describe("analysisRefreshFromEvent", () => {
  const repository = { full_name: REPO };
  const event = (action: string, authorId: number, issue: Record<string, unknown> = {}) => ({
    action,
    repository,
    issue: { number: 21, ...issue },
    comment: { user: { id: authorId }, body: "## Analyse" },
  });

  test("commentaire du mainteneur créé, modifié ou supprimé : relire l'Issue", () => {
    for (const action of ["created", "edited", "deleted"]) {
      assert.equal(analysisRefreshFromEvent("issue_comment", event(action, MAINTAINER_ID)), 21);
    }
  });

  test("autre auteur, PR, autre dépôt, autre événement : rien", () => {
    assert.equal(analysisRefreshFromEvent("issue_comment", event("created", 99)), null);
    assert.equal(
      analysisRefreshFromEvent(
        "issue_comment",
        event("created", MAINTAINER_ID, { pull_request: {} }),
      ),
      null,
    );
    assert.equal(
      analysisRefreshFromEvent("issue_comment", {
        ...event("created", MAINTAINER_ID),
        repository: { full_name: "autre/depot" },
      }),
      null,
    );
    assert.equal(analysisRefreshFromEvent("issues", event("created", MAINTAINER_ID)), null);
    assert.equal(analysisRefreshFromEvent("issue_comment", event("pinned", MAINTAINER_ID)), null);
  });

  test("une réponse supprimée ne devient pas `reply_text`", () => {
    assert.deepEqual(
      updatesFromEvent("issue_comment", {
        action: "deleted",
        repository,
        issue: { number: 21 },
        comment: { user: { id: MAINTAINER_ID }, body: "Réponse : ancienne" },
      }),
      [],
    );
  });
});

// ── Arguments des callables ─────────────────────────────────────────────────

describe("arguments de validateTicket et refuseTicket", () => {
  test("identifiant de ticket", () => {
    assert.equal(readTicketIdArg({ ticketId: "abc_123-X" }), "abc_123-X");
    for (const bad of [undefined, {}, { ticketId: "" }, { ticketId: "a/b" }, { ticketId: 12 }]) {
      assert.throws(
        () => readTicketIdArg(bad),
        (err: unknown) => err instanceof HttpsError && err.code === "invalid-argument",
      );
    }
  });

  test("motif : lu, nettoyé, ou refusé avec le champ", () => {
    assert.equal(readRefusalArg({ reason: "  Pas prévu.  " }), "Pas prévu.");
    assert.throws(
      () => readRefusalArg({ reason: "abc" }),
      (err: unknown) =>
        err instanceof HttpsError &&
        err.code === "invalid-argument" &&
        (err.details as { field?: string }).field === "reason",
    );
    // Garde de taille brute avant tout nettoyage.
    assert.throws(
      () => readRefusalArg({ reason: "x".repeat(10_000) }),
      (err: unknown) => err instanceof HttpsError,
    );
  });
});

// ── Fixture partagée avec Dart ──────────────────────────────────────────────

const DECISIONS_FIXTURE = JSON.parse(
  readFileSync(
    path.join(__dirname, "..", "..", "..", "test-fixtures", "ticket_decisions.json"),
    "utf8",
  ),
) as {
  refusal_partial_reason: string;
  default_launches_per_day: number;
  max_launches_per_day: number;
  cases: {
    status: string;
    type: TicketType;
    has_issue: boolean;
    can_validate: boolean;
    can_refuse: boolean;
    can_launch_analysis: boolean;
    can_launch_development: boolean;
  }[];
  launch_runs: {
    name: string;
    action: "analyse" | "developpement";
    raw_status: string;
    now: string;
    launches: {
      action: string;
      outcome: string;
      from_status: string;
      launched_at: string | null;
      retry_after: string | null;
    }[];
    running: boolean;
    running_since: string | null;
    relaunch_of: string | null;
  }[];
};

const isoMs = (iso: string | null): number | null => (iso === null ? null : Date.parse(iso));

describe("fixture ticket_decisions.json (partagée avec le client)", () => {
  test("raison de l'échec partiel d'un refus", () => {
    assert.equal(REFUSAL_PARTIAL_REASON, DECISIONS_FIXTURE.refusal_partial_reason);
  });

  for (const c of DECISIONS_FIXTURE.cases) {
    test(`${c.status} · ${c.type} · ${c.has_issue ? "avec" : "sans"} Issue`, () => {
      assert.deepEqual(
        ticketDecisions({ rawStatus: c.status, type: c.type, hasIssue: c.has_issue }),
        {
          canValidate: c.can_validate,
          canRefuse: c.can_refuse,
          canLaunchAnalysis: c.can_launch_analysis,
          canLaunchDevelopment: c.can_launch_development,
        },
      );
    });
  }

  test("plafond quotidien des lancements par défaut", () => {
    assert.equal(DEFAULT_LAUNCHES_PER_DAY, DECISIONS_FIXTURE.default_launches_per_day);
    assert.equal(MAX_LAUNCHES_PER_DAY, DECISIONS_FIXTURE.max_launches_per_day);
  });

  for (const r of DECISIONS_FIXTURE.launch_runs) {
    test(`lancements : ${r.name}`, () => {
      const state = launchRunState({
        entries: r.launches.map((e) => ({
          action: e.action,
          outcome: e.outcome,
          from_status: e.from_status,
          launched_at_ms: isoMs(e.launched_at),
          retry_after_ms: isoMs(e.retry_after),
        })),
        action: r.action,
        rawStatus: r.raw_status,
        nowMs: Date.parse(r.now),
      });
      assert.deepEqual(state, {
        running: r.running,
        runningSinceMs: isoMs(r.running_since),
        relaunchOfMs: isoMs(r.relaunch_of),
      });
    });
  }
});

describe("écriture de la validation", () => {
  test("un ticket déjà refusé, livré ou validé n'est pas réécrit", () => {
    for (const status of [
      "refused",
      "delivered",
      "answered",
      "validated",
      "in_progress",
      "received",
      "sending",
    ] as TicketStatus[]) {
      assert.equal(shouldWriteValidated(status), false, status);
    }
    assert.equal(shouldWriteValidated("analyzed"), true);
  });

  test("une validation sur un ticket déjà refusé est refusée avant tout appel", () => {
    const pre = validatePrecondition({ status: "refused", type: "bug", hasIssue: true });
    assert.equal(pre.kind, "refused");
  });
});
