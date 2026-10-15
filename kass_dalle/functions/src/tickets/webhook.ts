/**
 * `githubTicketWebhook` — retours de statut des Issues, poussés par GitHub.
 *
 * Fonction HTTPS publique (`invoker: "public"`) : GitHub ne présente pas de
 * jeton Google. L'authentification est la signature `X-Hub-Signature-256`,
 * HMAC SHA-256 du corps BRUT sous `GITHUB_WEBHOOK_SECRET`, comparée à temps
 * constant (`verifyGithubSignature`). Corps non signé ou mal signé : 401.
 * Avant tout calcul de HMAC : un corps de plus de 25 Mo (le plafond des
 * livraisons GitHub) rend 413, une requête sans en-tête `X-GitHub-Event` rend
 * 400. Les refus de signature sont journalisés une fois par minute et par
 * instance au plus, avec leur nombre (`SignatureRejectionLog`).
 *
 * Événements traités : `issues` (étiquettes, fermeture, réouverture ; un
 * `labeled validé` du mainteneur écrit aussi `validated_at` dans
 * `tickets/{id}/admin/analysis` ; un état d'Issue antérieur au dernier retour
 * à « Reçu » d'une réponse de l'administrateur est ignoré),
 * `issue_comment` (réponse de l'administrateur ; et pour tout commentaire du
 * mainteneur créé, modifié ou supprimé, relecture des commentaires de l'Issue
 * et réécriture des analyses `tickets/{id}/admin/analysis`), `pull_request` (PR ouverte
 * qui ferme l'Issue → « En cours », si son auteur est le mainteneur ou un
 * `OWNER`, `MEMBER` ou `COLLABORATOR` du dépôt), `ping`. Pour « Livrer » :
 * `pull_request` (ouverte, rouverte, modifiée, prête, repassée en brouillon,
 * poussée, fermée) et `workflow_run` terminé du workflow « CI » relisent
 * l'état « PR prête » des tickets dont l'Issue est citée par un mot-clé de
 * fermeture (`deliveryRefreshFromEvent`, `refreshTicketDelivery`) ; un
 * commentaire du mainteneur relève aussi les comptes rendus
 * `## Livraison — …`. Tout autre événement, une Issue
 * d'un autre dépôt ou une Issue qui ne vient pas de l'application (aucun
 * ticket sous ce numéro) : 200, ignoré.
 *
 * Aucun texte venu de GitHub n'est écrit dans Firestore, hormis `reply_text`
 * filtré (`replyFromComment`) et les analyses du mainteneur
 * (`analysesFromComments`), lisibles par l'administrateur seul. Les statuts
 * sont dérivés des étiquettes et de l'état, jamais d'un texte libre.
 *
 * Relire les commentaires demande le jeton `GITHUB_TICKETS_TOKEN`, monté ici
 * pour cela seul. Jeton absent ou refusé : `token_invalid_since` est posé, la
 * livraison rend 500, et la tâche horaire réécrit les analyses à sa passe.
 *
 * Une panne Firestore rend 500 : GitHub affiche la livraison en échec, et la
 * tâche horaire `ticketsSyncSchedule` rattrape l'état.
 */

import { onRequest } from "firebase-functions/v2/https";

import {
  GITHUB_TICKETS_MAINTAINER_ID,
  GITHUB_TICKETS_TOKEN,
  GITHUB_WEBHOOK_SECRET,
  REGION,
} from "../config";
import { logError, logInfo, logWarn, newCorrelationId } from "../logging";
import { recordDeliveredPr, refreshTicketDelivery, type OpenPullRequests } from "./delivery";
import {
  GITHUB_REPO_FULL_NAME,
  GithubError,
  getPullRequest,
  githubToken,
  listOpenPullRequests,
  readPullRequest,
  readRemoteIssue,
} from "./github";
import {
  CI_WORKFLOW_NAME,
  LABEL_VALIDATED,
  closingIssueNumbers,
  isTrustedPrAuthor,
  replyFromComment,
  statusFromIssue,
  verifyGithubSignature,
  type PullRequestView,
} from "./rules";
import {
  applyGithubUpdate,
  markTokenInvalid,
  refreshTicketComments,
  ticketIdsForIssue,
  updateValidatedAt,
  type GithubUpdate,
} from "./service";

const ISSUE_ACTIONS = new Set(["opened", "edited", "labeled", "unlabeled", "closed", "reopened"]);
const COMMENT_ACTIONS = new Set(["created", "edited", "deleted"]);
const PR_ACTIONS = new Set(["opened", "reopened", "edited", "ready_for_review"]);
/** Actions d'une PR qui changent son état « PR prête » (corps, brouillon, tête, fermeture). */
const DELIVERY_PR_ACTIONS = new Set([
  "opened",
  "reopened",
  "edited",
  "ready_for_review",
  "converted_to_draft",
  "synchronize",
  "closed",
]);

type Payload = Record<string, unknown>;

/** Plafond d'une livraison GitHub : au-delà, le corps est refusé avant le HMAC. */
export const WEBHOOK_MAX_BODY_BYTES = 25 * 1024 * 1024;

/**
 * Échantillonnage des journaux de signature refusée : un relevé par
 * intervalle au plus, qui porte le nombre de refus depuis le précédent. Un
 * envoi massif de requêtes non signées n'écrit qu'une ligne par minute et par
 * instance.
 */
export class SignatureRejectionLog {
  private pending = 0;
  private lastLoggedAt: number | null = null;

  constructor(private readonly intervalMs = 60_000) {}

  /** Compte un refus ; rend le nombre à journaliser, ou `null` s'il faut se taire. */
  record(now: number): number | null {
    this.pending++;
    if (this.lastLoggedAt !== null && now - this.lastLoggedAt < this.intervalMs) return null;
    const count = this.pending;
    this.pending = 0;
    this.lastLoggedAt = now;
    return count;
  }
}

const signatureRejections = new SignatureRejectionLog();
/** Même échantillonnage pour les livraisons refusées faute de secret. */
const missingSecretRejections = new SignatureRejectionLog();

/**
 * Le numéro de l'Issue d'un événement `issues` `closed` de ce dépôt (hors
 * pull request), ou `null`. Le webhook y relève la PR de livraison. Pure.
 */
export function closedIssueFromEvent(event: string, payload: Payload): number | null {
  if (event !== "issues" || payload.action !== "closed") return null;
  const repo = (payload.repository as { full_name?: unknown } | undefined)?.full_name;
  if (typeof repo !== "string" || repo.toLowerCase() !== GITHUB_REPO_FULL_NAME.toLowerCase()) {
    return null;
  }
  const issue = payload.issue as Payload | undefined;
  if (!issue || typeof issue.number !== "number" || issue.pull_request != null) return null;
  return issue.number;
}

/** Les mises à jour qu'un événement propose, par numéro d'Issue. Pure. */
export function updatesFromEvent(
  event: string,
  payload: Payload,
): Array<{ issueNumber: number; update: GithubUpdate }> {
  const repo = (payload.repository as { full_name?: unknown } | undefined)?.full_name;
  if (typeof repo !== "string" || repo.toLowerCase() !== GITHUB_REPO_FULL_NAME.toLowerCase()) {
    return [];
  }
  const action = typeof payload.action === "string" ? payload.action : "";

  if (event === "issues" && ISSUE_ACTIONS.has(action)) {
    const raw = payload.issue as Payload | undefined;
    if (!raw || typeof raw.number !== "number") return [];
    const issue = readRemoteIssue(raw);
    if (issue.isPullRequest) return [];
    return [
      {
        issueNumber: raw.number,
        update: {
          statusFor: (type) => statusFromIssue({ ...issue, hasOpenClosingPr: false }, type),
          issueUpdatedAt: issue.updatedAt,
        },
      },
    ];
  }

  if (event === "issue_comment" && COMMENT_ACTIONS.has(action)) {
    const issue = payload.issue as Payload | undefined;
    const comment = payload.comment as Payload | undefined;
    if (!issue || typeof issue.number !== "number" || issue.pull_request != null || !comment) {
      return [];
    }
    // Un commentaire supprimé ne devient pas la réponse montrée au membre.
    if (action === "deleted") return [];
    const user = comment.user as { id?: unknown } | undefined;
    const reply = replyFromComment(
      {
        authorId: typeof user?.id === "number" ? user.id : null,
        body: typeof comment.body === "string" ? comment.body : null,
      },
      GITHUB_TICKETS_MAINTAINER_ID,
    );
    return reply === null ? [] : [{ issueNumber: issue.number, update: { reply } }];
  }

  if (event === "pull_request" && PR_ACTIONS.has(action)) {
    const pr = payload.pull_request as Payload | undefined;
    if (!pr || pr.state !== "open") return [];
    // Une PR de fork par un compte quelconque ne fait pas passer « En cours ».
    const author = pr.user as { id?: unknown } | undefined;
    const trusted = isTrustedPrAuthor(
      {
        id: typeof author?.id === "number" ? author.id : null,
        association: typeof pr.author_association === "string" ? pr.author_association : null,
      },
      GITHUB_TICKETS_MAINTAINER_ID,
    );
    if (!trusted) return [];
    const body = typeof pr.body === "string" ? pr.body : null;
    return closingIssueNumbers(body, GITHUB_REPO_FULL_NAME).map((issueNumber) => ({
      issueNumber,
      update: { openClosingPr: true },
    }));
  }

  return [];
}

/**
 * Un `validé` posé par le mainteneur : le numéro de l'Issue et l'instant
 * (`issue.updated_at` de GitHub, à défaut `nowIso`), ou `null`. Pure.
 *
 * Seul l'expéditeur `GITHUB_TICKETS_MAINTAINER_ID` compte : c'est le
 * « validé » que la session de développement exige.
 */
export function validatedLabelFromEvent(
  event: string,
  payload: Payload,
  nowIso: string,
): { issueNumber: number; at: string } | null {
  if (event !== "issues" || payload.action !== "labeled") return null;
  const repo = (payload.repository as { full_name?: unknown } | undefined)?.full_name;
  if (typeof repo !== "string" || repo.toLowerCase() !== GITHUB_REPO_FULL_NAME.toLowerCase()) {
    return null;
  }
  const label = payload.label as { name?: unknown } | undefined;
  const sender = payload.sender as { id?: unknown } | undefined;
  const issue = payload.issue as Payload | undefined;
  if (label?.name !== LABEL_VALIDATED || sender?.id !== GITHUB_TICKETS_MAINTAINER_ID) return null;
  if (!issue || typeof issue.number !== "number" || issue.pull_request != null) return null;
  const at =
    typeof issue.updated_at === "string" && !Number.isNaN(Date.parse(issue.updated_at))
      ? issue.updated_at
      : nowIso;
  return { issueNumber: issue.number, at };
}

/**
 * Le numéro de l'Issue dont il faut relire les analyses, ou `null`. Pure.
 *
 * Tout commentaire du mainteneur créé, modifié ou supprimé sur une Issue du
 * dépôt (pas une PR) : une modification peut retirer le titre `## Analyse`,
 * une suppression retire une analyse. Un autre auteur ne déclenche rien.
 */
export function analysisRefreshFromEvent(event: string, payload: Payload): number | null {
  if (event !== "issue_comment") return null;
  const repo = (payload.repository as { full_name?: unknown } | undefined)?.full_name;
  if (typeof repo !== "string" || repo.toLowerCase() !== GITHUB_REPO_FULL_NAME.toLowerCase()) {
    return null;
  }
  const action = typeof payload.action === "string" ? payload.action : "";
  if (!COMMENT_ACTIONS.has(action)) return null;
  const issue = payload.issue as Payload | undefined;
  const comment = payload.comment as Payload | undefined;
  if (!issue || typeof issue.number !== "number" || issue.pull_request != null || !comment) {
    return null;
  }
  const user = comment.user as { id?: unknown } | undefined;
  return user?.id === GITHUB_TICKETS_MAINTAINER_ID ? issue.number : null;
}

/** Issues (ou PR) relues au plus par événement pour « Livrer ». */
export const DELIVERY_EVENT_MAX = 5;

/**
 * Vrai si une PR peut concerner une livraison : tête dans ce dépôt et auteur
 * `GITHUB_TICKETS_MAINTAINER_ID`. Toute autre PR (copie du dépôt, autre
 * compte, même `OWNER` ou `COLLABORATOR`) ne déclenche aucune relecture.
 * La règle « En cours » (`updatesFromEvent`) n'en dépend pas. Pure.
 */
export function isDeliveryCandidatePr(pr: PullRequestView | null): boolean {
  return (
    pr !== null &&
    pr.authorId === GITHUB_TICKETS_MAINTAINER_ID &&
    typeof pr.headRepoFullName === "string" &&
    pr.headRepoFullName.toLowerCase() === GITHUB_REPO_FULL_NAME.toLowerCase()
  );
}

/**
 * Ce qu'un événement demande de relire pour « Livrer », ou `null`. Pure.
 *
 * - `pull_request` (`DELIVERY_PR_ACTIONS`) d'une PR candidate
 *   (`isDeliveryCandidatePr`) : les Issues citées par un mot-clé de fermeture
 *   dans le corps, et dans l'ancien corps d'un `edited` (un renvoi retiré rend
 *   la PR inéligible pour cette Issue). `DELIVERY_EVENT_MAX` au plus.
 * - `workflow_run` `completed` du workflow « CI » : les PR du dépôt qu'il
 *   porte (`workflow_run.pull_requests`, vide pour une copie du dépôt),
 *   `DELIVERY_EVENT_MAX` au plus, dont l'appelant relit le corps et l'auteur.
 */
export function deliveryRefreshFromEvent(
  event: string,
  payload: Payload,
): { issueNumbers: number[]; prNumbers: number[] } | null {
  const repo = (payload.repository as { full_name?: unknown } | undefined)?.full_name;
  if (typeof repo !== "string" || repo.toLowerCase() !== GITHUB_REPO_FULL_NAME.toLowerCase()) {
    return null;
  }
  const action = typeof payload.action === "string" ? payload.action : "";
  if (event === "pull_request" && DELIVERY_PR_ACTIONS.has(action)) {
    const pr = payload.pull_request as Payload | undefined;
    if (!pr || !isDeliveryCandidatePr(readPullRequest(pr))) return null;
    const changes = payload.changes as { body?: { from?: unknown } } | undefined;
    const bodies = [pr.body, changes?.body?.from].filter((b): b is string => typeof b === "string");
    const issues = new Set<number>();
    for (const body of bodies) {
      for (const n of closingIssueNumbers(body, GITHUB_REPO_FULL_NAME)) issues.add(n);
    }
    return issues.size === 0
      ? null
      : {
          issueNumbers: [...issues].sort((a, b) => a - b).slice(0, DELIVERY_EVENT_MAX),
          prNumbers: [],
        };
  }
  if (event === "workflow_run" && action === "completed") {
    const run = payload.workflow_run as Payload | undefined;
    if (!run || run.name !== CI_WORKFLOW_NAME || !Array.isArray(run.pull_requests)) return null;
    const prs = new Set<number>();
    for (const raw of run.pull_requests) {
      const n = (raw as { number?: unknown } | null)?.number;
      if (typeof n === "number" && Number.isSafeInteger(n) && n > 0) prs.add(n);
    }
    return prs.size === 0
      ? null
      : {
          issueNumbers: [],
          prNumbers: [...prs].sort((a, b) => a - b).slice(0, DELIVERY_EVENT_MAX),
        };
  }
  return null;
}

export const githubTicketWebhook = onRequest(
  {
    region: REGION,
    invoker: "public",
    maxInstances: 5,
    timeoutSeconds: 60,
    secrets: [GITHUB_WEBHOOK_SECRET, GITHUB_TICKETS_TOKEN],
  },
  async (req, res) => {
    const correlationId = newCorrelationId("ticket_webhook");
    if (req.method !== "POST") {
      res.status(405).send("Méthode non admise.");
      return;
    }

    const rawBody: Buffer = req.rawBody ?? Buffer.alloc(0);
    const declaredLength = Number(req.get("content-length") ?? 0);
    if (rawBody.length > WEBHOOK_MAX_BODY_BYTES || declaredLength > WEBHOOK_MAX_BODY_BYTES) {
      res.status(413).send("Corps trop volumineux.");
      return;
    }
    const event = req.get("x-github-event") ?? "";
    if (!event) {
      res.status(400).send("En-tête X-GitHub-Event absent.");
      return;
    }

    const secret = (process.env.GITHUB_WEBHOOK_SECRET ?? "").trim();
    if (!secret) {
      const refused = missingSecretRejections.record(Date.now());
      if (refused !== null) {
        await logError({
          message:
            `githubTicketWebhook : secret GITHUB_WEBHOOK_SECRET vide, ${refused} livraison(s) ` +
            "refusée(s) depuis le dernier relevé",
          correlationId,
          feature: "tickets",
        });
      }
      res.status(503).send("Webhook non configuré.");
      return;
    }

    const signature = req.get("x-hub-signature-256");
    if (!verifyGithubSignature(rawBody, signature, secret)) {
      const rejected = signatureRejections.record(Date.now());
      if (rejected !== null) {
        await logWarn({
          message:
            `githubTicketWebhook : ${rejected} livraison(s) refusée(s) ` +
            "pour signature absente ou invalide depuis le dernier relevé",
          correlationId,
          feature: "tickets",
          extra: {
            has_signature: typeof signature === "string",
            rejected,
            event: event.slice(0, 64),
          },
        });
      }
      res.status(401).send("Signature invalide.");
      return;
    }

    const deliveryId = req.get("x-github-delivery") ?? null;
    if (event === "ping") {
      res.status(200).send("pong");
      return;
    }

    let payload: Payload;
    try {
      payload = JSON.parse(rawBody.toString("utf8")) as Payload;
    } catch (err) {
      await logWarn({
        message: "githubTicketWebhook : corps JSON illisible",
        errorDescription: err instanceof Error ? err.message : String(err),
        correlationId,
        feature: "tickets",
        extra: { event, delivery: deliveryId },
      });
      res.status(400).send("Corps illisible.");
      return;
    }

    const updates = updatesFromEvent(event, payload);
    let changed = 0;
    try {
      for (const { issueNumber, update } of updates) {
        // Une Issue sans ticket ne vient pas de l'application : ignorée.
        for (const ticketId of await ticketIdsForIssue(issueNumber)) {
          if (await applyGithubUpdate(ticketId, update)) {
            changed++;
            await logInfo({
              message: `githubTicketWebhook : ticket ${ticketId} mis à jour (Issue #${issueNumber}, ${event})`,
              correlationId,
              firestoreDocId: ticketId,
              feature: "tickets",
              extra: { delivery: deliveryId },
            });
          }
        }
      }
    } catch (err) {
      await logError({
        message: `githubTicketWebhook : événement ${event} non appliqué`,
        errorDescription: err instanceof Error ? err.message : String(err),
        correlationId,
        feature: "tickets",
        extra: { delivery: deliveryId },
      });
      res.status(500).send("Erreur interne.");
      return;
    }

    const closedIssue = closedIssueFromEvent(event, payload);
    if (closedIssue !== null) {
      try {
        const ticketIds = await ticketIdsForIssue(closedIssue);
        if (ticketIds.length > 0) {
          const token = githubToken();
          if (token === null) {
            throw new GithubError(
              "token",
              null,
              "Jeton GitHub absent (secret GITHUB_TICKETS_TOKEN vide).",
            );
          }
          for (const ticketId of ticketIds) {
            if ((await recordDeliveredPr(token, ticketId, closedIssue)) === "written") {
              changed++;
              await logInfo({
                message: `githubTicketWebhook : PR de livraison du ticket ${ticketId} relevée (Issue #${closedIssue})`,
                correlationId,
                firestoreDocId: ticketId,
                feature: "tickets",
                extra: { delivery: deliveryId },
              });
            }
          }
        }
      } catch (err) {
        const kind = err instanceof GithubError ? err.kind : "other";
        await logError({
          message: `githubTicketWebhook : PR de livraison de l'Issue #${closedIssue} non relevée`,
          errorDescription: err instanceof Error ? err.message : String(err),
          correlationId,
          feature: "tickets",
          extra: { delivery: deliveryId, kind },
        });
        if (kind === "token") {
          await markTokenInvalid(
            { correlationId },
            err instanceof Error ? err.message : String(err),
          );
        }
        res.status(500).send("Erreur interne.");
        return;
      }
    }

    const validated = validatedLabelFromEvent(event, payload, new Date().toISOString());
    if (validated !== null) {
      try {
        for (const ticketId of await ticketIdsForIssue(validated.issueNumber)) {
          // L'étiquette vient d'être posée : la date ne recule pas.
          await updateValidatedAt(ticketId, Date.parse(validated.at), true);
          changed++;
        }
      } catch (err) {
        await logError({
          message: `githubTicketWebhook : date de validation de l'Issue #${validated.issueNumber} non écrite`,
          errorDescription: err instanceof Error ? err.message : String(err),
          correlationId,
          feature: "tickets",
          extra: { delivery: deliveryId },
        });
        res.status(500).send("Erreur interne.");
        return;
      }
    }

    const refreshIssue = analysisRefreshFromEvent(event, payload);
    if (refreshIssue !== null) {
      const scope = { correlationId };
      try {
        const ticketIds = await ticketIdsForIssue(refreshIssue);
        if (ticketIds.length > 0) {
          const token = githubToken();
          if (token === null) {
            throw new GithubError(
              "token",
              null,
              "Jeton GitHub absent (secret GITHUB_TICKETS_TOKEN vide).",
            );
          }
          for (const ticketId of ticketIds) {
            const count = await refreshTicketComments(token, ticketId, refreshIssue, scope);
            changed++;
            await logInfo({
              message: `githubTicketWebhook : analyses du ticket ${ticketId} réécrites (${count}, Issue #${refreshIssue})`,
              correlationId,
              firestoreDocId: ticketId,
              feature: "tickets",
              extra: { delivery: deliveryId },
            });
          }
        }
      } catch (err) {
        const kind = err instanceof GithubError ? err.kind : "other";
        await logError({
          message: `githubTicketWebhook : analyses de l'Issue #${refreshIssue} non réécrites`,
          errorDescription: err instanceof Error ? err.message : String(err),
          correlationId,
          feature: "tickets",
          extra: { delivery: deliveryId, kind },
        });
        if (kind === "token") {
          await markTokenInvalid(scope, err instanceof Error ? err.message : String(err));
        }
        res.status(500).send("Erreur interne.");
        return;
      }
    }

    const delivery = deliveryRefreshFromEvent(event, payload);
    if (delivery !== null) {
      const scope = { correlationId };
      try {
        const token = githubToken();
        if (token === null) {
          throw new GithubError(
            "token",
            null,
            "Jeton GitHub absent (secret GITHUB_TICKETS_TOKEN vide).",
          );
        }
        const issues = new Set(delivery.issueNumbers);
        for (const prNumber of delivery.prNumbers) {
          const pr = await getPullRequest(token, prNumber);
          if (!isDeliveryCandidatePr(pr)) continue;
          for (const n of closingIssueNumbers(pr.body, GITHUB_REPO_FULL_NAME)) issues.add(n);
        }
        // Liste des PR ouvertes lue une fois pour l'événement, partagée.
        let openPrs: OpenPullRequests | null = null;
        for (const issueNumber of [...issues].slice(0, DELIVERY_EVENT_MAX)) {
          for (const ticketId of await ticketIdsForIssue(issueNumber)) {
            openPrs ??= await listOpenPullRequests(token);
            const state = await refreshTicketDelivery(token, ticketId, issueNumber, openPrs);
            changed++;
            await logInfo({
              message: `githubTicketWebhook : état « PR prête » du ticket ${ticketId} relu (Issue #${issueNumber}, ${event}, prête : ${state?.ready === true})`,
              correlationId,
              firestoreDocId: ticketId,
              feature: "tickets",
              extra: { delivery: deliveryId },
            });
          }
        }
      } catch (err) {
        const kind = err instanceof GithubError ? err.kind : "other";
        await logError({
          message: `githubTicketWebhook : état « PR prête » non relu (${event})`,
          errorDescription: err instanceof Error ? err.message : String(err),
          correlationId,
          feature: "tickets",
          extra: { delivery: deliveryId, kind },
        });
        if (kind === "token") {
          await markTokenInvalid(scope, err instanceof Error ? err.message : String(err));
        }
        res.status(500).send("Erreur interne.");
        return;
      }
    }
    res.status(200).send(changed > 0 ? `ok (${changed})` : "ignoré");
  },
);
