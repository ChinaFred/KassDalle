/**
 * Tickets, lot A du ticket #73 : logique pure.
 *
 * - détection d'une analyse du mainteneur (auteur, préfixe), ordre, plafond
 *   de dix, troncature à la dernière ligne vide ;
 * - lecture du motif de refus et reconnaissance d'un motif déjà publié ;
 * - conditions de « Valider » et « Refuser », message d'un échec GitHub ;
 * - événement du webhook qui demande de relire les analyses ;
 * - lecture des arguments des callables ;
 * - lot 2 : réponse de l'administrateur à une analyse (texte, adresse
 *   e-mail, état de la dernière analyse), ticket bloqué, dernier « validé »
 *   du mainteneur, état d'Issue périmé, lancements antérieurs à un
 *   changement de statut.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import { HttpsError } from "firebase-functions/v2/https";

import {
  ANALYSIS_MAX_CHARS,
  ANALYSIS_MAX_COUNT,
  ANSWER_MAX_CHARS,
  ANSWER_MIN_CHARS,
  ANSWER_DEVELOPMENT_RUNNING_MESSAGE,
  ANSWER_PARTIAL_REASON,
  analysisAnswerState,
  answerCommentBody,
  nextValidatedAt,
  readAnswerCommentIds,
  answerPrecondition,
  containsEmailAddress,
  isAnswerComment,
  isStaleIssueSnapshot,
  lastMaintainerValidatedAt,
  readAnswerText,
  ticketAwaitingReply,
  ticketCanReply,
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
  DELIVERY_SENSITIVE_REASON,
  FOUNDER_LAUNCHES_PER_DAY,
  LAUNCH_ACTIONS,
  LAUNCH_FROM_STATUS,
  LAUNCH_RETRY_MS,
  deliveryLockActive,
  MAX_LAUNCHES_PER_DAY,
  launchLimitFor,
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
import {
  analysisRefreshFromEvent,
  updatesFromEvent,
  validatedLabelFromEvent,
} from "../tickets/webhook";
import { lastAnalysisMillis } from "../tickets/stored";
import { readAnswerArg, readRefusalArg, readTicketIdArg } from "../callable/ticketsCallable";
import { Timestamp } from "firebase-admin/firestore";
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
    assert.deepEqual(
      out.map((a) => a.kind),
      ["analysis", "analysis"],
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
  answer_partial_reason: string;
  default_launches_per_day: number;
  max_launches_per_day: number;
  founder_launches_per_day: number;
  delivery_sensitive_reason: string;
  launch_actions: { action: string; from_status: string; retry_hours: number }[];
  launch_limits: { configured: number; is_founder: boolean; expected: number }[];
  cases: {
    status: string;
    type: TicketType;
    has_issue: boolean;
    can_validate: boolean;
    can_refuse: boolean;
    can_launch_analysis: boolean;
    can_launch_development: boolean;
    can_deliver: boolean;
  }[];
  launch_runs: {
    name: string;
    action: "analyse" | "developpement" | "livraison";
    raw_status: string;
    now: string;
    status_changed_at?: string | null;
    delivery_blocked_at?: string | null;
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
    blocked?: boolean;
  }[];
  delivery_lock: {
    name: string;
    lock: {
      ticket_id: string | null;
      issue_number: number | null;
      launched_at: string | null;
      retry_after: string | null;
    } | null;
    locked_ticket_status: string | null;
    now: string;
    active: boolean;
  }[];
  reply_cases: {
    status: string;
    type: TicketType;
    has_issue: boolean;
    has_analysis: boolean;
    development_running: boolean;
    can_reply: boolean;
  }[];
  awaiting_reply: {
    name: string;
    status: string;
    type: TicketType;
    last_analysis_at: string | null;
    validated_known: boolean;
    validated_at: string | null;
    awaiting_reply: boolean;
  }[];
};

const ANSWER_FIXTURE = JSON.parse(
  readFileSync(
    path.join(__dirname, "..", "..", "..", "test-fixtures", "ticket_answer_text.json"),
    "utf8",
  ),
) as {
  min_chars: number;
  max_chars: number;
  email_cases: { text: string; contains_email: boolean }[];
};

const isoMs = (iso: string | null): number | null => (iso === null ? null : Date.parse(iso));

describe("fixture ticket_decisions.json (partagée avec le client)", () => {
  test("raison de l'échec partiel d'un refus", () => {
    assert.equal(REFUSAL_PARTIAL_REASON, DECISIONS_FIXTURE.refusal_partial_reason);
  });

  test("raison de l'échec partiel d'une réponse", () => {
    assert.equal(ANSWER_PARTIAL_REASON, DECISIONS_FIXTURE.answer_partial_reason);
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
          canDeliver: c.can_deliver,
        },
      );
    });
  }

  test("plafond quotidien des lancements par défaut", () => {
    assert.equal(DEFAULT_LAUNCHES_PER_DAY, DECISIONS_FIXTURE.default_launches_per_day);
    assert.equal(MAX_LAUNCHES_PER_DAY, DECISIONS_FIXTURE.max_launches_per_day);
    assert.equal(FOUNDER_LAUNCHES_PER_DAY, DECISIONS_FIXTURE.founder_launches_per_day);
  });

  for (const l of DECISIONS_FIXTURE.launch_limits) {
    test(`plafond effectif : réglage ${l.configured}, fondateur ${l.is_founder}`, () => {
      assert.equal(launchLimitFor(l.configured, l.is_founder), l.expected);
    });
  }

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
        statusChangedAtMs: isoMs(r.status_changed_at ?? null),
        deliveryBlockedAtMs: isoMs(r.delivery_blocked_at ?? null),
      });
      assert.deepEqual(state, {
        running: r.running,
        runningSinceMs: isoMs(r.running_since),
        relaunchOfMs: isoMs(r.relaunch_of),
        blocked: r.blocked ?? false,
      });
    });
  }

  test("les trois lancements, leur statut de départ et leur échéance", () => {
    assert.deepEqual(
      [...LAUNCH_ACTIONS],
      DECISIONS_FIXTURE.launch_actions.map((a) => a.action),
    );
    for (const a of DECISIONS_FIXTURE.launch_actions) {
      const action = a.action as (typeof LAUNCH_ACTIONS)[number];
      assert.equal(LAUNCH_FROM_STATUS[action], a.from_status);
      assert.equal(LAUNCH_RETRY_MS[action], a.retry_hours * 3_600_000);
    }
  });

  test("raison du refus d'une PR qui modifie un fichier sensible", () => {
    assert.equal(DELIVERY_SENSITIVE_REASON, DECISIONS_FIXTURE.delivery_sensitive_reason);
  });

  for (const c of DECISIONS_FIXTURE.delivery_lock) {
    test(`verrou des livraisons : ${c.name}`, () => {
      assert.equal(
        deliveryLockActive({
          lock:
            c.lock === null
              ? null
              : {
                  ticketId: c.lock.ticket_id,
                  issueNumber: c.lock.issue_number,
                  launchedAtMs: isoMs(c.lock.launched_at),
                  retryAfterMs: isoMs(c.lock.retry_after),
                },
          lockedTicketRawStatus: c.locked_ticket_status,
          nowMs: Date.parse(c.now),
        }),
        c.active,
      );
    });
  }
});

describe("fixture ticket_decisions.json : réponse et ticket bloqué", () => {
  for (const c of DECISIONS_FIXTURE.reply_cases) {
    test(`Répondre : ${c.status} · ${c.type} · ${c.has_issue ? "avec" : "sans"} Issue · ${
      c.has_analysis ? "avec" : "sans"
    } analyse${c.development_running ? " · développement en cours" : ""}`, () => {
      assert.equal(
        ticketCanReply({
          rawStatus: c.status,
          type: c.type,
          hasIssue: c.has_issue,
          hasAnalysis: c.has_analysis,
          developmentRunning: c.development_running,
        }),
        c.can_reply,
      );
    });
  }

  for (const c of DECISIONS_FIXTURE.awaiting_reply) {
    test(`bloqué : ${c.name}`, () => {
      assert.equal(
        ticketAwaitingReply({
          rawStatus: c.status,
          type: c.type,
          lastAnalysisAtMs: isoMs(c.last_analysis_at),
          validatedAtMs: c.validated_known ? isoMs(c.validated_at) : undefined,
        }),
        c.awaiting_reply,
      );
    });
  }
});

describe("fixture ticket_answer_text.json (partagée avec le client)", () => {
  test("bornes du texte", () => {
    assert.equal(ANSWER_MIN_CHARS, ANSWER_FIXTURE.min_chars);
    assert.equal(ANSWER_MAX_CHARS, ANSWER_FIXTURE.max_chars);
  });

  for (const c of ANSWER_FIXTURE.email_cases) {
    test(`adresse e-mail : ${JSON.stringify(c.text)}`, () => {
      assert.equal(containsEmailAddress(c.text), c.contains_email);
    });
  }
});

describe("readAnswerText", () => {
  test("nettoie, garde les retours à la ligne, neutralise mentions et renvois", () => {
    assert.equal(
      readAnswerText("  Oui, voir @ChinaFred et #12.\r\nMerci.\u0007 "),
      `Oui, voir @${ZWSP}ChinaFred et #${ZWSP}12.\nMerci.`,
    );
  });

  test("refuse un texte absent, trop court, trop long ou avec une adresse", () => {
    assert.throws(() => readAnswerText(undefined), TicketInputError);
    assert.throws(() => readAnswerText(" abcd "), /au moins 5/);
    assert.throws(() => readAnswerText("x".repeat(4001)), /4 000/);
    assert.equal(readAnswerText("x".repeat(4000)).length, 4000);
    try {
      readAnswerText("Écrivez à moi@exemple.fr");
      assert.fail("aurait dû lever");
    } catch (err) {
      assert.ok(err instanceof TicketInputError);
      assert.equal(err.field, "answer");
      assert.equal(err.reason, "contains_email");
      assert.equal(err.message, "Retirez l'adresse e-mail avant de publier.");
    }
  });

  test("le commentaire publié est reconnu comme réponse, pas comme analyse", () => {
    const body = answerCommentBody("Oui, garder le bouton.");
    assert.equal(body, "## Précisions de l'administrateur\n\nOui, garder le bouton.");
    assert.equal(isAnswerComment({ authorId: MAINTAINER_ID, body }, MAINTAINER_ID), true);
    assert.equal(isAnalysisComment({ authorId: MAINTAINER_ID, body }, MAINTAINER_ID), false);
    assert.equal(isAnswerComment({ authorId: 99, body }, MAINTAINER_ID), false);
    // La réponse affichée au membre (`Réponse :`) n'est pas une précision.
    assert.equal(
      isAnswerComment({ authorId: MAINTAINER_ID, body: "Réponse : non" }, MAINTAINER_ID),
      false,
    );
  });

  test("argument de la callable : champ et raison rendus au client", () => {
    assert.equal(readAnswerArg({ answer: "  Oui, garder.  " }), "Oui, garder.");
    assert.throws(
      () => readAnswerArg({ answer: "Mon adresse : a@b.fr" }),
      (err: unknown) =>
        err instanceof HttpsError &&
        err.code === "invalid-argument" &&
        (err.details as { field?: string; reason?: string }).field === "answer" &&
        (err.details as { reason?: string }).reason === "contains_email",
    );
    assert.throws(
      () => readAnswerArg({ answer: "abc" }),
      (err: unknown) =>
        err instanceof HttpsError &&
        (err.details as { field?: string }).field === "answer" &&
        (err.details as { reason?: string }).reason === undefined,
    );
    assert.throws(
      () => readAnswerArg({ answer: "x".repeat(10_000) }),
      (err: unknown) => err instanceof HttpsError,
    );
  });
});

describe("answerPrecondition", () => {
  test("Analysé ou Validé, hors Question, avec Issue : permis", () => {
    for (const status of ["analyzed", "validated"] as TicketStatus[]) {
      assert.equal(answerPrecondition({ status, type: "bug", hasIssue: true }), null, status);
    }
  });

  test("Reçu, Question, sans Issue : refusé", () => {
    assert.notEqual(answerPrecondition({ status: "received", type: "bug", hasIssue: true }), null);
    assert.notEqual(
      answerPrecondition({ status: "analyzed", type: "question", hasIssue: true }),
      null,
    );
    assert.notEqual(answerPrecondition({ status: "analyzed", type: "bug", hasIssue: false }), null);
  });

  test("développement en cours : refusé avec son message", () => {
    assert.equal(
      answerPrecondition({
        status: "validated",
        type: "bug",
        hasIssue: true,
        developmentRunning: true,
      }),
      ANSWER_DEVELOPMENT_RUNNING_MESSAGE,
    );
  });
});

describe("analysesFromComments : réponses de l'administrateur", () => {
  test("relevées avec leur nature, intercalées dans l'ordre", () => {
    const out = analysesFromComments(
      [
        comment({ id: 1, body: "## Analyse\n\nA", createdAt: "2026-10-11T00:00:00Z" }),
        comment({
          id: 2,
          body: "## Précisions de l'administrateur\n\nR",
          createdAt: "2026-10-12T00:00:00Z",
        }),
        comment({
          id: 3,
          authorId: 99,
          body: "## Précisions de l'administrateur\n\nIntrus",
          createdAt: "2026-10-12T01:00:00Z",
        }),
        comment({
          id: 5,
          body: "## Précisions de l'administrateur\n\nÉcrite par une session",
          createdAt: "2026-10-12T02:00:00Z",
        }),
        comment({ id: 4, body: "## Analyse — compléments", createdAt: "2026-10-13T00:00:00Z" }),
      ],
      MAINTAINER_ID,
      new Set([2]),
    );
    assert.deepEqual(
      out.map((a) => [a.comment_id, a.kind]),
      [
        [1, "analysis"],
        [2, "reply"],
        [5, "unverified_reply"],
        [4, "analysis"],
      ],
    );
  });

  test("sans identifiants enregistrés, aucune précision n'est une réponse", () => {
    const out = analysesFromComments(
      [comment({ id: 2, body: "## Précisions de l'administrateur\n\nR" })],
      MAINTAINER_ID,
    );
    assert.equal(out[0].kind, "unverified_reply");
  });

  test("identifiants stockés lus sans supposer leur forme", () => {
    assert.deepEqual([...readAnswerCommentIds([3, "4", 5.5, null, 7])], [3, 7]);
    assert.equal(readAnswerCommentIds(undefined).size, 0);
  });
});

describe("analysisAnswerState", () => {
  const analysis = (id: number, at: string) =>
    comment({ id, body: "## Analyse\n\nX", createdAt: at });
  const answer = (id: number, at: string, text = "Y") =>
    comment({ id, body: `## Précisions de l'administrateur\n\n${text}`, createdAt: at });
  const body = answerCommentBody("Y");

  test("aucune analyse", () => {
    assert.deepEqual(
      analysisAnswerState([answer(1, "2026-10-10T00:00:00Z")], MAINTAINER_ID, new Set([1]), body),
      { hasAnalysis: false, lastAnalysisAt: null, samePublished: false },
    );
  });

  test("même réponse déjà publiée depuis l'application après l'analyse : pas de republication", () => {
    const a = analysis(1, "2026-10-10T00:00:00Z");
    assert.deepEqual(analysisAnswerState([a], MAINTAINER_ID, new Set(), body), {
      hasAnalysis: true,
      lastAnalysisAt: "2026-10-10T00:00:00Z",
      samePublished: false,
    });
    assert.equal(
      analysisAnswerState([a, answer(2, "2026-10-11T00:00:00Z")], MAINTAINER_ID, new Set([2]), body)
        .samePublished,
      true,
    );
  });

  test("précision non enregistrée ou texte différent : republication", () => {
    const a = analysis(1, "2026-10-10T00:00:00Z");
    // Une session a publié une fausse précision : elle ne remplace pas la réponse.
    assert.equal(
      analysisAnswerState([a, answer(2, "2026-10-11T00:00:00Z")], MAINTAINER_ID, new Set(), body)
        .samePublished,
      false,
    );
    assert.equal(
      analysisAnswerState(
        [a, answer(2, "2026-10-11T00:00:00Z", "Autre texte")],
        MAINTAINER_ID,
        new Set([2]),
        body,
      ).samePublished,
      false,
    );
  });

  test("une réponse antérieure à la dernière analyse ne compte pas", () => {
    const state = analysisAnswerState(
      [
        analysis(1, "2026-10-10T00:00:00Z"),
        answer(2, "2026-10-11T00:00:00Z"),
        analysis(3, "2026-10-12T00:00:00Z"),
      ],
      MAINTAINER_ID,
      new Set([2]),
      body,
    );
    assert.equal(state.lastAnalysisAt, "2026-10-12T00:00:00Z");
    assert.equal(state.samePublished, false);
  });
});

describe("nextValidatedAt", () => {
  test("champ absent : la valeur lue est écrite, null compris", () => {
    assert.equal(nextValidatedAt(undefined, 100, true), 100);
    assert.equal(nextValidatedAt(undefined, null, true), null);
  });

  test("étiquette présente : jamais plus ancien, jamais null", () => {
    assert.equal(nextValidatedAt(200, 100, true), undefined);
    assert.equal(nextValidatedAt(200, 200, true), undefined);
    assert.equal(nextValidatedAt(200, null, true), undefined);
    assert.equal(nextValidatedAt(200, 300, true), 300);
    assert.equal(nextValidatedAt(null, 300, true), 300);
    assert.equal(nextValidatedAt(null, null, true), undefined);
  });

  test("étiquette absente : la valeur lue remplace la valeur stockée", () => {
    assert.equal(nextValidatedAt(200, 100, false), 100);
    assert.equal(nextValidatedAt(200, null, false), null);
    assert.equal(nextValidatedAt(200, 200, false), undefined);
  });
});

describe("dernier « validé » du mainteneur", () => {
  const labeled = (name: string, actorId: number, at: string) => ({
    event: "labeled",
    label: { name },
    actor: { id: actorId },
    created_at: at,
  });

  test("le plus récent du mainteneur, autres étiquettes et acteurs ignorés", () => {
    assert.equal(
      lastMaintainerValidatedAt(
        [
          labeled("validé", MAINTAINER_ID, "2026-10-10T00:00:00Z"),
          labeled("validé", 99, "2026-10-13T00:00:00Z"),
          labeled("statut:analysé", MAINTAINER_ID, "2026-10-14T00:00:00Z"),
          { event: "unlabeled", label: { name: "validé" }, actor: { id: MAINTAINER_ID } },
          labeled("validé", MAINTAINER_ID, "2026-10-12T00:00:00Z"),
          null,
          "texte",
        ],
        MAINTAINER_ID,
      ),
      "2026-10-12T00:00:00Z",
    );
  });

  test("aucun : null", () => {
    assert.equal(lastMaintainerValidatedAt([], MAINTAINER_ID), null);
    assert.equal(
      lastMaintainerValidatedAt([labeled("validé", 99, "2026-10-10T00:00:00Z")], MAINTAINER_ID),
      null,
    );
  });

  test("webhook : `labeled validé` du mainteneur seulement", () => {
    const payload = (name: string, senderId: number, issue: Record<string, unknown> = {}) => ({
      action: "labeled",
      repository: { full_name: REPO },
      label: { name },
      sender: { id: senderId },
      issue: { number: 68, updated_at: "2026-10-14T09:00:00Z", ...issue },
    });
    const now = "2026-10-14T10:00:00.000Z";
    assert.deepEqual(validatedLabelFromEvent("issues", payload("validé", MAINTAINER_ID), now), {
      issueNumber: 68,
      at: "2026-10-14T09:00:00Z",
    });
    assert.deepEqual(
      validatedLabelFromEvent(
        "issues",
        payload("validé", MAINTAINER_ID, { updated_at: null }),
        now,
      ),
      { issueNumber: 68, at: now },
    );
    assert.equal(validatedLabelFromEvent("issues", payload("validé", 99), now), null);
    assert.equal(validatedLabelFromEvent("issues", payload("autre", MAINTAINER_ID), now), null);
    assert.equal(
      validatedLabelFromEvent(
        "issues",
        { ...payload("validé", MAINTAINER_ID), action: "unlabeled" },
        now,
      ),
      null,
    );
    assert.equal(
      validatedLabelFromEvent(
        "issues",
        { ...payload("validé", MAINTAINER_ID), repository: { full_name: "autre/depot" } },
        now,
      ),
      null,
    );
  });
});

describe("état d'Issue périmé après une réponse", () => {
  const reset = Date.parse("2026-10-14T10:00:00Z");

  test("antérieur ou égal au retour à Reçu : ignoré", () => {
    assert.equal(isStaleIssueSnapshot("2026-10-14T09:59:59Z", reset), true);
    assert.equal(isStaleIssueSnapshot("2026-10-14T10:00:00Z", reset), true);
  });

  test("postérieur, sans date ou sans réponse : appliqué", () => {
    assert.equal(isStaleIssueSnapshot("2026-10-14T10:00:01Z", reset), false);
    assert.equal(isStaleIssueSnapshot(null, reset), false);
    assert.equal(isStaleIssueSnapshot(undefined, reset), false);
    assert.equal(isStaleIssueSnapshot("illisible", reset), false);
    assert.equal(isStaleIssueSnapshot("2026-10-14T09:00:00Z", null), false);
  });

  test("le webhook transmet la date de l'Issue", () => {
    const [u] = updatesFromEvent("issues", {
      action: "labeled",
      repository: { full_name: REPO },
      issue: { number: 3, state: "open", labels: [], updated_at: "2026-10-14T09:00:00Z" },
    });
    assert.equal(u.update.issueUpdatedAt, "2026-10-14T09:00:00Z");
  });
});

describe("date de la dernière analyse stockée", () => {
  test("analyses seules, `kind` absent lu comme analyse", () => {
    const at = (iso: string) => Timestamp.fromMillis(Date.parse(iso));
    assert.equal(
      lastAnalysisMillis({
        analyses: [
          { created_at: at("2026-10-10T00:00:00Z") },
          { kind: "analysis", created_at: at("2026-10-12T00:00:00Z") },
          { kind: "reply", created_at: at("2026-10-13T00:00:00Z") },
          { kind: "analysis", created_at: null },
          "texte",
        ],
      }),
      Date.parse("2026-10-12T00:00:00Z"),
    );
    assert.equal(lastAnalysisMillis(undefined), null);
    assert.equal(lastAnalysisMillis({ analyses: [] }), null);
  });
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
