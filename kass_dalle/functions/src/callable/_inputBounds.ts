/**
 * Bornes des entrées qu'un client envoie à un modèle, et journal de leur taille.
 *
 * Les callables recopiaient dans le prompt ce que le client envoyait, sans
 * limite de taille : un texte de plusieurs millions de caractères partait tel
 * quel chez Gemini ou Anthropic, et se facturait au jeton. Les bornes posées
 * ici sont **larges** : aucun texte réel n'y touche, seuls les envois de
 * plusieurs centaines de milliers de jetons sont refusés.
 *
 * Refus, jamais troncature : couper un texte en silence ferait travailler le
 * modèle sur une recette amputée, et rien ne le dirait. Le refus part en
 * `invalid-argument`, avant tout appel de modèle et toute réservation de
 * budget, avec le champ et la limite dans le message.
 *
 * La taille réelle de chaque champ est journalisée à chaque appel (message
 * « Taille des entrées IA », jamais le contenu) : c'est ce relevé qui permettra
 * de resserrer les bornes poste par poste.
 *
 * Les fonctions `requireBounded*` sont pures, testées par
 * `tests/inputBounds.test.ts`.
 */

import { HttpsError } from "firebase-functions/v2/https";
import { logInfo, logWarn } from "../logging";

// ── Bornes ───────────────────────────────────────────────────────────────────

/**
 * Texte collé à extraire (`extractRecipeFromTextFn.text`).
 *
 * Une page de livre pèse deux à quatre mille caractères ; un chapitre entier
 * collé d'un coup, quelques dizaines de milliers. 200 000 caractères font
 * environ 50 000 jetons.
 */
export const PASTED_TEXT_MAX_CHARS = 200_000;

/**
 * Une recette : CookLang, markdown, contexte d'illustration, préférences.
 *
 * Une recette longue fait dix mille caractères. 100 000 caractères font
 * environ 25 000 jetons.
 */
export const RECIPE_TEXT_MAX_CHARS = 100_000;

/** Instruction libre, requête de recherche, consigne, titre, libellé, date. */
export const SHORT_TEXT_MAX_CHARS = 5_000;

/** Liste envoyée au modèle : ingrédients, créneaux, titres à éviter. */
export const LIST_MAX_ITEMS = 500;

/**
 * Corpus de recettes : la bibliothèque entière que la recherche et le
 * planning envoient au modèle.
 *
 * Elle grandit avec la famille ; la borner à 500 refuserait un jour une
 * bibliothèque réelle. Chaque élément est un résumé de quelques centaines de
 * caractères, borné par `STRUCTURED_ITEM_MAX_CHARS`.
 */
export const CORPUS_MAX_ITEMS = 5_000;

/** Un élément structuré d'une liste (ingrédient, résumé de recette), en JSON. */
export const STRUCTURED_ITEM_MAX_CHARS = 20_000;

/** Un objet structuré (tags, contraintes du jour), mesuré en JSON. */
export const STRUCTURED_OBJECT_MAX_CHARS = 100_000;

/** Image de couverture (`extractBookCoverFn.bytesBase64`), octets décodés. */
export const COVER_IMAGE_MAX_BYTES = 8 * 1024 * 1024;

/**
 * Page photographiée (`detectAndCropIllustrationsFn.bytesBase64`), octets décodés.
 *
 * Plus large que la couverture : le client envoie le scan tel qu'il est stocké,
 * et la quarantaine en accepte jusqu'à 50 Mo. 20 Mo encodés en base64 font
 * 27 Mo, sous le plafond de 32 Mio d'une requête Cloud Run.
 */
export const PAGE_IMAGE_MAX_BYTES = 20 * 1024 * 1024;

// ── Erreurs ──────────────────────────────────────────────────────────────────

/** Unité d'une taille mesurée. */
export type SizeUnit = "chars" | "items" | "bytes";

/**
 * Refus pour dépassement d'une borne.
 *
 * Une `HttpsError` (`invalid-argument`), donc rendue telle quelle au client ;
 * la classe propre permet seulement de la distinguer d'un champ absent ou mal
 * typé, pour journaliser le refus.
 */
export class InputBoundExceededError extends HttpsError {
  constructor(
    readonly field: string,
    readonly size: number,
    readonly max: number,
    readonly unit: SizeUnit,
    message: string,
  ) {
    super("invalid-argument", message, { field, size, max, unit });
  }
}

/** 200000 → « 200 000 », sans dépendre de la locale de l'environnement. */
export function formatCount(n: number): string {
  return String(Math.trunc(n)).replace(/\B(?=(\d{3})+(?!\d))/g, " ");
}

/** Octets en mégaoctets, une décimale, virgule française. */
function formatMegabytes(bytes: number): string {
  const mb = bytes / (1024 * 1024);
  const rounded = Number.isInteger(mb) ? String(mb) : mb.toFixed(1);
  return rounded.replace(".", ",");
}

function missing(field: string): HttpsError {
  return new HttpsError("invalid-argument", `Le champ « ${field} » est requis.`);
}

function wrongType(field: string, expected: string): HttpsError {
  return new HttpsError("invalid-argument", `Le champ « ${field} » doit être ${expected}.`);
}

// ── Fonctions pures ──────────────────────────────────────────────────────────

export interface TextBound {
  field: string;
  max: number;
  /** Absent, `null` ou chaîne vide : refusé. Sinon, rendu `undefined`. */
  required?: boolean;
}

/**
 * Un texte d'au plus `max` caractères (unités UTF-16, comme `String.length`).
 *
 * Requis : absent ou vide est refusé — c'est ce que faisaient les `if (!x)`
 * qu'elle remplace. Facultatif : absent rend `undefined`, une chaîne vide est
 * rendue telle quelle.
 */
export function requireBoundedText(value: unknown, opts: TextBound & { required: true }): string;
export function requireBoundedText(value: unknown, opts: TextBound): string | undefined;
export function requireBoundedText(value: unknown, opts: TextBound): string | undefined {
  const { field, max, required = false } = opts;
  if (value === undefined || value === null) {
    if (required) throw missing(field);
    return undefined;
  }
  if (typeof value !== "string") throw wrongType(field, "un texte");
  if (required && value.length === 0) throw missing(field);
  if (value.length > max) {
    throw new InputBoundExceededError(
      field,
      value.length,
      max,
      "chars",
      `Texte trop long : « ${field} » dépasse la limite de ${formatCount(max)} caractères ` +
        `(${formatCount(value.length)} reçus).`,
    );
  }
  return value;
}

export interface ListBound {
  field: string;
  maxItems: number;
  /**
   * Taille maximale d'un élément, en caractères : sa longueur pour un texte,
   * celle de son JSON pour un objet. Absent : les éléments ne sont pas mesurés.
   */
  maxItemChars?: number;
  /** Absent ou `null` : refusé. Une liste vide est acceptée. */
  required?: boolean;
}

/** Taille d'un élément de liste : sa longueur, ou celle de son JSON. */
export function itemChars(item: unknown): number {
  if (typeof item === "string") return item.length;
  if (item === undefined) return 0;
  return JSON.stringify(item)?.length ?? 0;
}

/**
 * Une liste d'au plus `maxItems` éléments, chacun d'au plus `maxItemChars`.
 *
 * Les éléments ne sont pas filtrés ni retypés : la callable les transmet
 * comme avant. Seule la taille est contrôlée.
 */
export function requireBoundedList<T = unknown>(
  value: unknown,
  opts: ListBound & { required: true },
): T[];
export function requireBoundedList<T = unknown>(value: unknown, opts: ListBound): T[] | undefined;
export function requireBoundedList<T = unknown>(value: unknown, opts: ListBound): T[] | undefined {
  const { field, maxItems, maxItemChars, required = false } = opts;
  if (value === undefined || value === null) {
    if (required) throw missing(field);
    return undefined;
  }
  if (!Array.isArray(value)) throw wrongType(field, "une liste");
  if (value.length > maxItems) {
    throw new InputBoundExceededError(
      field,
      value.length,
      maxItems,
      "items",
      `Liste trop longue : « ${field} » dépasse la limite de ${formatCount(maxItems)} éléments ` +
        `(${formatCount(value.length)} reçus).`,
    );
  }
  if (maxItemChars !== undefined) {
    value.forEach((item, index) => {
      const chars = itemChars(item);
      if (chars > maxItemChars) {
        const itemField = `${field}[${index}]`;
        throw new InputBoundExceededError(
          itemField,
          chars,
          maxItemChars,
          "chars",
          `Élément trop long : « ${itemField} » dépasse la limite de ` +
            `${formatCount(maxItemChars)} caractères (${formatCount(chars)} reçus).`,
        );
      }
    });
  }
  return value as T[];
}

export interface ObjectBound {
  field: string;
  /** Taille maximale de l'objet sérialisé en JSON, en caractères. */
  maxChars: number;
  required?: boolean;
}

/** Un objet (pas une liste) dont le JSON tient en `maxChars` caractères. */
export function requireBoundedObject<T extends object = Record<string, unknown>>(
  value: unknown,
  opts: ObjectBound & { required: true },
): T;
export function requireBoundedObject<T extends object = Record<string, unknown>>(
  value: unknown,
  opts: ObjectBound,
): T | undefined;
export function requireBoundedObject<T extends object = Record<string, unknown>>(
  value: unknown,
  opts: ObjectBound,
): T | undefined {
  const { field, maxChars, required = false } = opts;
  if (value === undefined || value === null) {
    if (required) throw missing(field);
    return undefined;
  }
  if (typeof value !== "object" || Array.isArray(value)) throw wrongType(field, "un objet");
  const chars = itemChars(value);
  if (chars > maxChars) {
    throw new InputBoundExceededError(
      field,
      chars,
      maxChars,
      "chars",
      `Objet trop long : « ${field} » dépasse la limite de ${formatCount(maxChars)} caractères ` +
        `(${formatCount(chars)} reçus).`,
    );
  }
  return value as T;
}

export interface NumberBound {
  field: string;
  min: number;
  max: number;
  /** Exige un entier (jour de la semaine, par exemple). */
  integer?: boolean;
  required?: boolean;
}

/**
 * Un nombre fini compris entre `min` et `max`.
 *
 * Un nombre recopié dans un prompt se borne comme un texte : sans ce contrôle,
 * une chaîne de plusieurs mégaoctets posée à la place d'un nombre de portions
 * partait telle quelle au modèle.
 */
export function requireBoundedNumber(
  value: unknown,
  opts: NumberBound & { required: true },
): number;
export function requireBoundedNumber(value: unknown, opts: NumberBound): number | undefined;
export function requireBoundedNumber(value: unknown, opts: NumberBound): number | undefined {
  const { field, min, max, integer = false, required = false } = opts;
  if (value === undefined || value === null) {
    if (required) throw missing(field);
    return undefined;
  }
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw wrongType(field, integer ? "un nombre entier" : "un nombre");
  }
  if (integer && !Number.isInteger(value)) throw wrongType(field, "un nombre entier");
  if (value < min || value > max) {
    throw new HttpsError(
      "invalid-argument",
      `Le champ « ${field} » doit être compris entre ${formatCount(min)} et ${formatCount(max)}.`,
    );
  }
  return value;
}

export interface Base64Bound {
  field: string;
  /** Taille maximale une fois décodée, en octets. */
  maxBytes: number;
  required?: boolean;
}

/** Alphabet base64 standard, remplissage facultatif. Ni espace, ni saut de ligne. */
const BASE64_PATTERN = /^[A-Za-z0-9+/]*={0,2}$/;

/**
 * Taille décodée d'une chaîne base64, sans la décoder ; `null` si elle est
 * mal formée.
 *
 * `Buffer.from(x, "base64")` ignore les caractères qu'il ne reconnaît pas :
 * une chaîne invalide rendait un tampon tronqué, envoyé au modèle comme une
 * image. On la refuse ici.
 */
export function decodedBase64Length(value: string): number | null {
  if (!BASE64_PATTERN.test(value)) return null;
  const padding = value.endsWith("==") ? 2 : value.endsWith("=") ? 1 : 0;
  if (padding > 0 && value.length % 4 !== 0) return null;
  if (value.length % 4 === 1) return null;
  return Math.floor(((value.length - padding) * 3) / 4);
}

/**
 * Une image en base64 d'au plus `maxBytes` octets décodés, rendue décodée.
 *
 * La taille est contrôlée avant le décodage : une chaîne énorme n'est jamais
 * copiée en mémoire.
 */
export function requireBoundedBase64(
  value: unknown,
  opts: Base64Bound & { required: true },
): Buffer;
export function requireBoundedBase64(value: unknown, opts: Base64Bound): Buffer | undefined;
export function requireBoundedBase64(value: unknown, opts: Base64Bound): Buffer | undefined {
  const { field, maxBytes, required = false } = opts;
  if (value === undefined || value === null) {
    if (required) throw missing(field);
    return undefined;
  }
  if (typeof value !== "string") throw wrongType(field, "un texte base64");
  if (required && value.length === 0) throw missing(field);
  const bytes = decodedBase64Length(value);
  if (bytes === null) {
    throw new HttpsError(
      "invalid-argument",
      `Le champ « ${field} » n'est pas un encodage base64 valide.`,
    );
  }
  if (bytes > maxBytes) {
    throw new InputBoundExceededError(
      field,
      bytes,
      maxBytes,
      "bytes",
      `Image trop lourde : « ${field} » dépasse la limite de ${formatMegabytes(maxBytes)} Mo ` +
        `(${formatMegabytes(bytes)} Mo reçus).`,
    );
  }
  return Buffer.from(value, "base64");
}

// ── Relevé des tailles ───────────────────────────────────────────────────────

/**
 * Applique les bornes et retient la taille de chaque champ lu.
 *
 * Une liste est relevée deux fois : `sizes.recipes` en éléments, et
 * `sizes.recipes_chars` en caractères JSON — c'est le second qui dit combien de
 * jetons elle coûte. Un objet est relevé en caractères JSON, une image en
 * octets décodés, un texte en caractères, un nombre en caractères de son
 * écriture décimale.
 */
export class AiInputSizes {
  readonly sizes: Record<string, number> = {};

  text(value: unknown, opts: TextBound & { required: true }): string;
  text(value: unknown, opts: TextBound): string | undefined;
  text(value: unknown, opts: TextBound): string | undefined {
    const out = requireBoundedText(value, opts);
    if (out !== undefined) this.sizes[opts.field] = out.length;
    return out;
  }

  list<T = unknown>(value: unknown, opts: ListBound & { required: true }): T[];
  list<T = unknown>(value: unknown, opts: ListBound): T[] | undefined;
  list<T = unknown>(value: unknown, opts: ListBound): T[] | undefined {
    const out = requireBoundedList<T>(value, opts);
    if (out !== undefined) {
      this.sizes[opts.field] = out.length;
      this.sizes[`${opts.field}_chars`] = out.reduce((sum, item) => sum + itemChars(item), 0);
    }
    return out;
  }

  object<T extends object = Record<string, unknown>>(
    value: unknown,
    opts: ObjectBound & { required: true },
  ): T;
  object<T extends object = Record<string, unknown>>(
    value: unknown,
    opts: ObjectBound,
  ): T | undefined;
  object<T extends object = Record<string, unknown>>(
    value: unknown,
    opts: ObjectBound,
  ): T | undefined {
    const out = requireBoundedObject<T>(value, opts);
    if (out !== undefined) this.sizes[opts.field] = itemChars(out);
    return out;
  }

  base64(value: unknown, opts: Base64Bound & { required: true }): Buffer;
  base64(value: unknown, opts: Base64Bound): Buffer | undefined;
  base64(value: unknown, opts: Base64Bound): Buffer | undefined {
    const out = requireBoundedBase64(value, opts);
    if (out !== undefined) this.sizes[opts.field] = out.length;
    return out;
  }

  /** Un nombre est relevé en caractères de son écriture décimale. */
  number(value: unknown, opts: NumberBound & { required: true }): number;
  number(value: unknown, opts: NumberBound): number | undefined;
  number(value: unknown, opts: NumberBound): number | undefined {
    const out = requireBoundedNumber(value, opts);
    if (out !== undefined) this.sizes[opts.field] = String(out).length;
    return out;
  }

  /**
   * Relève une taille sans poser de borne : pour un champ que la callable
   * borne déjà elle-même (consigne des idées de repas, tronquée à dessein).
   */
  measure(field: string, size: number): void {
    this.sizes[field] = size;
  }
}

/** Message fixe des relevés, pour les filtrer dans Cloud Logging. */
export const INPUT_SIZES_LOG_MESSAGE = "Taille des entrées IA";

export interface InputSizesLogger {
  info: typeof logInfo;
  warn: typeof logWarn;
}

const defaultLogger: InputSizesLogger = { info: logInfo, warn: logWarn };

/**
 * Lit les entrées d'une callable sous leurs bornes, puis journalise leur taille.
 *
 * À appeler après les gardes d'accès et AVANT tout appel de modèle : un refus
 * ne réserve aucun budget et ne coûte rien.
 *
 * - Accepté : `logInfo`, extra `{ feature, sizes }`.
 * - Refusé pour dépassement : `logWarn`, même forme, plus `refused` (champ,
 *   taille, borne, unité), puis l'erreur repart vers le client.
 * - Champ absent ou mal typé : l'erreur repart sans journal, comme avant.
 */
export async function readAiInputs<T>(
  scope: { feature: string; userId: string; correlationId: string },
  read: (inputs: AiInputSizes) => T,
  logger: InputSizesLogger = defaultLogger,
): Promise<T> {
  const inputs = new AiInputSizes();
  let out: T;
  try {
    out = read(inputs);
  } catch (err) {
    if (err instanceof InputBoundExceededError) {
      await logger.warn({
        message: INPUT_SIZES_LOG_MESSAGE,
        feature: scope.feature,
        userId: scope.userId,
        correlationId: scope.correlationId,
        extra: {
          feature: scope.feature,
          sizes: { ...inputs.sizes, [err.field]: err.size },
          refused: { field: err.field, size: err.size, max: err.max, unit: err.unit },
        },
      });
    }
    throw err;
  }
  await logger.info({
    message: INPUT_SIZES_LOG_MESSAGE,
    feature: scope.feature,
    userId: scope.userId,
    correlationId: scope.correlationId,
    extra: { feature: scope.feature, sizes: inputs.sizes },
  });
  return out;
}
