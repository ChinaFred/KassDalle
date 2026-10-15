/**
 * Client REST GitHub minimal des tickets, par `fetch` — aucun SDK.
 *
 * Quatorze appels : créer une Issue, lire une Issue, lire ses commentaires,
 * lire sa chronologie (PR qui la référencent), lire ses événements (dernier
 * « validé » du mainteneur), chercher
 * une Issue par la référence d'un ticket, et pour les décisions de
 * l'administrateur : poser une étiquette, retirer une étiquette, publier un
 * commentaire, fermer une Issue « not planned ». Pour « Livrer » : lister les
 * PR ouvertes, lire une PR, lister ses fichiers, lister les runs GitHub
 * Actions d'un commit (permission « Actions : lecture »). Le jeton vient de
 * `process.env.GITHUB_TICKETS_TOKEN`, peuplé par le secret du même nom une
 * fois attaché ; absent, `githubToken()` rend `null`.
 *
 * Chaque échec lève une `GithubError` classée (`kind`) : l'appelant distingue
 * un jeton refusé — signalé à l'administrateur par un bandeau — d'une panne
 * passagère. Le message ne contient jamais le jeton.
 */

import { GITHUB_TICKETS_MAINTAINER_ID, GITHUB_TICKETS_OWNER, GITHUB_TICKETS_REPO } from "../config";
import {
  closingCommitFromEvents,
  isTrustedPrAuthor,
  lastMaintainerValidatedAt,
  pickDeliveredPr,
  type CiRunView,
  type MergedPrCandidate,
  type PullRequestFileView,
  type PullRequestView,
} from "./rules";

const API = "https://api.github.com";
const TIMEOUT_MS = 15_000;
const USER_AGENT = "KassDalle-Tickets (https://kassdale-6d948.web.app)";

export const GITHUB_REPO_FULL_NAME = `${GITHUB_TICKETS_OWNER}/${GITHUB_TICKETS_REPO}`;

/**
 * - `token` : jeton absent, refusé (401) ou sans droit sur le dépôt (403 hors
 *   limite de débit, 404 sur le dépôt lui-même) ;
 * - `rate_limit` : limite de débit (403 avec quota épuisé, 429) ;
 * - `not_found` : ressource absente (Issue supprimée) ;
 * - `network` : délai dépassé, connexion refusée ;
 * - `other` : toute autre réponse.
 */
export type GithubErrorKind = "token" | "rate_limit" | "not_found" | "network" | "other";

export class GithubError extends Error {
  constructor(
    readonly kind: GithubErrorKind,
    readonly status: number | null,
    message: string,
  ) {
    super(message);
  }
}

/** Le jeton des tickets, ou `null` s'il n'est pas posé. */
export function githubToken(): string | null {
  const token = (process.env.GITHUB_TICKETS_TOKEN ?? "").trim();
  return token.length > 0 ? token : null;
}

/**
 * Classe une réponse en échec. Pure, testée.
 *
 * Un 403 est une limite de débit, et non un jeton refusé, quand le quota est
 * épuisé (`x-ratelimit-remaining: 0`), quand GitHub annonce un délai
 * (`retry-after`, limite secondaire) ou quand son message parle de
 * « secondary rate limit » : déclarer le jeton invalide arrêterait la tâche
 * horaire et afficherait un faux bandeau.
 */
export function classifyGithubFailure(
  status: number,
  rateLimitRemaining: string | null,
  repoLevel: boolean,
  extra: { retryAfter?: string | null; message?: string | null } = {},
): GithubErrorKind {
  if (status === 401) return "token";
  if (status === 429) return "rate_limit";
  if (status === 403) {
    const secondary =
      (typeof extra.retryAfter === "string" && extra.retryAfter.trim().length > 0) ||
      /secondary rate limit/i.test(extra.message ?? "");
    return rateLimitRemaining === "0" || secondary ? "rate_limit" : "token";
  }
  if (status === 404) return repoLevel ? "token" : "not_found";
  return "other";
}

async function request<T>(
  token: string,
  method: "GET" | "POST" | "PATCH" | "DELETE",
  path: string,
  opts: { body?: unknown; repoLevel?: boolean } = {},
): Promise<T> {
  let response: Response;
  try {
    response = await fetch(`${API}${path}`, {
      method,
      headers: {
        accept: "application/vnd.github+json",
        authorization: `Bearer ${token}`,
        "x-github-api-version": "2022-11-28",
        "user-agent": USER_AGENT,
        ...(opts.body !== undefined ? { "content-type": "application/json" } : {}),
      },
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
  } catch (err) {
    throw new GithubError(
      "network",
      null,
      `GitHub injoignable : ${err instanceof Error ? err.message : String(err)}`.slice(0, 300),
    );
  }
  if (!response.ok) {
    let detail = "";
    try {
      const json = (await response.json()) as { message?: unknown };
      detail = typeof json.message === "string" ? json.message : "";
    } catch (parseErr) {
      detail = `réponse illisible (${parseErr instanceof Error ? parseErr.message : "?"})`;
    }
    const kind = classifyGithubFailure(
      response.status,
      response.headers.get("x-ratelimit-remaining"),
      opts.repoLevel === true,
      { retryAfter: response.headers.get("retry-after"), message: detail },
    );
    throw new GithubError(
      kind,
      response.status,
      `GitHub HTTP ${response.status}${detail ? ` : ${detail}` : ""}`.slice(0, 300),
    );
  }
  return (await response.json()) as T;
}

const REPO_PATH = `/repos/${GITHUB_TICKETS_OWNER}/${GITHUB_TICKETS_REPO}`;

export interface CreatedIssue {
  number: number;
  url: string;
}

/** Crée l'Issue. Un 404 vise le dépôt : jeton sans accès, classé `token`. */
export async function createIssue(
  token: string,
  issue: { title: string; body: string; labels: string[] },
): Promise<CreatedIssue> {
  const created = await request<{ number: number; html_url: string }>(
    token,
    "POST",
    `${REPO_PATH}/issues`,
    { body: issue, repoLevel: true },
  );
  return { number: created.number, url: created.html_url };
}

export interface RemoteIssue {
  state: "open" | "closed";
  stateReason: string | null;
  labels: string[];
  isPullRequest: boolean;
  /** Dernière modification de l'Issue (horodatage ISO de GitHub), ou `null`. */
  updatedAt: string | null;
}

/** Noms des étiquettes d'une Issue, qu'elles arrivent en objets ou en chaînes. */
export function labelNames(labels: unknown): string[] {
  if (!Array.isArray(labels)) return [];
  return labels
    .map((l) => (typeof l === "string" ? l : (l as { name?: unknown } | null)?.name))
    .filter((n): n is string => typeof n === "string");
}

/** Lit une Issue de la forme rendue par l'API ou par un webhook. Pure. */
export function readRemoteIssue(raw: Record<string, unknown>): RemoteIssue {
  return {
    state: raw.state === "closed" ? "closed" : "open",
    stateReason: typeof raw.state_reason === "string" ? raw.state_reason : null,
    labels: labelNames(raw.labels),
    isPullRequest: raw.pull_request != null,
    updatedAt: typeof raw.updated_at === "string" ? raw.updated_at : null,
  };
}

export async function getIssue(token: string, issueNumber: number): Promise<RemoteIssue> {
  const raw = await request<Record<string, unknown>>(
    token,
    "GET",
    `${REPO_PATH}/issues/${issueNumber}`,
  );
  return readRemoteIssue(raw);
}

export interface RemoteComment {
  /** Identifiant numérique du commentaire, ou `null`. */
  id: number | null;
  /** Identifiant numérique du compte auteur (`user.id`), ou `null`. */
  authorId: number | null;
  body: string | null;
  /** Horodatages ISO de GitHub, ou `null`. */
  createdAt: string | null;
  updatedAt: string | null;
}

/** Lit un commentaire de la forme rendue par l'API ou par un webhook. Pure. */
export function readRemoteComment(raw: Record<string, unknown>): RemoteComment {
  const user = raw.user as { id?: unknown } | null | undefined;
  return {
    id: typeof raw.id === "number" ? raw.id : null,
    authorId: typeof user?.id === "number" ? user.id : null,
    body: typeof raw.body === "string" ? raw.body : null,
    createdAt: typeof raw.created_at === "string" ? raw.created_at : null,
    updatedAt: typeof raw.updated_at === "string" ? raw.updated_at : null,
  };
}

const MAX_PAGES = 5;

/** Commentaires d'une Issue, du plus ancien au plus récent (500 au plus). */
export async function listIssueComments(
  token: string,
  issueNumber: number,
): Promise<RemoteComment[]> {
  const out: RemoteComment[] = [];
  for (let page = 1; page <= MAX_PAGES; page++) {
    const batch = await request<Array<Record<string, unknown>>>(
      token,
      "GET",
      `${REPO_PATH}/issues/${issueNumber}/comments?per_page=100&page=${page}`,
    );
    for (const c of batch) out.push(readRemoteComment(c));
    if (batch.length < 100) break;
  }
  return out;
}

/** Pose des étiquettes sur une Issue (les autres restent). */
export async function addIssueLabels(
  token: string,
  issueNumber: number,
  labels: string[],
): Promise<string[]> {
  const result = await request<unknown>(
    token,
    "POST",
    `${REPO_PATH}/issues/${issueNumber}/labels`,
    { body: { labels } },
  );
  return labelNames(result);
}

/**
 * Retire une étiquette d'une Issue. Rend `removed`, ou `absent` quand GitHub
 * répond 404 (étiquette déjà retirée) : le résultat voulu est atteint, et
 * l'appelant le journalise avec le numéro d'Issue et l'étiquette.
 */
export async function removeIssueLabel(
  token: string,
  issueNumber: number,
  label: string,
): Promise<"removed" | "absent"> {
  try {
    await request<unknown>(
      token,
      "DELETE",
      `${REPO_PATH}/issues/${issueNumber}/labels/${encodeURIComponent(label)}`,
    );
    return "removed";
  } catch (err) {
    if (err instanceof GithubError && err.kind === "not_found") return "absent";
    throw err;
  }
}

/** Publie un commentaire sur une Issue. Rend son identifiant. */
export async function createIssueComment(
  token: string,
  issueNumber: number,
  body: string,
): Promise<RemoteComment> {
  const raw = await request<Record<string, unknown>>(
    token,
    "POST",
    `${REPO_PATH}/issues/${issueNumber}/comments`,
    { body: { body } },
  );
  return readRemoteComment(raw);
}

/** Ferme une Issue avec la raison `not_planned` (refus). Rend l'Issue relue. */
export async function closeIssueNotPlanned(
  token: string,
  issueNumber: number,
): Promise<RemoteIssue> {
  const raw = await request<Record<string, unknown>>(
    token,
    "PATCH",
    `${REPO_PATH}/issues/${issueNumber}`,
    { body: { state: "closed", state_reason: "not_planned" } },
  );
  return readRemoteIssue(raw);
}

/**
 * Corps des PR **ouvertes** qui mentionnent l'Issue, lus dans sa chronologie
 * (événements `cross-referenced`). L'appelant y cherche « Closes #N ».
 *
 * Seules les PR d'un auteur de confiance sont rendues (`isTrustedPrAuthor`) :
 * une PR ouverte depuis un fork par un autre compte ne fait pas passer un
 * ticket « En cours ». Une PR dont le dépôt n'est pas lisible est écartée.
 *
 * `complete` est faux quand la chronologie dépasse `MAX_PAGES` pages : des
 * tiers peuvent la remplir de commentaires et de renvois, et la PR peut se
 * trouver après la coupure. L'appelant ne conclut alors à aucune absence.
 */
export async function openPullRequestBodiesReferencing(
  token: string,
  issueNumber: number,
): Promise<{ bodies: string[]; complete: boolean }> {
  return collectOpenPrBodies((page) =>
    request<Array<Record<string, unknown>>>(
      token,
      "GET",
      `${REPO_PATH}/issues/${issueNumber}/timeline?per_page=100&page=${page}`,
    ),
  );
}

/**
 * Parcourt les pages de chronologie rendues par `fetchPage` (1 à `MAX_PAGES`)
 * et garde le corps des PR ouvertes de ce dépôt, d'un auteur de confiance.
 * `complete` ne vaut vrai que si une page de moins de 100 événements a été lue.
 */
export async function collectOpenPrBodies(
  fetchPage: (page: number) => Promise<Array<Record<string, unknown>>>,
): Promise<{ bodies: string[]; complete: boolean }> {
  const bodies: string[] = [];
  let complete = false;
  for (let page = 1; page <= MAX_PAGES; page++) {
    const batch = await fetchPage(page);
    for (const event of batch) {
      if (event.event !== "cross-referenced") continue;
      const source = event.source as { issue?: Record<string, unknown> } | undefined;
      const issue = source?.issue;
      if (!issue || issue.pull_request == null || issue.state !== "open") continue;
      const repo = issue.repository as { full_name?: unknown } | undefined;
      if (
        typeof repo?.full_name !== "string" ||
        repo.full_name.toLowerCase() !== GITHUB_REPO_FULL_NAME.toLowerCase()
      ) {
        continue;
      }
      const user = issue.user as { id?: unknown } | null | undefined;
      const trusted = isTrustedPrAuthor(
        {
          id: typeof user?.id === "number" ? user.id : null,
          association:
            typeof issue.author_association === "string" ? issue.author_association : null,
        },
        GITHUB_TICKETS_MAINTAINER_ID,
      );
      if (trusted && typeof issue.body === "string") bodies.push(issue.body);
    }
    if (batch.length < 100) {
      complete = true;
      break;
    }
  }
  return { bodies, complete };
}

/**
 * Date du dernier `labeled validé` posé par le mainteneur, lue dans les
 * événements de l'Issue (`GET /issues/{n}/events`, 500 au plus — étiquettes,
 * fermetures, renvois, sans les commentaires), ou `null`. Sert à la tâche
 * horaire et, avant un développement, quand la date stockée manque.
 */
export async function lastValidatedLabelAt(
  token: string,
  issueNumber: number,
): Promise<string | null> {
  const events: unknown[] = [];
  for (let page = 1; page <= MAX_PAGES; page++) {
    const batch = await request<unknown[]>(
      token,
      "GET",
      `${REPO_PATH}/issues/${issueNumber}/events?per_page=100&page=${page}`,
    );
    events.push(...batch);
    if (batch.length < 100) break;
  }
  return lastMaintainerValidatedAt(events, GITHUB_TICKETS_MAINTAINER_ID);
}

/**
 * La PR fusionnée qui a fermé l'Issue, ou `null` (fermée à la main, sans PR).
 * Lit les événements de l'Issue pour le commit de fermeture, puis les PR de
 * ce commit (`GET /commits/{sha}/pulls`). Deux appels GitHub au plus.
 */
export async function findDeliveredPullRequest(
  token: string,
  issueNumber: number,
): Promise<{ number: number; url: string } | null> {
  const events: unknown[] = [];
  for (let page = 1; page <= MAX_PAGES; page++) {
    const batch = await request<unknown[]>(
      token,
      "GET",
      `${REPO_PATH}/issues/${issueNumber}/events?per_page=100&page=${page}`,
    );
    events.push(...batch);
    if (batch.length < 100) break;
  }
  const sha = closingCommitFromEvents(events);
  if (sha === null) return null;
  const raw = await request<Array<Record<string, unknown>>>(
    token,
    "GET",
    `${REPO_PATH}/commits/${sha}/pulls?per_page=30`,
  );
  const candidates: MergedPrCandidate[] = [];
  for (const pr of raw) {
    if (typeof pr.number !== "number" || !Number.isSafeInteger(pr.number)) continue;
    const user = pr.user as { id?: unknown } | null | undefined;
    const base = pr.base as { repo?: { full_name?: unknown } | null } | null | undefined;
    candidates.push({
      number: pr.number,
      mergedAt: str(pr.merged_at),
      body: str(pr.body),
      htmlUrl: str(pr.html_url),
      baseRepoFullName: str(base?.repo?.full_name),
      authorId: typeof user?.id === "number" ? user.id : null,
      authorAssociation: str(pr.author_association),
    });
  }
  return pickDeliveredPr(
    candidates,
    issueNumber,
    GITHUB_TICKETS_MAINTAINER_ID,
    GITHUB_REPO_FULL_NAME,
  );
}

/**
 * L'Issue déjà créée pour un ticket, retrouvée par sa référence dans le corps.
 *
 * Sert avant un nouvel essai : si la création a réussi chez GitHub mais que
 * l'écriture du numéro dans Firestore a échoué, réessayer publierait l'Issue
 * deux fois. L'index de recherche de GitHub a quelques minutes de retard ; la
 * reprise est horaire.
 */
export async function findIssueByTicketReference(
  token: string,
  ticketId: string,
): Promise<CreatedIssue | null> {
  const q = `repo:${GITHUB_REPO_FULL_NAME} is:issue in:body "${ticketId}"`;
  const result = await request<{ items?: Array<Record<string, unknown>> }>(
    token,
    "GET",
    `/search/issues?q=${encodeURIComponent(q)}&per_page=10`,
  );
  const marker = `\`${ticketId}\``;
  for (const item of result.items ?? []) {
    if (typeof item.body === "string" && item.body.includes(marker)) {
      const n = item.number;
      const url = item.html_url;
      if (typeof n === "number" && typeof url === "string") return { number: n, url };
    }
  }
  return null;
}

// ── Livraison : pull requests et runs de la CI ──────────────────────────────

function str(value: unknown): string | null {
  return typeof value === "string" ? value : null;
}

/** Lit une PR de la forme rendue par l'API (liste ou détail) ou par un webhook. Pure. */
export function readPullRequest(raw: Record<string, unknown>): PullRequestView | null {
  if (typeof raw.number !== "number" || !Number.isSafeInteger(raw.number)) return null;
  const user = raw.user as { id?: unknown } | null | undefined;
  const head = raw.head as
    { ref?: unknown; sha?: unknown; repo?: { full_name?: unknown } | null } | null | undefined;
  return {
    number: raw.number,
    state: str(raw.state),
    draft: raw.draft === true,
    body: str(raw.body),
    authorId: typeof user?.id === "number" ? user.id : null,
    headRepoFullName: str(head?.repo?.full_name),
    headRef: str(head?.ref),
    headSha: str(head?.sha),
    htmlUrl: str(raw.html_url),
  };
}

/**
 * Les PR ouvertes du dépôt (500 au plus). `complete` est faux quand la
 * dernière page lue était pleine : une PR peut manquer.
 */
export async function listOpenPullRequests(
  token: string,
): Promise<{ prs: PullRequestView[]; complete: boolean }> {
  const prs: PullRequestView[] = [];
  for (let page = 1; page <= MAX_PAGES; page++) {
    const batch = await request<Array<Record<string, unknown>>>(
      token,
      "GET",
      `${REPO_PATH}/pulls?state=open&per_page=100&page=${page}`,
    );
    for (const raw of batch) {
      const pr = readPullRequest(raw);
      if (pr !== null) prs.push(pr);
    }
    if (batch.length < 100) return { prs, complete: true };
  }
  return { prs, complete: false };
}

/** Le détail d'une PR : sa tête du moment et son corps relus. */
export async function getPullRequest(token: string, prNumber: number): Promise<PullRequestView> {
  const raw = await request<Record<string, unknown>>(
    token,
    "GET",
    `${REPO_PATH}/pulls/${prNumber}`,
  );
  const pr = readPullRequest(raw);
  if (pr === null) throw new GithubError("other", null, `PR #${prNumber} illisible`);
  return pr;
}

/** Pages de fichiers lues au plus pour une PR (100 par page). */
const MAX_FILE_PAGES = 10;

/**
 * Les fichiers modifiés par une PR (1 000 au plus). `complete` est faux quand
 * la dernière page lue était pleine : la liste n'est pas vérifiable.
 */
export async function listPullRequestFiles(
  token: string,
  prNumber: number,
): Promise<{ files: PullRequestFileView[]; complete: boolean }> {
  const files: PullRequestFileView[] = [];
  for (let page = 1; page <= MAX_FILE_PAGES; page++) {
    const batch = await request<Array<Record<string, unknown>>>(
      token,
      "GET",
      `${REPO_PATH}/pulls/${prNumber}/files?per_page=100&page=${page}`,
    );
    for (const f of batch) {
      files.push({ filename: str(f.filename), previousFilename: str(f.previous_filename) });
    }
    if (batch.length < 100) return { files, complete: true };
  }
  return { files, complete: false };
}

/** Lit un run de workflow de la forme rendue par l'API ou par un webhook. Pure. */
export function readCiRun(raw: Record<string, unknown>): CiRunView {
  return {
    id: typeof raw.id === "number" ? raw.id : null,
    name: str(raw.name),
    headSha: str(raw.head_sha),
    status: str(raw.status),
    conclusion: str(raw.conclusion),
    createdAt: str(raw.created_at),
    updatedAt: str(raw.updated_at),
  };
}

/**
 * Les runs GitHub Actions d'un commit (`GET /actions/runs?head_sha=`, 100 au
 * plus : un commit n'en a que quelques-uns). Demande la permission
 * « Actions : lecture » du jeton.
 */
export async function listRunsForCommit(token: string, headSha: string): Promise<CiRunView[]> {
  if (!/^[0-9a-f]{40}$/i.test(headSha)) {
    throw new GithubError("other", null, `SHA de commit illisible : ${headSha.slice(0, 64)}`);
  }
  let raw: { workflow_runs?: unknown };
  try {
    raw = await request<{ workflow_runs?: unknown }>(
      token,
      "GET",
      `${REPO_PATH}/actions/runs?head_sha=${headSha}&per_page=100`,
    );
  } catch (err) {
    // Un 403 ici dit le plus souvent que la permission « Actions » manque au
    // jeton, qui sert par ailleurs : il n'est pas déclaré invalide pour autant.
    if (err instanceof GithubError && err.kind === "token" && err.status === 403) {
      throw new GithubError(
        "other",
        403,
        "GitHub refuse la lecture des runs de la CI : ajoutez la permission " +
          "« Actions : lecture » au jeton GITHUB_TICKETS_TOKEN.",
      );
    }
    throw err;
  }
  const runs = Array.isArray(raw.workflow_runs) ? raw.workflow_runs : [];
  return runs
    .filter((r): r is Record<string, unknown> => r !== null && typeof r === "object")
    .map(readCiRun);
}
