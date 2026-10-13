/**
 * Client REST GitHub minimal des tickets, par `fetch` — aucun SDK.
 *
 * Cinq appels : créer une Issue, lire une Issue, lire ses commentaires, lire
 * sa chronologie (PR qui la référencent), chercher une Issue par la référence
 * d'un ticket. Le jeton vient de `process.env.GITHUB_TICKETS_TOKEN`, peuplé par
 * le secret du même nom une fois attaché ; absent, `githubToken()` rend `null`.
 *
 * Chaque échec lève une `GithubError` classée (`kind`) : l'appelant distingue
 * un jeton refusé — signalé à l'administrateur par un bandeau — d'une panne
 * passagère. Le message ne contient jamais le jeton.
 */

import { GITHUB_TICKETS_MAINTAINER_ID, GITHUB_TICKETS_OWNER, GITHUB_TICKETS_REPO } from "../config";
import { isTrustedPrAuthor } from "./rules";

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

/** Classe une réponse en échec. Pure, testée. */
export function classifyGithubFailure(
  status: number,
  rateLimitRemaining: string | null,
  repoLevel: boolean,
): GithubErrorKind {
  if (status === 401) return "token";
  if (status === 429) return "rate_limit";
  if (status === 403) return rateLimitRemaining === "0" ? "rate_limit" : "token";
  if (status === 404) return repoLevel ? "token" : "not_found";
  return "other";
}

async function request<T>(
  token: string,
  method: "GET" | "POST",
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
  /** Identifiant numérique du compte auteur (`user.id`), ou `null`. */
  authorId: number | null;
  body: string | null;
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
    for (const c of batch) {
      const user = c.user as { id?: unknown } | null | undefined;
      out.push({
        authorId: typeof user?.id === "number" ? user.id : null,
        body: typeof c.body === "string" ? c.body : null,
      });
    }
    if (batch.length < 100) break;
  }
  return out;
}

/**
 * Corps des PR **ouvertes** qui mentionnent l'Issue, lus dans sa chronologie
 * (événements `cross-referenced`). L'appelant y cherche « Closes #N ».
 *
 * Seules les PR d'un auteur de confiance sont rendues (`isTrustedPrAuthor`) :
 * une PR ouverte depuis un fork par un autre compte ne fait pas passer un
 * ticket « En cours ».
 */
export async function openPullRequestBodiesReferencing(
  token: string,
  issueNumber: number,
): Promise<string[]> {
  const bodies: string[] = [];
  for (let page = 1; page <= MAX_PAGES; page++) {
    const batch = await request<Array<Record<string, unknown>>>(
      token,
      "GET",
      `${REPO_PATH}/issues/${issueNumber}/timeline?per_page=100&page=${page}`,
    );
    for (const event of batch) {
      if (event.event !== "cross-referenced") continue;
      const source = event.source as { issue?: Record<string, unknown> } | undefined;
      const issue = source?.issue;
      if (!issue || issue.pull_request == null || issue.state !== "open") continue;
      const repo = issue.repository as { full_name?: unknown } | undefined;
      if (
        typeof repo?.full_name === "string" &&
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
    if (batch.length < 100) break;
  }
  return bodies;
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
