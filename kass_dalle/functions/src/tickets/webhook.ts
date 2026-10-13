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
 * Événements traités : `issues` (étiquettes, fermeture, réouverture),
 * `issue_comment` (réponse de l'administrateur), `pull_request` (PR ouverte
 * qui ferme l'Issue → « En cours », si son auteur est le mainteneur ou un
 * `OWNER`, `MEMBER` ou `COLLABORATOR` du dépôt), `ping`. Tout autre événement, une Issue
 * d'un autre dépôt ou une Issue qui ne vient pas de l'application (aucun
 * ticket sous ce numéro) : 200, ignoré.
 *
 * Aucun texte venu de GitHub n'est écrit dans Firestore, hormis `reply_text`
 * filtré (`replyFromComment`). Les statuts sont dérivés des étiquettes et de
 * l'état, jamais d'un texte libre.
 *
 * Une panne Firestore rend 500 : GitHub affiche la livraison en échec, et la
 * tâche horaire `ticketsSyncSchedule` rattrape l'état.
 */

import { onRequest } from "firebase-functions/v2/https";

import { GITHUB_TICKETS_MAINTAINER_ID, GITHUB_WEBHOOK_SECRET, REGION } from "../config";
import { logError, logInfo, logWarn, newCorrelationId } from "../logging";
import { GITHUB_REPO_FULL_NAME, readRemoteIssue } from "./github";
import {
  closingIssueNumbers,
  isTrustedPrAuthor,
  replyFromComment,
  statusFromIssue,
  verifyGithubSignature,
} from "./rules";
import { applyGithubUpdate, ticketIdsForIssue, type GithubUpdate } from "./service";

const ISSUE_ACTIONS = new Set(["opened", "edited", "labeled", "unlabeled", "closed", "reopened"]);
const COMMENT_ACTIONS = new Set(["created", "edited"]);
const PR_ACTIONS = new Set(["opened", "reopened", "edited", "ready_for_review"]);

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

export const githubTicketWebhook = onRequest(
  {
    region: REGION,
    invoker: "public",
    maxInstances: 5,
    timeoutSeconds: 60,
    secrets: [GITHUB_WEBHOOK_SECRET],
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

    const delivery = req.get("x-github-delivery") ?? null;
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
        extra: { event, delivery },
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
              extra: { delivery },
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
        extra: { delivery },
      });
      res.status(500).send("Erreur interne.");
      return;
    }
    res.status(200).send(changed > 0 ? `ok (${changed})` : "ignoré");
  },
);
