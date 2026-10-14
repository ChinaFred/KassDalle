/**
 * Tickets : règles pures, testées par `tests/tickets.test.ts`.
 *
 * Rien ici ne lit Firestore ni GitHub. On y trouve :
 *  - la lecture des entrées de `submitTicket` (types, bornes, écran) ;
 *  - le corps de l'Issue publiée sur un dépôt PUBLIC, construit sur un gabarit
 *    fixe : ni nom, ni adresse, ni uid, ni capture, mentions `@` et renvois
 *    `#N` neutralisés ;
 *  - la correspondance état GitHub → statut du ticket, et la règle de
 *    non-recul ;
 *  - le filtre de la réponse de l'administrateur (`reply_text`) et des PR
 *    qui comptent pour « En cours » ;
 *  - la signature des octets d'une capture ;
 *  - la vérification de la signature HMAC d'un webhook ;
 *  - le jour calendaire Europe/Paris du plafond, et la lecture des plafonds ;
 *  - les analyses du mainteneur relevées sur l'Issue (`## Analyse…`) ;
 *  - les décisions de l'administrateur : conditions de « Valider » et
 *    « Refuser », lecture du motif de refus, message d'une erreur GitHub ;
 *  - les lancements de sessions Claude Code : texte de commande, condition
 *    de statut, échéance, règle « en cours », plafond et compteurs
 *    (`tests/ticketLaunches.test.ts`, fixture `ticket_decisions.json`).
 */

import { createHmac, timingSafeEqual } from "node:crypto";

// ── Types et statuts ────────────────────────────────────────────────────────

export const TICKET_TYPES = ["bug", "evolution", "feature", "question"] as const;
export type TicketType = (typeof TICKET_TYPES)[number];

export const TICKET_TYPE_LABELS: Record<TicketType, string> = {
  bug: "Bug",
  evolution: "Évolution",
  feature: "Nouvelle fonctionnalité",
  question: "Question",
};

export const TICKET_PLATFORMS = ["android", "ios", "web", "windows"] as const;
export type TicketPlatform = (typeof TICKET_PLATFORMS)[number];

const PLATFORM_LABELS: Record<TicketPlatform, string> = {
  android: "Android",
  ios: "iOS",
  web: "Web",
  windows: "Windows",
};

export const TICKET_STATUSES = [
  "sending",
  "received",
  "analyzed",
  "validated",
  "in_progress",
  "delivered",
  "refused",
  "answered",
] as const;
export type TicketStatus = (typeof TICKET_STATUSES)[number];

/** Statuts de fin : le suivi s'arrête, sauf réouverture de l'Issue. */
export const FINAL_STATUSES: readonly TicketStatus[] = ["delivered", "refused", "answered"];

/** Rang d'un statut dans le suivi. Les trois fins partagent le dernier rang. */
const STATUS_RANK: Record<TicketStatus, number> = {
  sending: 0,
  received: 1,
  analyzed: 2,
  validated: 3,
  in_progress: 4,
  delivered: 5,
  refused: 5,
  answered: 5,
};

export function isTicketType(value: unknown): value is TicketType {
  return typeof value === "string" && (TICKET_TYPES as readonly string[]).includes(value);
}

export function isTicketStatus(value: unknown): value is TicketStatus {
  return typeof value === "string" && (TICKET_STATUSES as readonly string[]).includes(value);
}

export function isFinalStatus(status: TicketStatus): boolean {
  return FINAL_STATUSES.includes(status);
}

// ── Étiquettes GitHub ───────────────────────────────────────────────────────

export const LABEL_SOURCE_APP = "source:app";
export const LABEL_TO_ANALYZE = "statut:à-analyser";
export const LABEL_ANALYZED = "statut:analysé";
export const LABEL_VALIDATED = "validé";

export function typeLabel(type: TicketType): string {
  return `type:${type}`;
}

/** Étiquettes posées à la création de l'Issue. */
export function creationLabels(type: TicketType): string[] {
  return [LABEL_SOURCE_APP, typeLabel(type), LABEL_TO_ANALYZE];
}

// ── Entrées de submitTicket ─────────────────────────────────────────────────

export const TICKET_TITLE_MIN = 5;
export const TICKET_TITLE_MAX = 100;
export const TICKET_DESCRIPTION_MAX = 2000;
export const TICKET_SCREEN_MAX = 100;

/** Écran choisi « Autre écran » ou « Je ne sais pas » dans le formulaire. */
export const SCREEN_OTHER = "autre";
export const SCREEN_UNKNOWN = "inconnu";

/** Une entrée refusée : le champ et le message rendus au client. */
export class TicketInputError extends Error {
  constructor(
    readonly field: string,
    message: string,
  ) {
    super(message);
  }
}

export interface TicketInput {
  type: TicketType;
  title: string;
  description: string;
  screen: string;
  /** Vrai quand l'écran reçu n'était pas un modèle de route et a été remplacé. */
  screenReplaced: boolean;
  app_version: string;
  platform: TicketPlatform;
}

/** Espaces, retours à la ligne et tabulations ramenés à une espace. */
function singleLine(value: string): string {
  return value.replace(/\s+/g, " ").trim();
}

/**
 * Caractères de contrôle retirés d'un texte multiligne, sauf retour à la ligne
 * et tabulation ; fins de ligne Windows ramenées à `\n`.
 */
function cleanMultiline(value: string): string {
  const unixLines = value.replace(/\r\n?/g, "\n");
  let out = "";
  for (const char of unixLines) {
    const code = char.charCodeAt(0);
    const isControl = code < 0x20 || code === 0x7f;
    if (!isControl || char === "\n" || char === "\t") out += char;
  }
  return out;
}

const SCREEN_SEGMENT = /^(?:[a-z][a-z-]{0,39}|:[A-Za-z][A-Za-z0-9]{0,39})$/;

/**
 * Le modèle de route go_router de l'écran, ou `null` s'il n'en a pas la forme.
 *
 * Un modèle ne porte que des segments littéraux en minuscules
 * (`book-pages`, `edit`) et des paramètres (`:recipeId`). Un identifiant de
 * document (`aB3x…`, chiffres, majuscules) ne passe pas : l'écran part sur un
 * dépôt public, et une adresse réelle y publierait l'identifiant d'une recette.
 * La requête et le fragment (`?…`, `#…`) ne sont jamais acceptés.
 */
export function routeTemplateOrNull(value: string): string | null {
  if (value === SCREEN_OTHER || value === SCREEN_UNKNOWN) return value;
  if (value === "/") return value;
  if (!value.startsWith("/") || value.length > TICKET_SCREEN_MAX) return null;
  const segments = value.slice(1).split("/");
  return segments.every((s) => SCREEN_SEGMENT.test(s)) ? value : null;
}

/** Version de l'application : `0.23.53+400`, 40 caractères au plus. */
const APP_VERSION_PATTERN = /^[0-9A-Za-z.+-]{1,40}$/;

/**
 * Lit et valide les entrées de `submitTicket`. Lève `TicketInputError`.
 *
 * Titre : une ligne, 5 à 100 caractères après nettoyage. Description : 1 à
 * 2 000 caractères. Écran : un modèle de route, sinon remplacé par `inconnu`
 * (le membre n'y peut rien, le ticket n'est pas refusé pour autant).
 */
export function readTicketInput(raw: Record<string, unknown>): TicketInput {
  if (!isTicketType(raw.type)) {
    throw new TicketInputError("type", "Choisissez le type de ticket.");
  }
  if (typeof raw.title !== "string") {
    throw new TicketInputError("title", "Le titre est requis.");
  }
  const title = singleLine(raw.title);
  if (title.length < TICKET_TITLE_MIN) {
    throw new TicketInputError("title", "Le titre doit faire au moins 5 caractères.");
  }
  if (title.length > TICKET_TITLE_MAX) {
    throw new TicketInputError("title", "Le titre ne doit pas dépasser 100 caractères.");
  }
  if (typeof raw.description !== "string") {
    throw new TicketInputError("description", "La description est requise.");
  }
  const description = cleanMultiline(raw.description).trim();
  if (description.length === 0) {
    throw new TicketInputError("description", "La description est requise.");
  }
  if (description.length > TICKET_DESCRIPTION_MAX) {
    throw new TicketInputError(
      "description",
      "La description ne doit pas dépasser 2 000 caractères.",
    );
  }
  if (typeof raw.screen !== "string" || raw.screen.length > 2 * TICKET_SCREEN_MAX) {
    throw new TicketInputError("screen", "L'écran concerné est invalide.");
  }
  const template = routeTemplateOrNull(raw.screen.trim());
  if (typeof raw.app_version !== "string" || !APP_VERSION_PATTERN.test(raw.app_version.trim())) {
    throw new TicketInputError("app_version", "La version de l'application est invalide.");
  }
  if (
    typeof raw.platform !== "string" ||
    !(TICKET_PLATFORMS as readonly string[]).includes(raw.platform)
  ) {
    throw new TicketInputError("platform", "La plateforme est invalide.");
  }
  return {
    type: raw.type,
    title,
    description,
    screen: template ?? SCREEN_UNKNOWN,
    screenReplaced: template === null,
    app_version: raw.app_version.trim(),
    platform: raw.platform as TicketPlatform,
  };
}

// ── Corps de l'Issue (dépôt public) ─────────────────────────────────────────

/** Espace sans chasse : coupe `@nom` sans changer ce qu'on lit. */
const ZERO_WIDTH_SPACE = String.fromCharCode(0x200b);

/**
 * Neutralise les mentions `@nom` et `@org/équipe` : GitHub ne notifie
 * personne. Un `@` suivi d'une lettre, d'un chiffre ou d'un tiret reçoit une
 * espace sans chasse ; une adresse e-mail (`a@b.fr`) est traitée de même, ce
 * qui est sans effet visible.
 */
export function neutralizeMentions(text: string): string {
  return text.replace(/@(?=[A-Za-z0-9-])/g, `@${ZERO_WIDTH_SPACE}`);
}

/**
 * Neutralise les renvois `#12` et `owner/repo#12` : GitHub ne
 * lie pas le texte à une autre Issue ou PR, et n'ajoute pas d'événement
 * « mentioned this » à leur chronologie. Un `#` suivi d'un chiffre reçoit une
 * espace sans chasse ; un titre Markdown (`### Description`) n'est pas touché.
 */
export function neutralizeIssueReferences(text: string): string {
  return text.replace(/#(?=\d)/g, `#${ZERO_WIDTH_SPACE}`);
}

/** Texte d'un membre publié sur le dépôt public : mentions et renvois neutralisés. */
function publicText(text: string): string {
  return neutralizeIssueReferences(neutralizeMentions(text));
}

function screenLabel(screen: string): string {
  if (screen === SCREEN_OTHER) return "Autre écran";
  if (screen === SCREEN_UNKNOWN) return "Non précisé";
  return `\`${screen}\``;
}

/** Titre de l'Issue : celui du ticket, mentions et renvois neutralisés. */
export function buildIssueTitle(title: string): string {
  return publicText(singleLine(title));
}

/**
 * Corps de l'Issue, sur un gabarit fixe.
 *
 * Ce qui part : type, écran (modèle de route), version, plateforme,
 * référence opaque (l'identifiant du document `tickets`), description.
 * Ce qui ne part jamais : nom, adresse, uid, capture, contenu de recette.
 * Le texte du membre n'est pas échappé en Markdown, seulement privé de ses
 * mentions et de ses renvois `#N`.
 */
export function buildIssueBody(args: {
  ticketId: string;
  type: TicketType;
  description: string;
  screen: string;
  app_version: string;
  platform: TicketPlatform;
}): string {
  return [
    `**Type :** ${TICKET_TYPE_LABELS[args.type]}`,
    `**Écran :** ${screenLabel(args.screen)}`,
    `**Version :** ${args.app_version}`,
    `**Plateforme :** ${PLATFORM_LABELS[args.platform]}`,
    `**Référence :** \`${args.ticketId}\``,
    "",
    "### Description",
    "",
    publicText(args.description),
    "",
    "---",
    "_Ticket envoyé depuis l'application Kass'Dalle. Capture éventuelle disponible dans " +
      "Admin › Tickets._",
  ].join("\n");
}

// ── État GitHub → statut ────────────────────────────────────────────────────

export interface IssueState {
  state: "open" | "closed";
  /** `completed`, `not_planned`, `duplicate`, `reopened` ou `null`. */
  stateReason: string | null;
  labels: string[];
  /** Une PR ouverte référence l'Issue par un mot-clé de fermeture. Inconnu : `false`. */
  hasOpenClosingPr: boolean;
}

/**
 * Le statut que dit l'Issue, sans tenir compte du statut actuel.
 *
 * Fermée : `not_planned` (ou `duplicate`) → `refused` ; sinon `delivered`,
 * ou `answered` pour une Question. Ouverte : PR ouverte → `in_progress`,
 * étiquette `validé` → `validated`, `statut:analysé` → `analyzed`, sinon
 * `received`.
 */
export function statusFromIssue(issue: IssueState, type: TicketType): TicketStatus {
  if (issue.state === "closed") {
    if (issue.stateReason === "not_planned" || issue.stateReason === "duplicate") {
      return "refused";
    }
    return type === "question" ? "answered" : "delivered";
  }
  if (issue.hasOpenClosingPr) return "in_progress";
  if (issue.labels.includes(LABEL_VALIDATED)) return "validated";
  if (issue.labels.includes(LABEL_ANALYZED)) return "analyzed";
  return "received";
}

/**
 * Le statut à retenir, connaissant le statut actuel et celui que dit GitHub.
 *
 * - Un statut ne recule jamais : on garde le plus avancé des deux.
 * - Un statut de fin suit l'Issue : rouverte, elle ramène au statut dérivé de
 *   ses étiquettes ; refermée autrement, elle change de fin.
 */
export function nextTicketStatus(current: TicketStatus, fromGithub: TicketStatus): TicketStatus {
  if (isFinalStatus(current)) return fromGithub;
  if (isFinalStatus(fromGithub)) return fromGithub;
  return STATUS_RANK[fromGithub] > STATUS_RANK[current] ? fromGithub : current;
}

/**
 * Numéros d'Issue fermés par une PR : `Closes #12`, `fixes ChinaFred/KassDalle#12`…
 *
 * Mots-clés reconnus par GitHub : close(s|d), fix(es|ed), resolve(s|d). Une
 * référence vers un autre dépôt est ignorée.
 */
export function closingIssueNumbers(
  body: string | null | undefined,
  repoFullName: string,
): number[] {
  if (!body) return [];
  const pattern =
    /\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\s*:?\s+(?:([A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+))?#(\d+)\b/gi;
  const numbers = new Set<number>();
  for (const match of body.matchAll(pattern)) {
    const repo = match[1];
    if (repo && repo.toLowerCase() !== repoFullName.toLowerCase()) continue;
    const n = Number(match[2]);
    if (Number.isSafeInteger(n) && n > 0) numbers.add(n);
  }
  return [...numbers].sort((a, b) => a - b);
}

/** Rôles GitHub d'un auteur de PR qui a un accès au dépôt. */
const TRUSTED_ASSOCIATIONS = new Set(["OWNER", "MEMBER", "COLLABORATOR"]);

/**
 * Vrai si une PR de cet auteur peut faire passer un ticket « En cours ».
 *
 * N'importe quel compte peut ouvrir une PR depuis un fork avec « Closes #N »
 * dans son corps. Seules comptent celles du mainteneur (identifiant
 * numérique) ou d'un compte que GitHub déclare `OWNER`, `MEMBER` ou
 * `COLLABORATOR` du dépôt (`author_association`).
 */
export function isTrustedPrAuthor(
  author: { id: number | null | undefined; association: string | null | undefined },
  maintainerId: number,
): boolean {
  if (typeof author.id === "number" && author.id === maintainerId) return true;
  return typeof author.association === "string" && TRUSTED_ASSOCIATIONS.has(author.association);
}

// ── Réponse de l'administrateur ─────────────────────────────────────────────

const REPLY_PREFIX = /^Réponse\s*:\s*/u;

/**
 * La réponse montrée au membre, ou `null` si ce commentaire n'en est pas une.
 *
 * Seul un commentaire du compte `maintainerId` (identifiant numérique GitHub,
 * pas le login, qui se renomme) qui commence par « Réponse : » compte ;
 * le préfixe est retiré. Les espaces (y compris insécables) autour des deux
 * points sont tolérés, et le « é » composé comme décomposé.
 */
export function replyFromComment(
  comment: { authorId: number | null | undefined; body: string | null | undefined },
  maintainerId: number,
): string | null {
  if (typeof comment.authorId !== "number" || comment.authorId !== maintainerId) return null;
  if (typeof comment.body !== "string") return null;
  const body = comment.body.normalize("NFC").replace(/\r\n?/g, "\n").trimStart();
  if (!REPLY_PREFIX.test(body)) return null;
  const text = body.replace(REPLY_PREFIX, "").trim();
  return text.length > 0 ? text : null;
}

// ── Analyses du mainteneur ──────────────────────────────────────────────────

const ANALYSIS_PREFIX = "## Analyse";

/** Analyses gardées par ticket : les plus récentes. */
export const ANALYSIS_MAX_COUNT = 10;

/** Longueur maximale d'une analyse stockée, en caractères. */
export const ANALYSIS_MAX_CHARS = 20_000;

/** Texte d'un commentaire, NFC, fins de ligne Unix. */
function normalizedBody(body: string): string {
  return body.normalize("NFC").replace(/\r\n?/g, "\n");
}

/**
 * Vrai si ce commentaire est une analyse : son auteur est le compte
 * `maintainerId` (identifiant numérique) et son texte, espaces de tête
 * retirées, commence par `## Analyse` (« ## Analyse — compléments » compte).
 * Tout autre auteur est ignoré, même avec le bon titre.
 */
export function isAnalysisComment(
  comment: { authorId: number | null | undefined; body: string | null | undefined },
  maintainerId: number,
): boolean {
  if (typeof comment.authorId !== "number" || comment.authorId !== maintainerId) return false;
  if (typeof comment.body !== "string") return false;
  return normalizedBody(comment.body).trimStart().startsWith(ANALYSIS_PREFIX);
}

/**
 * Coupe une analyse trop longue à la dernière ligne vide avant
 * `ANALYSIS_MAX_CHARS` : un paragraphe, un tableau ou un bloc de code n'est
 * pas tranché au milieu. Sans ligne vide avant la limite, coupe à la limite
 * (sans séparer une paire de substitution UTF-16).
 */
export function truncateAnalysis(
  body: string,
  max: number = ANALYSIS_MAX_CHARS,
): { body: string; truncated: boolean } {
  if (body.length <= max) return { body, truncated: false };
  const head = body.slice(0, max);
  let cut = -1;
  for (const match of head.matchAll(/\n[ \t]*\n/g)) {
    if (match.index !== undefined && match.index > 0) cut = match.index;
  }
  if (cut <= 0) {
    cut = max;
    const code = body.charCodeAt(cut - 1);
    if (code >= 0xd800 && code <= 0xdbff) cut -= 1;
  }
  return { body: body.slice(0, cut).trimEnd(), truncated: true };
}

/** Un commentaire d'Issue tel que les analyses le lisent. */
export interface AnalysisSourceComment {
  id: number | null;
  authorId: number | null;
  body: string | null;
  /** Horodatage ISO de GitHub, ou `null`. */
  createdAt: string | null;
  updatedAt: string | null;
}

/** Une analyse stockée dans `tickets/{id}/admin/analysis.analyses`. */
export interface TicketAnalysis {
  comment_id: number | null;
  body: string;
  /** Horodatage ISO ; le service l'écrit en `Timestamp`. */
  created_at: string | null;
  updated_at: string | null;
  truncated: boolean;
}

function isoMillis(iso: string | null): number {
  if (iso === null) return Number.POSITIVE_INFINITY;
  const ms = Date.parse(iso);
  return Number.isNaN(ms) ? Number.POSITIVE_INFINITY : ms;
}

/**
 * Les analyses d'une Issue, dans l'ordre chronologique : seulement celles du
 * mainteneur (`isAnalysisComment`), les `ANALYSIS_MAX_COUNT` plus récentes,
 * chacune tronquée (`truncateAnalysis`). Le texte garde sa ligne de titre :
 * le client la retire à l'affichage.
 */
export function analysesFromComments(
  comments: readonly AnalysisSourceComment[],
  maintainerId: number,
): TicketAnalysis[] {
  const kept = comments
    .map((c, index) => ({ c, index }))
    .filter(({ c }) => isAnalysisComment(c, maintainerId))
    .sort((a, b) => isoMillis(a.c.createdAt) - isoMillis(b.c.createdAt) || a.index - b.index)
    .slice(-ANALYSIS_MAX_COUNT);
  return kept.map(({ c }) => {
    const { body, truncated } = truncateAnalysis(normalizedBody(c.body ?? "").trim());
    return {
      comment_id: c.id,
      body,
      created_at: c.createdAt,
      updated_at: c.updatedAt,
      truncated,
    };
  });
}

// ── Décisions de l'administrateur ───────────────────────────────────────────

export const REFUSAL_REASON_MIN = 5;
export const REFUSAL_REASON_MAX = 2000;

/** Préfixe du commentaire publié : celui que `replyFromComment` reconnaît. */
export const REPLY_COMMENT_PREFIX = "Réponse : ";

/**
 * Lit le motif d'un refus. Lève `TicketInputError` (champ `reason`).
 *
 * Caractères de contrôle retirés (retours à la ligne gardés), espaces de
 * tête et de fin retirées, NFC, 5 à 2 000 caractères. Le motif part sur un
 * dépôt PUBLIC : mentions `@` et renvois `#N` neutralisés après le contrôle
 * de longueur.
 */
export function readRefusalReason(raw: unknown): string {
  if (typeof raw !== "string") {
    throw new TicketInputError("reason", "Le motif du refus est requis.");
  }
  const reason = cleanMultiline(raw).normalize("NFC").trim();
  if (reason.length < REFUSAL_REASON_MIN) {
    throw new TicketInputError("reason", "Le motif doit faire au moins 5 caractères.");
  }
  if (reason.length > REFUSAL_REASON_MAX) {
    throw new TicketInputError("reason", "Le motif ne doit pas dépasser 2 000 caractères.");
  }
  return publicText(reason);
}

/** Corps du commentaire qui publie le motif. */
export function refusalCommentBody(reason: string): string {
  return `${REPLY_COMMENT_PREFIX}${reason}`;
}

/**
 * Vrai si la dernière réponse du mainteneur porte déjà ce motif : un refus
 * repris après un échec partiel (motif publié, Issue restée ouverte) ne
 * publie pas le motif une seconde fois.
 */
export function sameReply(lastReply: string | null | undefined, reason: string): boolean {
  if (typeof lastReply !== "string") return false;
  const norm = (t: string) => normalizedBody(t).trim();
  return norm(lastReply) === norm(reason);
}

/** Statuts depuis lesquels un ticket peut être refusé. */
export const REFUSABLE_STATUSES: readonly TicketStatus[] = [
  "received",
  "analyzed",
  "validated",
  "in_progress",
];

/**
 * Ce que décide « Valider » avant tout appel à GitHub :
 * - `already` : déjà validé, succès sans rien changer ;
 * - `ok` : ticket analysé, d'un autre type que Question, avec une Issue ;
 * - sinon le message du refus.
 */
export function validatePrecondition(args: {
  status: TicketStatus;
  type: TicketType;
  hasIssue: boolean;
}): { kind: "ok" } | { kind: "already" } | { kind: "refused"; message: string } {
  if (args.status === "validated") return { kind: "already" };
  if (!args.hasIssue) {
    return { kind: "refused", message: "Ce ticket n'a pas encore d'Issue GitHub." };
  }
  if (args.type === "question") {
    return {
      kind: "refused",
      message: "Une question reçoit une réponse sur GitHub, pas une validation.",
    };
  }
  if (args.status !== "analyzed") {
    return { kind: "refused", message: "Seul un ticket analysé peut être validé." };
  }
  return { kind: "ok" };
}

/**
 * Ce que décide « Refuser » avant tout appel à GitHub : `null` si le refus
 * est permis (statut Reçu, Analysé, Validé ou En cours, avec une Issue), sinon
 * le message du refus.
 */
export function refusePrecondition(args: {
  status: TicketStatus;
  hasIssue: boolean;
}): string | null {
  if (!args.hasIssue) return "Ce ticket n'a pas encore d'Issue GitHub.";
  if (!REFUSABLE_STATUSES.includes(args.status)) return "Ce ticket ne peut plus être refusé.";
  return null;
}

/**
 * Statut lu sur un document : une valeur inconnue de cette version se lit
 * `sending`, qui n'offre aucune décision.
 */
export function storedTicketStatus(raw: unknown): TicketStatus {
  return isTicketStatus(raw) ? raw : "sending";
}

/**
 * Les décisions permises sur un ticket stocké, telles que le client les
 * affiche (`adminTicketDecisions`, fixture `ticket_decisions.json`). Pure.
 *
 * Les lancements suivent leur condition de statut (`launchPrecondition`) ;
 * l'historique (lancement en cours, relance) est la règle à part
 * `launchRunState`, que le client combine de la même façon.
 */
export function ticketDecisions(args: {
  rawStatus: unknown;
  type: TicketType;
  hasIssue: boolean;
}): {
  canValidate: boolean;
  canRefuse: boolean;
  canLaunchAnalysis: boolean;
  canLaunchDevelopment: boolean;
} {
  const status = storedTicketStatus(args.rawStatus);
  const launchArgs = { status, type: args.type, hasIssue: args.hasIssue };
  return {
    canValidate:
      validatePrecondition({ status, type: args.type, hasIssue: args.hasIssue }).kind === "ok",
    canRefuse: refusePrecondition({ status, hasIssue: args.hasIssue }) === null,
    canLaunchAnalysis: launchPrecondition(launchArgs, "analyse") === null,
    canLaunchDevelopment: launchPrecondition(launchArgs, "developpement") === null,
  };
}

/**
 * Vrai si la validation peut écrire `validated` sur un ticket relu à
 * l'écriture : seulement s'il est encore `analyzed`. Un ticket refusé, livré
 * ou déjà validé entre-temps n'est pas réécrit.
 */
export function shouldWriteValidated(current: TicketStatus): boolean {
  return current === "analyzed";
}

/** Échec partiel d'un refus : le motif est publié, l'Issue n'est pas fermée. */
export const REFUSAL_PARTIAL_REASON = "reply_published_close_failed";

/**
 * Code et message rendus au client pour un échec GitHub d'une décision,
 * selon le genre d'erreur (`GithubErrorKind`). Rien n'a été modifié sur
 * GitHub quand cette erreur est rendue : l'échec partiel d'un refus a son
 * propre message.
 */
export function decisionGithubFailure(kind: string): {
  code: "failed-precondition" | "not-found" | "unavailable";
  message: string;
  reason: string;
} {
  switch (kind) {
    case "token":
      return {
        code: "failed-precondition",
        message: "GitHub refuse le jeton. Rien n'a été modifié.",
        reason: "github_token",
      };
    case "not_found":
      return {
        code: "not-found",
        message: "L'Issue n'existe plus sur GitHub.",
        reason: "issue_not_found",
      };
    case "rate_limit":
      return {
        code: "unavailable",
        message: "GitHub limite les appels. Réessayez dans quelques minutes. Rien n'a été modifié.",
        reason: "github_rate_limit",
      };
    default:
      return {
        code: "unavailable",
        message: "GitHub ne répond pas. Réessayez. Rien n'a été modifié.",
        reason: "github_unavailable",
      };
  }
}

// ── Lancements de sessions Claude Code (Routines) ──────────────────────────

/**
 * Les deux routines : `analyse` (ticket Reçu) et `developpement` (ticket
 * Validé). La valeur est aussi le premier mot du texte envoyé à la routine.
 */
export const LAUNCH_ACTIONS = ["analyse", "developpement"] as const;
export type LaunchAction = (typeof LAUNCH_ACTIONS)[number];

export function isLaunchAction(value: unknown): value is LaunchAction {
  return typeof value === "string" && (LAUNCH_ACTIONS as readonly string[]).includes(value);
}

/** Le statut que le ticket doit avoir pour lancer, et garder pendant le lancement. */
export const LAUNCH_FROM_STATUS: Record<LaunchAction, TicketStatus> = {
  analyse: "received",
  developpement: "validated",
};

/**
 * Délai après lequel un lancement resté sans effet sur le statut du ticket
 * peut être relancé : 1 h pour une analyse, 3 h pour un développement.
 */
export const LAUNCH_RETRY_MS: Record<LaunchAction, number> = {
  analyse: 60 * 60 * 1000,
  developpement: 3 * 60 * 60 * 1000,
};

/** Plafond par défaut, analyse et développement confondus, pour toute la famille. */
export const DEFAULT_LAUNCHES_PER_DAY = 10;

/**
 * Plus haut réglage accepté pour `launches_per_day`. Au-delà, le réglage est
 * refusé comme illisible : une faute de frappe (1000) ne lève pas le plafond.
 */
export const MAX_LAUNCHES_PER_DAY = 50;

/** Entrées gardées dans `tickets/{id}/admin/launches`, plus récente en tête. */
export const LAUNCH_HISTORY_MAX = 20;

/** Seule forme de texte envoyée à une routine. */
export const LAUNCH_TEXT_PATTERN = /^(analyse|developpement) #[1-9][0-9]{0,6}$/;

/**
 * Le texte envoyé à la routine : `analyse #N` ou `developpement #N`. Lève si
 * le résultat ne suit pas [LAUNCH_TEXT_PATTERN] : rien d'autre ne part.
 */
export function launchCommandText(action: LaunchAction, issueNumber: number): string {
  const text = `${action} #${issueNumber}`;
  if (!LAUNCH_TEXT_PATTERN.test(text)) {
    throw new Error(`texte de lancement refusé : ${JSON.stringify(text)}`);
  }
  return text;
}

/** Lit un texte de commande ; `null` hors de la forme permise. Pure. */
export function readLaunchCommandText(
  text: unknown,
): { action: LaunchAction; issueNumber: number } | null {
  if (typeof text !== "string" || !LAUNCH_TEXT_PATTERN.test(text)) return null;
  const [word, ref] = text.split(" ");
  if (!isLaunchAction(word)) return null;
  return { action: word, issueNumber: Number(ref.slice(1)) };
}

export const LAUNCH_NOT_ALLOWED_MESSAGE = "Ce lancement n'est pas possible pour ce statut.";

/**
 * Ce que décide un lancement avant tout appel : `null` s'il est permis, sinon
 * le message du refus. Analyse : ticket Reçu, tout type. Développement :
 * ticket Validé, d'un autre type que Question. Une Issue est requise.
 */
export function launchPrecondition(
  args: { status: TicketStatus; type: TicketType; hasIssue: boolean },
  action: LaunchAction,
): string | null {
  if (!args.hasIssue) return "Ce ticket n'a pas encore d'Issue GitHub.";
  if (args.status !== LAUNCH_FROM_STATUS[action]) return LAUNCH_NOT_ALLOWED_MESSAGE;
  if (action === "developpement" && args.type === "question") return LAUNCH_NOT_ALLOWED_MESSAGE;
  return null;
}

/** Échéance d'un lancement : l'instant à partir duquel il peut être relancé. */
export function launchRetryAfterMs(action: LaunchAction, launchedAtMs: number): number {
  return launchedAtMs + LAUNCH_RETRY_MS[action];
}

/** Une entrée d'historique, lue sans supposer sa forme (dates en millisecondes). */
export interface LaunchEntryView {
  action: unknown;
  outcome: unknown;
  from_status: unknown;
  launched_at_ms: number | null;
  retry_after_ms: number | null;
}

/**
 * L'état d'un type de lancement sur un ticket, d'après son historique.
 *
 * Seule compte la dernière entrée de ce type (plus grand `launched_at`).
 * Elle est « en cours » si elle a abouti ou si son résultat est inconnu
 * (`launched`, `unknown`), si le ticket a toujours le statut d'où elle est
 * partie (`from_status`) et si son échéance (`retry_after`) n'est pas
 * passée. Échéance passée, mêmes conditions : relance proposée. Une entrée
 * en échec, sans date, sans échéance, ou partie d'un autre statut ne bloque
 * rien. Pure ; fixture `ticket_decisions.json`, section `launch_runs`.
 */
export function launchRunState(args: {
  entries: readonly LaunchEntryView[];
  action: LaunchAction;
  rawStatus: unknown;
  nowMs: number;
}): { running: boolean; runningSinceMs: number | null; relaunchOfMs: number | null } {
  const none = { running: false, runningSinceMs: null, relaunchOfMs: null };
  let last: LaunchEntryView | null = null;
  for (const e of args.entries) {
    if (e.action !== args.action || e.launched_at_ms === null) continue;
    if (last === null || e.launched_at_ms > (last.launched_at_ms ?? -Infinity)) last = e;
  }
  if (last === null || last.launched_at_ms === null) return none;
  if (last.outcome !== "launched" && last.outcome !== "unknown") return none;
  if (typeof args.rawStatus !== "string" || last.from_status !== args.rawStatus) return none;
  if (last.retry_after_ms === null) return none;
  if (args.nowMs < last.retry_after_ms) {
    return { running: true, runningSinceMs: last.launched_at_ms, relaunchOfMs: null };
  }
  return { running: false, runningSinceMs: null, relaunchOfMs: last.launched_at_ms };
}

const PARIS_DATE_TIME = new Intl.DateTimeFormat("fr-FR", {
  timeZone: "Europe/Paris",
  year: "2-digit",
  month: "2-digit",
  day: "2-digit",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
});

function parisParts(ms: number): Record<string, string> {
  const out: Record<string, string> = {};
  for (const p of PARIS_DATE_TIME.formatToParts(new Date(ms))) out[p.type] = p.value;
  return out;
}

/** « 13/10/26 », heure de Paris. */
export function parisShortDate(ms: number): string {
  const p = parisParts(ms);
  return `${p.day}/${p.month}/${p.year}`;
}

/** « 14:05 », heure de Paris. */
export function parisHourMinute(ms: number): string {
  const p = parisParts(ms);
  return `${p.hour}:${p.minute}`;
}

/** Message d'un lancement refusé parce qu'un lancement du même type est en cours. */
export function launchRunningMessage(
  action: LaunchAction,
  launchedAtMs: number,
  retryAfterMs: number,
): string {
  const what = action === "analyse" ? "Une analyse a été lancée" : "Un développement a été lancé";
  return (
    `${what} le ${parisShortDate(launchedAtMs)} à ${parisHourMinute(launchedAtMs)}. ` +
    `Attendez son résultat ou relancez après ${parisHourMinute(retryAfterMs)}.`
  );
}

/** Message du plafond quotidien des lancements. */
export function launchQuotaMessage(limit: number): string {
  return `Vous avez lancé ${limit} sessions aujourd'hui. Réessayez demain.`;
}

/**
 * Le plafond lu dans `app_config/tickets.launches_per_day` : document ou champ
 * absent → [DEFAULT_LAUNCHES_PER_DAY] ; présent mais pas un entier de 1 à
 * [MAX_LAUNCHES_PER_DAY] → `null`, et le lancement est refusé.
 */
export function readLaunchesPerDay(data: Record<string, unknown> | undefined): number | null {
  const value = data?.launches_per_day;
  if (value === undefined) return DEFAULT_LAUNCHES_PER_DAY;
  return typeof value === "number" &&
    Number.isInteger(value) &&
    value > 0 &&
    value <= MAX_LAUNCHES_PER_DAY
    ? value
    : null;
}

/** Compteur du jour des lancements : `launch_{AAAAMMJJ}`. */
export function launchQuotaDocId(day: string): string {
  return `launch_${day}`;
}

/**
 * Les compteurs affichés par le client (`app_config/tickets_status`), après
 * un lancement compté (`delta` = 1) ou un lancement rendu (`delta` = -1), le
 * jour `day` étant celui où il a été compté.
 *
 * Compter : un compteur d'un autre jour ou d'un autre mois repart de zéro.
 * Rendre : un compteur déjà passé à un autre jour ou à un autre mois reste
 * tel quel (`null` : rien à écrire). Aucun ne descend sous zéro.
 */
export function nextLaunchCounters(
  current: { today?: unknown; month?: unknown },
  day: string,
  delta: 1 | -1,
): {
  today: { day: string; count: number } | null;
  month: { month: string; count: number } | null;
} {
  const read = (raw: unknown, key: "day" | "month", value: string): number | null => {
    if (raw === null || typeof raw !== "object") return null;
    const r = raw as Record<string, unknown>;
    if (r[key] !== value) return null;
    return typeof r.count === "number" && Number.isFinite(r.count) && r.count > 0 ? r.count : 0;
  };
  const month = day.slice(0, 6);
  const today = read(current.today, "day", day);
  const monthly = read(current.month, "month", month);
  if (delta === 1) {
    return {
      today: { day, count: (today ?? 0) + 1 },
      month: { month, count: (monthly ?? 0) + 1 },
    };
  }
  return {
    today: today === null ? null : { day, count: Math.max(0, today - 1) },
    month: monthly === null ? null : { month, count: Math.max(0, monthly - 1) },
  };
}

// ── Signature du webhook ────────────────────────────────────────────────────

/**
 * Vrai si `signatureHeader` (`X-Hub-Signature-256`, `sha256=<hex>`) est le
 * HMAC SHA-256 de `rawBody` sous `secret`. Comparaison à temps constant.
 * Secret vide, en-tête absent ou mal formé : `false`.
 */
export function verifyGithubSignature(
  rawBody: Buffer,
  signatureHeader: string | null | undefined,
  secret: string,
): boolean {
  if (!secret || typeof signatureHeader !== "string") return false;
  const match = /^sha256=([0-9a-f]{64})$/i.exec(signatureHeader.trim());
  if (!match) return false;
  const expected = createHmac("sha256", secret).update(rawBody).digest();
  const received = Buffer.from(match[1], "hex");
  return received.length === expected.length && timingSafeEqual(received, expected);
}

// ── Jour du plafond et plafonds ─────────────────────────────────────────────

const PARIS_DAY = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Europe/Paris",
  year: "numeric",
  month: "2-digit",
  day: "2-digit",
});

/** Jour calendaire Europe/Paris, `AAAAMMJJ`. */
export function parisDay(at: Date): string {
  const parts = PARIS_DAY.formatToParts(at);
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
  return `${get("year")}${get("month")}${get("day")}`;
}

/** Compteur du membre pour un jour : `{uid}_{AAAAMMJJ}`. */
export function memberQuotaDocId(uid: string, day: string): string {
  return `${uid}_${day}`;
}

/** Compteur de la famille pour un jour : `_global_{AAAAMMJJ}`. */
export function globalQuotaDocId(day: string): string {
  return `_global_${day}`;
}

/** Réglage par défaut du produit, appliqué quand `app_config/tickets` n'existe pas. */
export const DEFAULT_TICKET_LIMITS = { per_member_per_day: 5, global_per_day: 30 } as const;

export interface TicketLimits {
  per_member_per_day: number;
  global_per_day: number;
}

/**
 * Les plafonds lus dans `app_config/tickets`.
 *
 * Document absent : le réglage par défaut (5 et 30). Champ absent : sa valeur
 * par défaut. Champ présent mais illisible (pas un entier positif) : `null`,
 * et l'envoi est refusé — un plafond inventé à la place d'un réglage illisible
 * serait une valeur fausse présentée comme réglée.
 */
export function readTicketLimits(data: Record<string, unknown> | undefined): TicketLimits | null {
  if (data === undefined) return { ...DEFAULT_TICKET_LIMITS };
  const read = (field: keyof TicketLimits): number | null => {
    const value = data[field];
    if (value === undefined) return DEFAULT_TICKET_LIMITS[field];
    return typeof value === "number" && Number.isInteger(value) && value > 0 ? value : null;
  };
  const perMember = read("per_member_per_day");
  const global = read("global_per_day");
  if (perMember === null || global === null) return null;
  return { per_member_per_day: perMember, global_per_day: global };
}

/** Ce que décide le plafond, compteurs du jour lus. `null` : l'envoi passe. */
export function quotaRefusal(args: {
  isAdmin: boolean;
  memberCount: number;
  globalCount: number;
  limits: TicketLimits;
}): { reason: "member_daily_limit" | "global_daily_limit"; limit: number } | null {
  if (args.isAdmin) return null;
  if (args.memberCount >= args.limits.per_member_per_day) {
    return { reason: "member_daily_limit", limit: args.limits.per_member_per_day };
  }
  if (args.globalCount >= args.limits.global_per_day) {
    return { reason: "global_daily_limit", limit: args.limits.global_per_day };
  }
  return null;
}

/** Message rendu au membre pour un plafond atteint. */
export function quotaMessage(reason: "member_daily_limit" | "global_daily_limit", limit: number) {
  return reason === "member_daily_limit"
    ? `Vous avez envoyé ${limit} tickets aujourd'hui, réessayez demain.`
    : "Trop de tickets ont été envoyés aujourd'hui par la famille. Réessayez demain.";
}

// ── Chemin de la capture ────────────────────────────────────────────────────

/** Chemins de capture admis pour un ticket : `.png` ou `.jpg`. */
export function screenshotPaths(uid: string, ticketId: string): string[] {
  return [`tickets/${uid}/${ticketId}/screenshot.png`, `tickets/${uid}/${ticketId}/screenshot.jpg`];
}

/** Type MIME attendu pour un chemin de capture admis. */
export function screenshotContentType(path: string): "image/png" | "image/jpeg" {
  return path.endsWith(".png") ? "image/png" : "image/jpeg";
}

export const SCREENSHOT_MAX_BYTES = 5 * 1024 * 1024;

/** Octets lus en tête d'une capture pour en vérifier la signature. */
export const SCREENSHOT_SIGNATURE_BYTES = 8;

const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
const JPEG_SIGNATURE = [0xff, 0xd8, 0xff];

/**
 * Vrai si les premiers octets d'une capture sont ceux du format annoncé :
 * signature PNG sur 8 octets, ou `FF D8 FF` pour un JPEG. Le type MIME posé
 * par le client à l'envoi ne prouve rien sur le contenu.
 */
export function screenshotBytesMatch(head: Uint8Array, contentType: string): boolean {
  const signature =
    contentType === "image/png"
      ? PNG_SIGNATURE
      : contentType === "image/jpeg"
        ? JPEG_SIGNATURE
        : null;
  if (signature === null || head.length < signature.length) return false;
  return signature.every((byte, i) => head[i] === byte);
}

/** Identifiant de document Firestore plausible (pas de `/`, borné). */
export function isPlausibleDocId(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(value);
}
