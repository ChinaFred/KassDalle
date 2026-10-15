/**
 * Tickets : « Livrer » (logique pure).
 *
 * - texte `livraison #N`, condition de statut, routine de développement ;
 * - PR éligible, dernier run de la CI, état « PR prête » ;
 * - fichiers sensibles ;
 * - comptes rendus `## Livraison — …` du mainteneur ;
 * - verrou libéré par un blocage ;
 * - événements du webhook qui demandent une relecture.
 *
 * Les cas partagés avec le client (décision, règle « en cours » avec
 * blocage, verrou global) sont dans `ticket_decisions.json`, rejoués par
 * `ticketDecisions.test.ts`.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import {
  closingCommitFromEvents,
  pickDeliveredPr,
  pubspecVersionName,
  type MergedPrCandidate,
  DELIVERY_BLOCKED_TITLE,
  DELIVERY_DONE_TITLE,
  DELIVERY_REPORT_MAX_COUNT,
  LAUNCH_NOT_ALLOWED_MESSAGE,
  LAUNCH_ROUTINE,
  blockageReleasesLock,
  deliveryReportKind,
  deliveryReportsFromComments,
  deliveryRunningElsewhereMessage,
  deliverySensitiveMessage,
  deliveryState,
  isEligibleDeliveryPr,
  isGreenCiRun,
  latestCiRun,
  launchCommandText,
  launchPrecondition,
  launchRunningMessage,
  readLaunchCommandText,
  safePullRequestUrl,
  sensitiveDeliveryPath,
  type CiRunView,
  type PullRequestView,
} from "../tickets/rules";
import { routineConfig } from "../tickets/routine";
import { closedIssueFromEvent } from "../tickets/webhook";
import { classifyGithubFailure, readCiRun, readPullRequest } from "../tickets/github";
import {
  DELIVERY_EVENT_MAX,
  deliveryRefreshFromEvent,
  isDeliveryCandidatePr,
} from "../tickets/webhook";

const REPO = "ChinaFred/KassDalle";
const MAINTAINER = 16348852;
const SHA = "a".repeat(40);

function pr(over: Partial<PullRequestView> = {}): PullRequestView {
  return {
    number: 57,
    state: "open",
    draft: false,
    body: "Corrige la liste.\n\nCloses #42",
    authorId: MAINTAINER,
    headRepoFullName: REPO,
    headRef: "claude/ticket-42-liste",
    headSha: SHA,
    htmlUrl: `https://github.com/${REPO}/pull/57`,
    ...over,
  };
}

function run(over: Partial<CiRunView> = {}): CiRunView {
  return {
    id: 1,
    name: "CI",
    headSha: SHA,
    status: "completed",
    conclusion: "success",
    createdAt: "2026-10-15T12:00:00Z",
    updatedAt: "2026-10-15T12:05:00Z",
    ...over,
  };
}

describe("lancement d'une livraison", () => {
  test("texte `livraison #N`, et rien d'autre", () => {
    assert.equal(launchCommandText("livraison", 42), "livraison #42");
    assert.deepEqual(readLaunchCommandText("livraison #42"), {
      action: "livraison",
      issueNumber: 42,
    });
    for (const bad of ["livraison #042", "Livraison #4", "livraison #4 ", "livrer #4"]) {
      assert.equal(readLaunchCommandText(bad), null, bad);
    }
  });

  test("ticket En cours, hors Question, avec Issue", () => {
    assert.equal(
      launchPrecondition({ status: "in_progress", type: "evolution", hasIssue: true }, "livraison"),
      null,
    );
    assert.equal(
      launchPrecondition({ status: "in_progress", type: "question", hasIssue: true }, "livraison"),
      LAUNCH_NOT_ALLOWED_MESSAGE,
    );
    assert.equal(
      launchPrecondition({ status: "validated", type: "bug", hasIssue: true }, "livraison"),
      LAUNCH_NOT_ALLOWED_MESSAGE,
    );
  });

  test("part par la routine de développement, avec ses secrets", () => {
    assert.equal(LAUNCH_ROUTINE.livraison, "developpement");
    const env = { TICKETS_ROUTINE_DEV_ID: "trig_dev", TICKETS_ROUTINE_DEV_TOKEN: "sk-dev" };
    assert.deepEqual(routineConfig("livraison", env), { id: "trig_dev", token: "sk-dev" });
    assert.equal(routineConfig("livraison", { TICKETS_ROUTINE_ANALYSIS_ID: "x" }), null);
  });

  test("messages", () => {
    const at = Date.parse("2026-10-15T12:05:00Z");
    assert.match(launchRunningMessage("livraison", at, at + 3 * 3_600_000), /^Une livraison a été/);
    assert.equal(
      deliveryRunningElsewhereMessage(31, at),
      "Une livraison est en cours sur le ticket #31 depuis le 15/10/26 à 14:05. Une seule " +
        "livraison à la fois. Rien n'a été lancé ni décompté.",
    );
    assert.equal(
      deliverySensitiveMessage(57, ".github/workflows/ci.yml"),
      "La PR #57 modifie .github/workflows/ci.yml : fusionnez-la vous-même après relecture. " +
        "Rien n'a été lancé ni décompté.",
    );
  });
});

describe("PR éligible", () => {
  const ok = (p: PullRequestView) => isEligibleDeliveryPr(p, 42, MAINTAINER, REPO);

  test("ouverte, pas brouillon, du mainteneur, branche claude/ du dépôt, Closes #N", () => {
    assert.equal(ok(pr()), true);
    assert.equal(ok(pr({ body: "fixes ChinaFred/KassDalle#42" })), true);
  });

  test("chaque condition manquante l'écarte", () => {
    assert.equal(ok(pr({ state: "closed" })), false);
    assert.equal(ok(pr({ draft: true })), false);
    assert.equal(ok(pr({ authorId: 1 })), false);
    assert.equal(ok(pr({ authorId: null })), false);
    assert.equal(ok(pr({ headRepoFullName: "intrus/KassDalle" })), false);
    assert.equal(ok(pr({ headRepoFullName: null })), false);
    assert.equal(ok(pr({ headRef: "feature/x" })), false);
    assert.equal(ok(pr({ body: "Voir #42" })), false);
    assert.equal(ok(pr({ body: "Closes #43" })), false);
    assert.equal(ok(pr({ body: "Closes autre/depot#42" })), false);
  });

  test("le corps ne ferme que cette Issue", () => {
    assert.equal(ok(pr({ body: "Closes #42\nCloses #43" })), false);
    assert.equal(ok(pr({ body: "Fixes #41, closes #42" })), false);
    assert.equal(ok(pr({ body: "Closes #42\nVoir aussi #43" })), true);
    assert.equal(ok(pr({ body: "Closes #42\nCloses #42" })), true);
    assert.equal(ok(pr({ body: "Closes #42\nCloses autre/depot#43" })), true);
  });

  test("lecture d'une PR de l'API", () => {
    const read = readPullRequest({
      number: 57,
      state: "open",
      draft: false,
      body: "Closes #42",
      user: { id: MAINTAINER },
      head: { ref: "claude/x", sha: SHA, repo: { full_name: REPO } },
      html_url: `https://github.com/${REPO}/pull/57`,
      mergeable: false,
    });
    // `mergeable` n'est pas lu : un conflit signalé par GitHub n'empêche pas la livraison.
    assert.deepEqual(read, pr({ body: "Closes #42", headRef: "claude/x" }));
    assert.equal(readPullRequest({ number: "57" }), null);
    assert.equal(readPullRequest({ number: 3, head: { repo: null } })?.headRepoFullName, null);
  });
});

describe("dernier run de la CI", () => {
  test("le plus récent du workflow CI sur la tête", () => {
    const runs = [
      run({ id: 1, conclusion: "failure", createdAt: "2026-10-15T11:00:00Z" }),
      run({ id: 2, conclusion: "success", createdAt: "2026-10-15T12:00:00Z" }),
      run({ id: 3, name: "Déploiement", createdAt: "2026-10-15T13:00:00Z" }),
      run({ id: 4, headSha: "b".repeat(40), createdAt: "2026-10-15T14:00:00Z" }),
    ];
    assert.equal(latestCiRun(runs, SHA)?.id, 2);
    assert.equal(latestCiRun([], SHA), null);
  });

  test("à égalité de date, le plus grand identifiant", () => {
    assert.equal(latestCiRun([run({ id: 5 }), run({ id: 9 })], SHA)?.id, 9);
  });

  test("vert : fini et réussi", () => {
    assert.equal(isGreenCiRun(run()), true);
    assert.equal(isGreenCiRun(run({ status: "in_progress", conclusion: null })), false);
    assert.equal(isGreenCiRun(run({ conclusion: "failure" })), false);
    assert.equal(isGreenCiRun(null), false);
  });

  test("lecture d'un run de l'API", () => {
    assert.deepEqual(
      readCiRun({
        id: 1,
        name: "CI",
        head_sha: SHA,
        status: "completed",
        conclusion: "success",
        created_at: "2026-10-15T12:00:00Z",
        updated_at: "2026-10-15T12:05:00Z",
      }),
      run(),
    );
  });
});

describe("état « PR prête »", () => {
  const base = { ticketStatus: "in_progress", repoFullName: REPO };

  test("prête : En cours, une PR, CI verte", () => {
    const state = deliveryState({ ...base, eligible: [pr()], pr: pr(), ciRun: run() });
    assert.deepEqual(state, {
      eligible_pr_count: 1,
      pr_number: 57,
      pr_url: `https://github.com/${REPO}/pull/57`,
      head_sha: SHA,
      ci_status: "completed",
      ci_conclusion: "success",
      ci_completed_at: "2026-10-15T12:05:00Z",
      ready: true,
    });
  });

  test("CI rouge ou en cours, ticket ailleurs : pas prête", () => {
    const failed = deliveryState({
      ...base,
      eligible: [pr()],
      pr: pr(),
      ciRun: run({ conclusion: "failure" }),
    });
    assert.equal(failed.ready, false);
    assert.equal(failed.ci_conclusion, "failure");
    const running = deliveryState({
      ...base,
      eligible: [pr()],
      pr: pr(),
      ciRun: run({ status: "in_progress", conclusion: null }),
    });
    assert.equal(running.ready, false);
    assert.equal(running.ci_completed_at, null);
    assert.equal(
      deliveryState({ ...base, eligible: [pr()], pr: pr(), ciRun: null }).ci_status,
      null,
    );
    assert.equal(
      deliveryState({
        ...base,
        ticketStatus: "validated",
        eligible: [pr()],
        pr: pr(),
        ciRun: run(),
      }).ready,
      false,
    );
  });

  test("liste des PR tronquée : jamais prête", () => {
    assert.equal(
      deliveryState({ ...base, prListComplete: false, eligible: [pr()], pr: pr(), ciRun: run() })
        .ready,
      false,
    );
  });

  test("aucune ou plusieurs PR : pas de PR retenue", () => {
    const none = deliveryState({ ...base, eligible: [], pr: null, ciRun: null });
    assert.equal(none.eligible_pr_count, 0);
    assert.equal(none.pr_number, null);
    assert.equal(none.ready, false);
    const two = deliveryState({
      ...base,
      eligible: [pr(), pr({ number: 58 })],
      pr: null,
      ciRun: run(),
    });
    assert.equal(two.eligible_pr_count, 2);
    assert.equal(two.pr_number, null);
    assert.equal(two.ci_status, null);
    assert.equal(two.ready, false);
  });

  test("adresse de la PR : github.com, ce dépôt, un numéro", () => {
    assert.equal(
      safePullRequestUrl(`https://github.com/${REPO}/pull/57`, REPO),
      `https://github.com/${REPO}/pull/57`,
    );
    for (const bad of [
      `http://github.com/${REPO}/pull/57`,
      `https://github.com/autre/depot/pull/57`,
      `https://github.com/${REPO}/pull/57/files`,
      `https://github.com.evil.example/${REPO}/pull/57`,
      null,
    ]) {
      assert.equal(safePullRequestUrl(bad, REPO), null, String(bad));
    }
  });
});

describe("fichiers sensibles", () => {
  const f = (filename: string, previousFilename: string | null = null) => ({
    filename,
    previousFilename,
  });

  test("le premier chemin sensible, renommage compris", () => {
    assert.equal(sensitiveDeliveryPath([f("kass_dalle/lib/a.dart")]), null);
    assert.equal(
      sensitiveDeliveryPath([f("kass_dalle/lib/a.dart"), f(".github/workflows/ci.yml")]),
      ".github/workflows/ci.yml",
    );
    for (const path of [
      ".claude/agents/x.md",
      "CLAUDE.md",
      "deploy.ps1",
      "kass_dalle/firebase.json",
      "Claude.md",
      "kass_dalle/CLAUDE.md",
      "documentation/CLAUDE.md",
      "x/CLAUDE.local.md",
      "CLAUDE.local.md",
      ".mcp.json",
      "kass_dalle/functions/.mcp.json",
    ]) {
      assert.equal(sensitiveDeliveryPath([f(path)]), path);
    }
    assert.equal(sensitiveDeliveryPath([f("docs/ci.yml", ".github/ci.yml")]), ".github/ci.yml");
  });

  test("un nom proche n'est pas sensible", () => {
    for (const path of [
      "documentation/CLAUDE.md.bak",
      "docs/notes-claude.md",
      "mcp.json",
      "kass_dalle/firebase.json.bak",
      "github/x",
      "kass_dalle/functions/firebase.json",
    ]) {
      assert.equal(sensitiveDeliveryPath([f(path)]), null, path);
    }
  });
});

describe("comptes rendus de livraison", () => {
  const c = (id: number, body: string, createdAt: string, authorId = MAINTAINER) => ({
    id,
    authorId,
    body,
    createdAt,
    updatedAt: createdAt,
  });

  test("nature : auteur mainteneur et titre exact", () => {
    assert.equal(
      deliveryReportKind(
        { authorId: MAINTAINER, body: `  ${DELIVERY_BLOCKED_TITLE}\n\nCI` },
        MAINTAINER,
      ),
      "blocked",
    );
    assert.equal(
      deliveryReportKind(
        { authorId: MAINTAINER, body: `${DELIVERY_DONE_TITLE}\n\nv0.23.75` },
        MAINTAINER,
      ),
      "done",
    );
    assert.equal(
      deliveryReportKind({ authorId: 1, body: `${DELIVERY_BLOCKED_TITLE}` }, MAINTAINER),
      null,
    );
    assert.equal(
      deliveryReportKind({ authorId: MAINTAINER, body: "## Analyse" }, MAINTAINER),
      null,
    );
    assert.equal(
      deliveryReportKind({ authorId: MAINTAINER, body: "## Livraison - blocage" }, MAINTAINER),
      null,
    );
  });

  test("ordre chronologique, dix au plus", () => {
    const comments = [
      c(2, `${DELIVERY_DONE_TITLE}\n\nFini.`, "2026-10-15T14:00:00Z"),
      c(1, `${DELIVERY_BLOCKED_TITLE}\n\nConflit.`, "2026-10-15T13:00:00Z"),
      c(3, "## Analyse\n\nX", "2026-10-15T12:00:00Z"),
      c(4, `${DELIVERY_BLOCKED_TITLE}\n\nIntrus.`, "2026-10-15T15:00:00Z", 99),
    ];
    const reports = deliveryReportsFromComments(comments, MAINTAINER);
    assert.deepEqual(
      reports.map((r) => [r.comment_id, r.kind]),
      [
        [1, "blocked"],
        [2, "done"],
      ],
    );
    const many = Array.from({ length: 12 }, (_, i) =>
      c(i, `${DELIVERY_BLOCKED_TITLE}\n\n${i}`, `2026-10-15T1${i % 10}:0${Math.floor(i / 10)}:00Z`),
    );
    assert.equal(deliveryReportsFromComments(many, MAINTAINER).length, DELIVERY_REPORT_MAX_COUNT);
  });
});

describe("verrou libéré par un blocage", () => {
  const lock = {
    ticketId: "t31",
    issueNumber: 31,
    launchedAtMs: 1_000,
    retryAfterMs: 10_000,
  };

  test("même ticket, blocage postérieur au lancement", () => {
    assert.equal(blockageReleasesLock(lock, "t31", 2_000), true);
    assert.equal(blockageReleasesLock(lock, "t31", 1_000), false);
    assert.equal(blockageReleasesLock(lock, "t31", null), false);
    assert.equal(blockageReleasesLock(lock, "t32", 2_000), false);
    assert.equal(blockageReleasesLock(null, "t31", 2_000), false);
  });
});

describe("deliveryRefreshFromEvent", () => {
  const repository = { full_name: REPO };
  const candidate = (over: Record<string, unknown>) => ({
    user: { id: MAINTAINER },
    head: { ref: "claude/x", sha: SHA, repo: { full_name: REPO } },
    ...over,
  });

  test("pull_request d'une copie du dépôt ou d'un autre auteur : rien", () => {
    for (const over of [
      { head: { ref: "claude/x", sha: SHA, repo: { full_name: "intrus/KassDalle" } } },
      { head: { ref: "claude/x", sha: SHA, repo: null } },
      { user: { id: 1 }, author_association: "COLLABORATOR" },
      { user: null },
    ]) {
      assert.equal(
        deliveryRefreshFromEvent("pull_request", {
          action: "synchronize",
          repository,
          pull_request: candidate({ number: 57, body: "Closes #42", ...over }),
        }),
        null,
        JSON.stringify(over),
      );
    }
  });

  test("cinq Issues au plus par événement", () => {
    const body = Array.from({ length: 8 }, (_, i) => `Closes #${i + 1}`).join("\n");
    assert.deepEqual(
      deliveryRefreshFromEvent("pull_request", {
        action: "edited",
        repository,
        pull_request: candidate({ number: 57, body }),
      })?.issueNumbers,
      [1, 2, 3, 4, 5],
    );
    assert.equal(
      deliveryRefreshFromEvent("workflow_run", {
        action: "completed",
        repository,
        workflow_run: {
          name: "CI",
          pull_requests: Array.from({ length: 8 }, (_, i) => ({ number: i + 1 })),
        },
      })?.prNumbers.length,
      DELIVERY_EVENT_MAX,
    );
  });

  test("candidate : auteur mainteneur, tête dans le dépôt", () => {
    assert.equal(isDeliveryCandidatePr(pr()), true);
    assert.equal(isDeliveryCandidatePr(pr({ authorId: 1 })), false);
    assert.equal(isDeliveryCandidatePr(pr({ headRepoFullName: "intrus/KassDalle" })), false);
    assert.equal(isDeliveryCandidatePr(null), false);
  });

  test("pull_request : Issues citées, ancien corps compris", () => {
    assert.deepEqual(
      deliveryRefreshFromEvent("pull_request", {
        action: "edited",
        repository,
        pull_request: candidate({ number: 57, body: "Closes #42" }),
        changes: { body: { from: "Closes #41" } },
      }),
      { issueNumbers: [41, 42], prNumbers: [] },
    );
    assert.deepEqual(
      deliveryRefreshFromEvent("pull_request", {
        action: "synchronize",
        repository,
        pull_request: candidate({ number: 57, body: "Closes #42" }),
      }),
      { issueNumbers: [42], prNumbers: [] },
    );
    assert.equal(
      deliveryRefreshFromEvent("pull_request", {
        action: "labeled",
        repository,
        pull_request: candidate({ number: 57, body: "Closes #42" }),
      }),
      null,
    );
    assert.equal(
      deliveryRefreshFromEvent("pull_request", {
        action: "closed",
        repository,
        pull_request: candidate({ number: 57, body: "Rien" }),
      }),
      null,
    );
  });

  test("workflow_run du workflow CI (départ, exécution, fin) : ses PR", () => {
    for (const action of ["requested", "in_progress"]) {
      assert.deepEqual(
        deliveryRefreshFromEvent("workflow_run", {
          action,
          repository,
          workflow_run: { name: "CI", pull_requests: [{ number: 57 }] },
        }),
        { issueNumbers: [], prNumbers: [57] },
        action,
      );
    }
    assert.deepEqual(
      deliveryRefreshFromEvent("workflow_run", {
        action: "completed",
        repository,
        workflow_run: { name: "CI", pull_requests: [{ number: 58 }, { number: 57 }, {}] },
      }),
      { issueNumbers: [], prNumbers: [57, 58] },
    );
    for (const payload of [
      {
        action: "requested",
        workflow_run: { name: "Déploiement", pull_requests: [{ number: 57 }] },
      },
      {
        action: "completed",
        workflow_run: { name: "Déploiement", pull_requests: [{ number: 57 }] },
      },
      { action: "completed", workflow_run: { name: "CI", pull_requests: [] } },
    ]) {
      assert.equal(deliveryRefreshFromEvent("workflow_run", { ...payload, repository }), null);
    }
  });

  test("autre dépôt : rien", () => {
    assert.equal(
      deliveryRefreshFromEvent("pull_request", {
        action: "opened",
        repository: { full_name: "autre/depot" },
        pull_request: candidate({ number: 1, body: "Closes #42" }),
      }),
      null,
    );
  });
});

describe("403 de GitHub : limite secondaire ou jeton", () => {
  test("une limite secondaire n'est pas un jeton refusé", () => {
    assert.equal(classifyGithubFailure(403, "12", false, { retryAfter: "60" }), "rate_limit");
    assert.equal(
      classifyGithubFailure(403, null, false, {
        message: "You have exceeded a secondary rate limit.",
      }),
      "rate_limit",
    );
    assert.equal(classifyGithubFailure(403, "0", false), "rate_limit");
    assert.equal(
      classifyGithubFailure(403, "12", false, { retryAfter: " ", message: "Bad credentials" }),
      "token",
    );
    assert.equal(classifyGithubFailure(403, null, false), "token");
  });
});

describe("PR de livraison d'un ticket livré", () => {
  const REPO = "ChinaFred/KassDalle";
  const MAINTAINER = 16348852;
  const pr = (over: Partial<MergedPrCandidate>): MergedPrCandidate => ({
    number: 57,
    mergedAt: "2026-10-15T20:00:00Z",
    body: "Closes #91",
    htmlUrl: `https://github.com/${REPO}/pull/57`,
    baseRepoFullName: REPO,
    authorId: MAINTAINER,
    authorAssociation: "OWNER",
    ...over,
  });

  test("commit de fermeture : dernier événement closed avec commit_id", () => {
    assert.equal(
      closingCommitFromEvents([
        { event: "closed", commit_id: "aaaaaaa", created_at: "2026-10-01T00:00:00Z" },
        { event: "reopened", created_at: "2026-10-02T00:00:00Z" },
        { event: "closed", commit_id: "bbbbbbb", created_at: "2026-10-03T00:00:00Z" },
      ]),
      "bbbbbbb",
    );
  });

  test("commit de fermeture : fermée à la main ou valeur illisible, pas de commit", () => {
    assert.equal(closingCommitFromEvents([{ event: "closed", commit_id: null }]), null);
    assert.equal(closingCommitFromEvents([{ event: "closed", commit_id: "../x" }]), null);
    assert.equal(closingCommitFromEvents([null, "x", { event: "labeled" }]), null);
    assert.equal(closingCommitFromEvents([]), null);
  });

  test("la PR fusionnée qui ferme l'Issue est retenue", () => {
    assert.deepEqual(pickDeliveredPr([pr({})], 91, MAINTAINER, REPO), {
      number: 57,
      url: `https://github.com/${REPO}/pull/57`,
    });
  });

  test("plusieurs PR fusionnées : la dernière", () => {
    const picked = pickDeliveredPr(
      [
        pr({ number: 50, mergedAt: "2026-10-10T00:00:00Z" }),
        pr({ number: 60, mergedAt: "2026-10-14T00:00:00Z" }),
        pr({ number: 55, mergedAt: "2026-10-12T00:00:00Z" }),
      ],
      91,
      MAINTAINER,
      REPO,
    );
    assert.equal(picked?.number, 60);
  });

  test("PR non fusionnée, d'un autre dépôt, d'un tiers ou d'une autre Issue : écartée", () => {
    assert.equal(pickDeliveredPr([pr({ mergedAt: null })], 91, MAINTAINER, REPO), null);
    assert.equal(
      pickDeliveredPr([pr({ baseRepoFullName: "autre/depot" })], 91, MAINTAINER, REPO),
      null,
    );
    assert.equal(
      pickDeliveredPr([pr({ authorId: 1, authorAssociation: "NONE" })], 91, MAINTAINER, REPO),
      null,
    );
    assert.equal(pickDeliveredPr([pr({ body: "Closes #92" })], 91, MAINTAINER, REPO), null);
    assert.equal(pickDeliveredPr([], 91, MAINTAINER, REPO), null);
  });

  test("adresse hors du dépôt : reconstruite depuis le numéro", () => {
    assert.equal(
      pickDeliveredPr([pr({ htmlUrl: "https://evil.example/pull/57" })], 91, MAINTAINER, REPO)?.url,
      `https://github.com/${REPO}/pull/57`,
    );
  });

  test("événement issues closed : numéro de l'Issue, sinon rien", () => {
    const base = {
      action: "closed",
      repository: { full_name: REPO },
      issue: { number: 91 },
    };
    assert.equal(closedIssueFromEvent("issues", base), 91);
    assert.equal(closedIssueFromEvent("issues", { ...base, action: "opened" }), null);
    assert.equal(closedIssueFromEvent("pull_request", base), null);
    assert.equal(
      closedIssueFromEvent("issues", { ...base, repository: { full_name: "autre/depot" } }),
      null,
    );
    assert.equal(
      closedIssueFromEvent("issues", { ...base, issue: { number: 91, pull_request: {} } }),
      null,
    );
  });
});

describe("version lue dans pubspec.yaml", () => {
  test("version sans numéro de build", () => {
    assert.equal(pubspecVersionName("name: x\nversion: 0.23.80+427\n"), "0.23.80");
    assert.equal(pubspecVersionName("version: 1.2.3\r\nenv:\n"), "1.2.3");
  });

  test("version absente ou mal formée", () => {
    assert.equal(pubspecVersionName("name: x\n"), null);
    assert.equal(pubspecVersionName("version: latest\n"), null);
    assert.equal(pubspecVersionName("  version: 0.1.2\n"), null);
  });
});
