/**
 * Client minimal de l'API des Routines Claude Code, par `fetch` — aucun SDK.
 *
 * Un seul appel : `POST /v1/claude_code/routines/{id}/fire`, corps
 * `{"text": "analyse #N"}` ou `{"text": "developpement #N"}`. L'API n'est pas
 * idempotente : un appel n'est jamais rejoué, ni ici ni par l'appelant.
 *
 * L'identifiant et le jeton de chaque routine viennent de Secret Manager
 * (`TICKETS_ROUTINE_ANALYSIS_ID` / `_TOKEN`, `TICKETS_ROUTINE_DEV_ID` /
 * `_TOKEN`), lus dans `process.env` une fois les secrets attachés. Le jeton
 * ne figure dans aucun message, aucun journal, aucune erreur rendue.
 *
 * Aucun appel de modèle n'est facturé au projet : la session tourne sur
 * l'abonnement Claude de l'administrateur. Pas de poste d'IA, pas de
 * `ctx.feature`.
 */

import { LAUNCH_TEXT_PATTERN, type LaunchAction } from "./rules";

const API = "https://api.anthropic.com/v1/claude_code/routines";
const ANTHROPIC_VERSION = "2023-06-01";

/** Délai d'un lancement. Au-delà, le résultat est inconnu. */
export const ROUTINE_TIMEOUT_MS = 30_000;

/** Longueur gardée d'une URL ou d'un identifiant de session rendu par l'API. */
const SESSION_FIELD_MAX = 500;

/** Variables d'environnement des secrets, par routine. */
export const ROUTINE_ENV: Record<LaunchAction, { id: string; token: string }> = {
  analyse: { id: "TICKETS_ROUTINE_ANALYSIS_ID", token: "TICKETS_ROUTINE_ANALYSIS_TOKEN" },
  developpement: { id: "TICKETS_ROUTINE_DEV_ID", token: "TICKETS_ROUTINE_DEV_TOKEN" },
};

export interface RoutineConfig {
  id: string;
  token: string;
}

/**
 * L'identifiant et le jeton d'une routine, ou `null` si l'un manque, est vide,
 * ou si l'identifiant n'a pas la forme d'un segment d'URL sûr.
 */
export function routineConfig(
  action: LaunchAction,
  env: Record<string, string | undefined> = process.env,
): RoutineConfig | null {
  const id = (env[ROUTINE_ENV[action].id] ?? "").trim();
  const token = (env[ROUTINE_ENV[action].token] ?? "").trim();
  if (id.length === 0 || token.length === 0) return null;
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(id)) return null;
  return { id, token };
}

/**
 * - `paused` : 400, routine en pause sur claude.ai ;
 * - `rejected` : 400 pour une autre raison (texte refusé), ou tout statut
 *   non prévu ;
 * - `token` : 401 ou 403 ;
 * - `not_found` : 404, routine introuvable ;
 * - `rate_limit` : 429.
 *
 * Un 5xx n'est pas un échec : la session a pu partir, le résultat est
 * `unknown` (comme un délai dépassé).
 */
export type RoutineFailureKind = "paused" | "rejected" | "token" | "not_found" | "rate_limit";

export type FireOutcome =
  | {
      kind: "launched";
      sessionId: string | null;
      sessionUrl: string | null;
      /** Réponse 2xx dont le corps ne se lit pas : la raison, pour le journal. */
      note: string | null;
    }
  | {
      kind: "failed";
      failure: RoutineFailureKind;
      status: number;
      /** Minutes à attendre, arrondies au-dessus (429 seulement). */
      retryMinutes: number | null;
      /** Extrait du corps de la réponse, pour le journal. Jamais le jeton. */
      detail: string;
    }
  | {
      kind: "unknown";
      /** Statut HTTP d'une réponse 5xx ; `null` sans réponse (délai, réseau). */
      status: number | null;
      detail: string;
    };

/** Message d'un 5xx, rendu à l'administrateur comme un résultat inconnu. */
export const ROUTINE_SERVER_ERROR_MESSAGE =
  "Claude ne répond pas. Vérifiez sur claude.ai/code avant de relancer.";

/**
 * Minutes annoncées par `Retry-After` (secondes ou date HTTP), arrondies à la
 * minute supérieure, au moins 1. `null` si l'en-tête manque ou ne se lit pas.
 * Pure.
 */
export function retryAfterMinutes(header: string | null, nowMs: number): number | null {
  if (header === null) return null;
  const text = header.trim();
  if (text.length === 0) return null;
  let seconds: number;
  if (/^\d+$/.test(text)) {
    seconds = Number(text);
  } else {
    const at = Date.parse(text);
    if (Number.isNaN(at)) return null;
    seconds = (at - nowMs) / 1000;
  }
  return Math.max(1, Math.ceil(seconds / 60));
}

function excerpt(body: string): string {
  return body.replace(/\s+/g, " ").trim().slice(0, 300);
}

function sessionField(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 && value.length <= SESSION_FIELD_MAX
    ? value
    : null;
}

/** Une réponse 400 qui dit que la routine est en pause. */
function isPausedBody(body: string): boolean {
  return /\bpause/i.test(body);
}

/** Classe une réponse de l'API. Pure, testée. */
export function classifyRoutineResponse(
  status: number,
  body: string,
  retryAfterHeader: string | null,
  nowMs: number,
): FireOutcome {
  if (status >= 200 && status < 300) {
    let parsed: Record<string, unknown> = {};
    let note: string | null = null;
    try {
      const json: unknown = JSON.parse(body);
      if (json !== null && typeof json === "object") parsed = json as Record<string, unknown>;
    } catch (err) {
      // La session est créée (2xx) : seul le lien manque. L'appelant
      // l'enregistre sans lien et journalise `note`.
      note = `corps illisible : ${err instanceof Error ? err.message : String(err)}`;
    }
    return {
      kind: "launched",
      sessionId: sessionField(parsed.claude_code_session_id),
      sessionUrl: sessionField(parsed.claude_code_session_url),
      note,
    };
  }
  const detail = excerpt(body);
  const failed = (
    failure: RoutineFailureKind,
    retryMinutes: number | null = null,
  ): FireOutcome => ({
    kind: "failed",
    failure,
    status,
    retryMinutes,
    detail,
  });
  if (status === 400) return failed(isPausedBody(body) ? "paused" : "rejected");
  if (status === 401 || status === 403) return failed("token");
  if (status === 404) return failed("not_found");
  if (status === 429) return failed("rate_limit", retryAfterMinutes(retryAfterHeader, nowMs));
  // 500, 503 et tout 5xx : la session a pu être créée avant l'erreur.
  if (status >= 500) return { kind: "unknown", status, detail };
  return failed("rejected");
}

/** Message rendu à l'administrateur pour un échec de l'API. */
export function routineFailureMessage(
  failure: RoutineFailureKind,
  retryMinutes: number | null,
): string {
  switch (failure) {
    case "paused":
      return "La routine est en pause sur claude.ai. Réactivez-la, puis relancez.";
    case "token":
      return "Le jeton de la routine est refusé. Remplacez-le dans Secret Manager.";
    case "not_found":
      return "Routine introuvable : vérifiez son identifiant dans Secret Manager.";
    case "rate_limit":
      return retryMinutes === null
        ? "Trop de lancements chez Claude. Réessayez plus tard."
        : `Trop de lancements chez Claude. Réessayez dans ${retryMinutes} min.`;
    case "rejected":
      return "Lancement refusé par Claude.";
  }
}

/**
 * Vrai pour l'échec que `fetch` lève sur une réponse 3xx avec
 * `redirect: "error"` (undici : `TypeError`, cause « unexpected redirect »).
 * Pure, testée.
 */
export function isRedirectError(err: unknown): boolean {
  if (!(err instanceof Error)) return false;
  const cause = (err as Error & { cause?: unknown }).cause;
  const text = `${err.message} ${cause instanceof Error ? cause.message : String(cause ?? "")}`;
  return /redirect/i.test(text);
}

/**
 * Lance la routine avec `text`. Ne lève pas : un délai dépassé ou une panne
 * réseau rendent `unknown` (la session a pu partir), une réponse rend
 * `launched` ou `failed`. Une redirection (3xx) est refusée sans être
 * suivie et rend `failed` (`rejected`). Le texte est revérifié contre `LAUNCH_TEXT_PATTERN`.
 */
export async function fireRoutine(
  config: RoutineConfig,
  text: string,
  opts: { timeoutMs?: number; fetchImpl?: typeof fetch; nowMs?: () => number } = {},
): Promise<FireOutcome> {
  if (!LAUNCH_TEXT_PATTERN.test(text)) {
    throw new Error(`texte de lancement refusé : ${JSON.stringify(text)}`);
  }
  const doFetch = opts.fetchImpl ?? fetch;
  const now = opts.nowMs ?? Date.now;
  let response: Response;
  try {
    response = await doFetch(`${API}/${encodeURIComponent(config.id)}/fire`, {
      method: "POST",
      headers: {
        authorization: `Bearer ${config.token}`,
        "anthropic-version": ANTHROPIC_VERSION,
        "content-type": "application/json",
      },
      body: JSON.stringify({ text }),
      // Une redirection n'est jamais suivie : elle renverrait le jeton
      // Bearer vers une autre adresse.
      redirect: "error",
      signal: AbortSignal.timeout(opts.timeoutMs ?? ROUTINE_TIMEOUT_MS),
    });
  } catch (err) {
    if (isRedirectError(err)) {
      // Le serveur a répondu (3xx) : rien n'est parti vers la routine.
      return {
        kind: "failed",
        failure: "rejected",
        status: 0,
        retryMinutes: null,
        detail: "redirection refusée (3xx), jeton non transmis",
      };
    }
    const name = err instanceof Error ? err.name : "";
    const message = err instanceof Error ? err.message : String(err);
    return {
      kind: "unknown",
      status: null,
      detail: name === "TimeoutError" || name === "AbortError" ? `délai dépassé` : message,
    };
  }
  let body: string;
  try {
    body = await response.text();
  } catch (err) {
    // Statut reçu, corps perdu : le statut décide seul. Un succès reste un
    // succès, sans lien ; la raison part dans `note` ou `detail`.
    body = `corps illisible : ${err instanceof Error ? err.message : String(err)}`;
  }
  return classifyRoutineResponse(response.status, body, response.headers.get("retry-after"), now());
}
