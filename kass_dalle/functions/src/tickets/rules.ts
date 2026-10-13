/**
 * Tickets : règles pures, testées par `tests/tickets.test.ts`.
 *
 * Rien ici ne lit Firestore ni GitHub. On y trouve :
 *  - la lecture des entrées de `submitTicket` (types, bornes, écran) ;
 *  - le corps de l'Issue publiée sur un dépôt PUBLIC, construit sur un gabarit
 *    fixe : ni nom, ni adresse, ni uid, ni capture, mentions `@` neutralisées ;
 *  - la correspondance état GitHub → statut du ticket, et la règle de
 *    non-recul ;
 *  - le filtre de la réponse de l'administrateur (`reply_text`) ;
 *  - la vérification de la signature HMAC d'un webhook ;
 *  - le jour calendaire Europe/Paris du plafond, et la lecture des plafonds.
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

function screenLabel(screen: string): string {
  if (screen === SCREEN_OTHER) return "Autre écran";
  if (screen === SCREEN_UNKNOWN) return "Non précisé";
  return `\`${screen}\``;
}

/** Titre de l'Issue : celui du ticket, mentions neutralisées. */
export function buildIssueTitle(title: string): string {
  return neutralizeMentions(singleLine(title));
}

/**
 * Corps de l'Issue, sur un gabarit fixe.
 *
 * Ce qui part : type, écran (modèle de route), version, plateforme,
 * référence opaque (l'identifiant du document `tickets`), description.
 * Ce qui ne part jamais : nom, adresse, uid, capture, contenu de recette.
 * Le texte du membre n'est pas échappé en Markdown, seulement privé de ses
 * mentions.
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
    neutralizeMentions(args.description),
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

// ── Réponse de l'administrateur ─────────────────────────────────────────────

const REPLY_PREFIX = /^Réponse\s*:\s*/u;

/**
 * La réponse montrée au membre, ou `null` si ce commentaire n'en est pas une.
 *
 * Seul un commentaire de `maintainer` qui commence par « Réponse : » compte ;
 * le préfixe est retiré. Les espaces (y compris insécables) autour des deux
 * points sont tolérés, et le « é » composé comme décomposé.
 */
export function replyFromComment(
  comment: { authorLogin: string | null | undefined; body: string | null | undefined },
  maintainer: string,
): string | null {
  if (!comment.authorLogin || comment.authorLogin !== maintainer) return null;
  if (typeof comment.body !== "string") return null;
  const body = comment.body.normalize("NFC").replace(/\r\n?/g, "\n").trimStart();
  if (!REPLY_PREFIX.test(body)) return null;
  const text = body.replace(REPLY_PREFIX, "").trim();
  return text.length > 0 ? text : null;
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

/** Identifiant de document Firestore plausible (pas de `/`, borné). */
export function isPlausibleDocId(value: unknown): value is string {
  return typeof value === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(value);
}
