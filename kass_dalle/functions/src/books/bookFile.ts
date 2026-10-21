/**
 * Lecture d'un livre entier — PDF, EPUB ou document Word — et découpage en
 * tranches que le pipeline d'import sait lire.
 *
 * Un livre ne se transcrit pas en un appel : la réponse d'un modèle plafonne, et
 * l'appel coûterait tout d'un coup. On le découpe donc en tranches, chacune
 * devenant un job d'import ordinaire. Une recette n'a aucune raison de tenir
 * dans une seule tranche : chacune porte, après ses pages propres, une page de
 * contexte qui sert à terminer la dernière recette entamée. Voir
 * `bookWindowPreamble` pour ce que le modèle en fait.
 *
 * Aucun appel d'IA ici. Ouvrir un livre, compter ses pages, le découper : c'est
 * du code déterministe, et il se teste sans clé ni réseau.
 */

import { posix } from "node:path";
import { BoundedZip } from "../utils/boundedZip";
import type { PDFDocument } from "pdf-lib";

import { logError } from "../logging";
import { docxToPlainText } from "../utils/docx";
import { BOOK_WINDOW_CONTEXT_MARKER, type BookWindowInfo } from "../gemini/promptsExtraction";

// ── Constantes de découpage ─────────────────────────────────────────────────

/** Pages transcrites par tranche. Une recette de livre tient en une ou deux pages. */
export const PDF_OWNED_PAGES = 3;

/** Pages de contexte ajoutées après les pages transcrites. */
export const PDF_CONTEXT_PAGES = 1;

/** Caractères transcrits par tranche de texte : environ trois pages de livre. */
export const TEXT_OWNED_CHARS = 6000;

/** Caractères de contexte ajoutés après le texte transcrit. */
export const TEXT_CONTEXT_CHARS = 1500;

/**
 * Poids maximal d'une tranche PDF.
 *
 * Le fichier part chez le modèle en base64 dans le corps de la requête, dont le
 * plafond est de vingt mégaoctets chez Gemini : douze mégaoctets de PDF en font
 * seize une fois encodés. Une tranche plus lourde est coupée en deux.
 */
export const MAX_CHUNK_BYTES = 12 * 1024 * 1024;

/** Nombre maximal de tranches — donc de jobs d'import — pour un seul livre. */
export const MAX_WINDOWS = 400;

/**
 * Sous-dossier de `quarantine/{uid}/` — puis de `scans/{uid}/` une fois promu —
 * où arrive un livre entier. Il porte un plafond de taille à part (voir
 * `MAX_BOOK_UPLOAD_SIZE_BYTES`), et la règle Storage le désigne par ce nom.
 */
export const BOOK_UPLOAD_FOLDER = "livres";

/** Types MIME des livres acceptés. */
export const PDF_MIME_TYPE = "application/pdf";
export const EPUB_MIME_TYPE = "application/epub+zip";
export const DOCX_MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document";

export type BookFileKind = "pdf" | "epub" | "docx";

/**
 * Erreur dont le message s'adresse à l'utilisateur.
 *
 * Un fichier illisible le reste à chaque tentative : le processeur ne la
 * réessaie pas, et le message part tel quel sur le job.
 *
 * Le texte de la bibliothèque qui a échoué (pdf-lib, JSZip, lecteur Word) ne
 * va jamais dans le message : il va dans `detail`, que le processeur écrit
 * dans `logError` et dans la dead letter (`last_error`), lus par
 * l'administrateur.
 */
export class BookFileError extends Error {
  readonly detail: string | null;

  constructor(message: string, cause?: unknown) {
    super(message);
    this.name = "BookFileError";
    this.detail =
      cause === undefined ? null : cause instanceof Error ? cause.message : String(cause);
  }
}

/** Message d'un EPUB qui ne s'ouvre pas ou ne se lit pas (archive abîmée ou au-delà des bornes). */
export const EPUB_UNREADABLE_MESSAGE =
  "Ce fichier EPUB n'a pas pu être ouvert : il est abîmé ou trop volumineux. " +
  "Exportez-le de nouveau, ou découpez-le, puis recommencez.";

/**
 * Message d'une archive qui s'ouvre mais n'a pas la structure d'un EPUB
 * (`META-INF/container.xml` absent, fichier OPF introuvable). Le détail
 * technique va dans `BookFileError.detail`, lu par les journaux.
 */
export const EPUB_INVALID_MESSAGE =
  "Ce fichier EPUB est incomplet et ne peut pas être lu. " +
  "Exportez-le de nouveau depuis le logiciel qui l'a créé, ou importez le livre en PDF.";

/**
 * Livre sans texte : ses pages sont des images. Un PDF se lit page par page
 * comme une photo (les tranches PDF partent au modèle telles quelles) ; le
 * message propose donc ce chemin.
 */
export const EPUB_NO_TEXT_MESSAGE =
  "Ce fichier EPUB ne contient pas de texte : ses pages sont des images. " +
  "Convertissez-le en PDF, ou importez le livre en PDF si vous l'avez : les pages du PDF seront lues comme des photos.";

/** Document Word sans texte (images seules). Même chemin que l'EPUB : le PDF. */
export const DOCX_NO_TEXT_MESSAGE =
  "Ce document Word ne contient pas de texte, seulement des images. " +
  "Enregistrez-le en PDF depuis Word, puis importez le PDF : les pages du PDF seront lues comme des photos.";

/** Le message d'une erreur pour les journaux : message, puis détail technique s'il existe. */
export function technicalErrorText(err: unknown): string {
  if (err instanceof BookFileError && err.detail) return `${err.message} (${err.detail})`;
  return err instanceof Error ? err.message : String(err);
}

/** Le format d'un livre, d'après son type MIME puis son extension. */
export function detectBookFileKind(
  mimeType: string | undefined,
  fileName: string | undefined,
): BookFileKind | null {
  const mime = (mimeType ?? "").split(";")[0].trim().toLowerCase();
  if (mime === PDF_MIME_TYPE) return "pdf";
  if (mime === EPUB_MIME_TYPE) return "epub";
  if (mime === DOCX_MIME) return "docx";
  const dot = (fileName ?? "").lastIndexOf(".");
  const ext = dot < 0 ? "" : (fileName ?? "").substring(dot + 1).toLowerCase();
  if (ext === "pdf") return "pdf";
  if (ext === "epub") return "epub";
  if (ext === "docx") return "docx";
  return null;
}

// ── Métadonnées ─────────────────────────────────────────────────────────────

export interface BookMetadata {
  titre: string;
  sousTitre: string | null;
  auteur: string;
  editeur: string | null;
  serie: string | null;
  annee: number | null;
  langue: string;
  isbn: string | null;
  description: string | null;
  tags: string[];
}

// ── Fenêtres ────────────────────────────────────────────────────────────────

export interface Window {
  index: number;
  /** Rang (à partir de 0) de la première unité transcrite. */
  firstUnit: number;
  /** Unités transcrites. */
  ownedUnits: number;
  /** Unités de contexte qui suivent. */
  contextUnits: number;
}

/**
 * Découpe `totalUnits` unités — des pages — en fenêtres qui se chevauchent
 * d'exactement `context` unités.
 *
 * Chaque unité est transcrite par une fenêtre et une seule. Le contexte est lu
 * par la fenêtre courante et transcrit par la suivante.
 */
export function planWindows(
  totalUnits: number,
  owned: number = PDF_OWNED_PAGES,
  context: number = PDF_CONTEXT_PAGES,
): Window[] {
  if (!Number.isInteger(totalUnits) || totalUnits <= 0) return [];
  const windows: Window[] = [];
  for (let first = 0, index = 0; first < totalUnits; first += owned, index += 1) {
    const ownedUnits = Math.min(owned, totalUnits - first);
    const contextUnits = Math.min(context, totalUnits - first - ownedUnits);
    windows.push({ index, firstUnit: first, ownedUnits, contextUnits });
  }
  return windows;
}

export interface TextWindow {
  index: number;
  /** Le texte à transcrire. */
  owned: string;
  /** Le texte qui suit, pour terminer la dernière recette. Vide pour la dernière fenêtre. */
  context: string;
}

/**
 * Coupe un paragraphe trop long à la dernière fin de phrase avant la limite.
 *
 * Certains EPUB rendent un chapitre entier en un seul bloc. Sans coupe, une
 * fenêtre pèserait le chapitre entier et dépasserait ce que la réponse du modèle
 * peut recopier.
 */
function splitLongParagraph(paragraph: string, max: number): string[] {
  if (paragraph.length <= max) return [paragraph];
  const pieces: string[] = [];
  let rest = paragraph;
  while (rest.length > max) {
    const slice = rest.slice(0, max);
    const cut = Math.max(slice.lastIndexOf(". "), slice.lastIndexOf("; "), slice.lastIndexOf(" "));
    const at = cut > max / 2 ? cut + 1 : max;
    pieces.push(rest.slice(0, at).trim());
    rest = rest.slice(at).trim();
  }
  if (rest.length > 0) pieces.push(rest);
  return pieces;
}

/**
 * Découpe un texte en fenêtres, sans jamais couper un paragraphe en deux — sauf
 * un paragraphe plus long que la fenêtre elle-même.
 */
export function planTextWindows(
  paragraphs: string[],
  ownedChars: number = TEXT_OWNED_CHARS,
  contextChars: number = TEXT_CONTEXT_CHARS,
): TextWindow[] {
  const blocks = paragraphs.flatMap((p) => splitLongParagraph(p, Math.floor(ownedChars * 1.5)));
  const windows: TextWindow[] = [];
  let cursor = 0;
  while (cursor < blocks.length) {
    let ownedLength = 0;
    const owned: string[] = [];
    while (cursor < blocks.length && (owned.length === 0 || ownedLength < ownedChars)) {
      owned.push(blocks[cursor]);
      ownedLength += blocks[cursor].length + 1;
      cursor += 1;
    }
    let contextLength = 0;
    const context: string[] = [];
    for (let i = cursor; i < blocks.length && contextLength < contextChars; i += 1) {
      context.push(blocks[i]);
      contextLength += blocks[i].length + 1;
    }
    windows.push({
      index: windows.length,
      owned: owned.join("\n"),
      context: context.join("\n"),
    });
  }
  return windows;
}

/** Le texte d'une fenêtre, prêt à être envoyé : la partie propre, la ligne, le contexte. */
export function textWindowContent(window: TextWindow): string {
  if (window.context.length === 0) return window.owned;
  return `${window.owned}\n\n${BOOK_WINDOW_CONTEXT_MARKER}\n\n${window.context}`;
}

// ── HTML → texte ────────────────────────────────────────────────────────────

const NAMED_ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
  laquo: "«",
  raquo: "»",
  hellip: "…",
  mdash: "—",
  ndash: "–",
  rsquo: "’",
  lsquo: "‘",
  ldquo: "“",
  rdquo: "”",
  oelig: "œ",
  OElig: "Œ",
  deg: "°",
  frac12: "½",
  frac14: "¼",
  frac34: "¾",
  times: "×",
  eacute: "é",
  egrave: "è",
  ecirc: "ê",
  euml: "ë",
  agrave: "à",
  acirc: "â",
  ccedil: "ç",
  icirc: "î",
  iuml: "ï",
  ocirc: "ô",
  ugrave: "ù",
  ucirc: "û",
};

function decodeEntities(value: string): string {
  return value.replace(/&(#x[0-9a-fA-F]+|#\d+|[A-Za-z][A-Za-z0-9]*);/g, (whole, body: string) => {
    if (body.startsWith("#x") || body.startsWith("#X")) {
      const code = parseInt(body.slice(2), 16);
      return Number.isFinite(code) && code > 0 && code <= 0x10ffff
        ? String.fromCodePoint(code)
        : whole;
    }
    if (body.startsWith("#")) {
      const code = parseInt(body.slice(1), 10);
      return Number.isFinite(code) && code > 0 && code <= 0x10ffff
        ? String.fromCodePoint(code)
        : whole;
    }
    return NAMED_ENTITIES[body] ?? whole;
  });
}

/**
 * Les lignes de texte d'une page XHTML.
 *
 * Un bloc — paragraphe, titre, élément de liste — vaut une ligne : c'est ce qui
 * garde une liste d'ingrédients lisible ligne à ligne. Tout ramasser à l'aveugle
 * la collerait en un seul paragraphe.
 */
export function htmlToParagraphs(html: string): string[] {
  const BLOCKS =
    "p|div|li|h[1-6]|tr|section|article|blockquote|ul|ol|table|figure|figcaption|dd|dt|header|footer|aside|pre";
  const text = html
    .replace(/<head\b[\s\S]*?<\/head>/gi, "")
    .replace(/<(script|style)\b[\s\S]*?<\/\1\s*>/gi, "")
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(new RegExp(`</(${BLOCKS})\\s*>`, "gi"), "\n")
    .replace(new RegExp(`<(${BLOCKS})\\b[^>]*>`, "gi"), "\n")
    .replace(/<\/(td|th)\s*>/gi, " ")
    .replace(/<[^>]+>/g, "");
  return decodeEntities(text)
    .split("\n")
    .map((line) => line.replace(/[ \t\u00a0]+/g, " ").trim())
    .filter((line) => line.length > 0);
}

// ── EPUB ────────────────────────────────────────────────────────────────────

function attribute(tag: string, name: string): string | null {
  const match = tag.match(new RegExp(`\\b${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)')`, "i"));
  return match ? (match[1] ?? match[2] ?? null) : null;
}

/**
 * Le texte d'un élément de l'OPF.
 *
 * Une description est souvent du HTML **échappé** : `&lt;p&gt;Des recettes&lt;/p&gt;`.
 * Les balises se retirent donc avant le décodage des entités, puis une seconde
 * fois après — sinon le titre du livre porterait des `<p>`.
 */
function elementText(raw: string): string {
  const decoded = decodeEntities(raw.replace(/<[^>]+>/g, ""));
  const text = /<[a-z][^>]*>/i.test(decoded) ? decoded.replace(/<[^>]+>/g, "") : decoded;
  return text.replace(/\s+/g, " ").trim();
}

function firstElementText(xml: string, name: string): string | null {
  const match = xml.match(new RegExp(`<${name}\\b[^>]*>([\\s\\S]*?)</${name}\\s*>`, "i"));
  if (!match) return null;
  const text = elementText(match[1]);
  return text.length > 0 ? text : null;
}

function allElementTexts(xml: string, name: string): string[] {
  const out: string[] = [];
  for (const match of xml.matchAll(
    new RegExp(`<${name}\\b[^>]*>([\\s\\S]*?)</${name}\\s*>`, "gi"),
  )) {
    const text = elementText(match[1]);
    if (text.length > 0) out.push(text);
  }
  return out;
}

/** Un ISBN à dix ou treize chiffres, ou `null`. */
function isbnFrom(identifier: string): string | null {
  const bare = identifier
    .replace(/^urn:isbn:/i, "")
    .replace(/^isbn:?/i, "")
    .replace(/[-\s]/g, "");
  return /^(\d{13}|\d{9}[\dXx])$/.test(bare) ? bare : null;
}

interface ManifestItem {
  href: string;
  mediaType: string;
  properties: string;
}

export interface EpubContent {
  metadata: Partial<BookMetadata>;
  /** Chemin, dans l'archive, de l'image de couverture. */
  coverPath: string | null;
  paragraphs: string[];
  /** Archive ouverte en lecture bornée : chaque entrée lue compte contre les bornes. */
  archive: BoundedZip;
}

/** Résout un lien de l'OPF relativement à son dossier, comme le fait un lecteur. */
function resolveInArchive(opfPath: string, href: string): string {
  const clean = decodeURIComponent(href.split("#")[0]);
  const dir = posix.dirname(opfPath);
  return posix.normalize(dir === "." ? clean : posix.join(dir, clean));
}

/**
 * Ouvre un EPUB : métadonnées, couverture, texte dans l'ordre de lecture.
 *
 * Un EPUB est une archive ZIP. `META-INF/container.xml` désigne le fichier OPF ;
 * l'OPF liste les fichiers (manifeste) et leur ordre de lecture (spine). Le texte
 * de chaque page XHTML est déplié par du code, pas par un modèle.
 */
export async function readEpub(bytes: Buffer): Promise<EpubContent> {
  // Lecture bornée (nombre d'entrées, taille dépliée) : un EPUB est une
  // archive envoyée par l'utilisateur. Une borne franchie, à l'ouverture comme
  // à la lecture d'une page, devient une `BookFileError` : jamais réessayée.
  let archive: BoundedZip;
  try {
    archive = await BoundedZip.open(bytes);
  } catch (err) {
    throw new BookFileError(EPUB_UNREADABLE_MESSAGE, err);
  }
  const read = async (path: string): Promise<string | null> => {
    try {
      return await archive.text(path);
    } catch (err) {
      throw new BookFileError(EPUB_UNREADABLE_MESSAGE, err);
    }
  };

  const containerXml = await read("META-INF/container.xml");
  if (containerXml == null) {
    throw new BookFileError(EPUB_INVALID_MESSAGE, "META-INF/container.xml manquant");
  }
  const rootfile = containerXml.match(/<rootfile\b[^>]*>/i)?.[0] ?? "";
  const opfPath = attribute(rootfile, "full-path");
  const opf = opfPath ? await read(opfPath) : null;
  if (!opfPath || opf == null) {
    throw new BookFileError(
      EPUB_INVALID_MESSAGE,
      opfPath
        ? `fichier OPF introuvable : ${opfPath}`
        : "fichier OPF introuvable : full-path absent de META-INF/container.xml",
    );
  }

  const manifest = new Map<string, ManifestItem>();
  for (const match of opf.matchAll(/<item\b[^>]*>/gi)) {
    const id = attribute(match[0], "id");
    const href = attribute(match[0], "href");
    if (!id || !href) continue;
    manifest.set(id, {
      href,
      mediaType: (attribute(match[0], "media-type") ?? "").toLowerCase(),
      properties: attribute(match[0], "properties") ?? "",
    });
  }

  const spine: string[] = [];
  for (const match of opf.matchAll(/<itemref\b[^>]*>/gi)) {
    const idref = attribute(match[0], "idref");
    if (!idref) continue;
    if ((attribute(match[0], "linear") ?? "yes").toLowerCase() === "no") continue;
    spine.push(idref);
  }

  // Couverture : EPUB 3 la marque d'une propriété, EPUB 2 la désigne par une balise <meta>.
  let coverItem: ManifestItem | undefined;
  for (const item of manifest.values()) {
    if (item.properties.split(/\s+/).includes("cover-image")) {
      coverItem = item;
      break;
    }
  }
  if (!coverItem) {
    for (const match of opf.matchAll(/<meta\b[^>]*>/gi)) {
      if ((attribute(match[0], "name") ?? "").toLowerCase() !== "cover") continue;
      const target = manifest.get(attribute(match[0], "content") ?? "");
      if (target) coverItem = target;
    }
  }

  const paragraphs: string[] = [];
  for (const idref of spine) {
    const item = manifest.get(idref);
    if (!item || !/x?html/.test(item.mediaType)) continue;
    const html = await read(resolveInArchive(opfPath, item.href));
    if (html == null) continue;
    paragraphs.push(...htmlToParagraphs(html));
  }

  const creators = allElementTexts(opf, "dc:creator");
  let isbn: string | null = null;
  for (const identifier of allElementTexts(opf, "dc:identifier")) {
    isbn = isbnFrom(identifier);
    if (isbn) break;
  }
  const date = firstElementText(opf, "dc:date");
  const year = date?.match(/\b(1[5-9]\d\d|20\d\d)\b/)?.[1];
  const description = firstElementText(opf, "dc:description");
  const language = firstElementText(opf, "dc:language");

  return {
    metadata: {
      titre: firstElementText(opf, "dc:title") ?? undefined,
      auteur: creators.length > 0 ? creators.join(", ") : undefined,
      editeur: firstElementText(opf, "dc:publisher"),
      annee: year ? Number(year) : null,
      langue: language ? language.slice(0, 2).toLowerCase() : undefined,
      isbn,
      description: description ? description.slice(0, 1000) : null,
    },
    coverPath: coverItem ? resolveInArchive(opfPath, coverItem.href) : null,
    paragraphs,
    archive,
  };
}

// ── PDF ─────────────────────────────────────────────────────────────────────

export interface PdfSource {
  doc: PDFDocument;
  lib: typeof import("pdf-lib");
  pageCount: number;
  title: string | null;
  author: string | null;
}

/**
 * Ouvre un PDF.
 *
 * `pdf-lib` se charge ici, à la demande : la bibliothèque n'a rien à faire au
 * démarrage des cinquante fonctions du bundle, dont aucune ne lit de PDF.
 */
export async function openPdf(bytes: Buffer): Promise<PdfSource> {
  const lib = await import("pdf-lib");
  let doc: PDFDocument;
  let pageCount: number;
  try {
    doc = await lib.PDFDocument.load(bytes, { updateMetadata: false });
    // `load` accepte un fichier sans arbre de pages ; c'est le décompte qui échoue.
    pageCount = doc.getPageCount();
  } catch (err) {
    if (err instanceof lib.EncryptedPDFError) {
      throw new BookFileError(
        "Ce PDF est protégé par un mot de passe ou un chiffrement : il ne peut pas être découpé. " +
          "Exportez-le sans protection, puis recommencez.",
      );
    }
    throw new BookFileError(
      "Ce PDF n'a pas pu être lu : le fichier est abîmé ou n'est pas un PDF. " +
        "Exportez-le de nouveau, puis recommencez.",
      err,
    );
  }
  const title = doc.getTitle()?.trim() ?? "";
  const author = doc.getAuthor()?.trim() ?? "";
  return {
    doc,
    lib,
    pageCount,
    title: title.length > 0 ? title : null,
    author: author.length > 0 ? author : null,
  };
}

/** Un PDF de `count` pages, à partir de la page `first` (rang à partir de 0). */
export async function extractPdfPages(
  source: PdfSource,
  first: number,
  count: number,
): Promise<Buffer> {
  const out = await source.lib.PDFDocument.create();
  const indices = Array.from({ length: count }, (_, i) => first + i);
  const pages = await out.copyPages(source.doc, indices);
  for (const page of pages) out.addPage(page);
  return Buffer.from(await out.save());
}

/**
 * Le PDF d'une fenêtre, ou plusieurs si elle est trop lourde.
 *
 * Une fenêtre qui dépasse [MAX_CHUNK_BYTES] est coupée en deux moitiés, chacune
 * gardant sa page de contexte : ce sont les pages qui la suivent, celles de
 * l'autre moitié comprises. Une page seule qui dépasse la limite ne se coupe
 * plus : le fichier est trop lourd, et le dire vaut mieux qu'un appel refusé.
 */
export async function buildPdfChunks(
  source: PdfSource,
  window: Pick<Window, "firstUnit" | "ownedUnits" | "contextUnits">,
  maxBytes: number = MAX_CHUNK_BYTES,
): Promise<Array<{ first: number; owned: number; context: number; bytes: Buffer }>> {
  const bytes = await extractPdfPages(
    source,
    window.firstUnit,
    window.ownedUnits + window.contextUnits,
  );
  if (bytes.length <= maxBytes) {
    return [
      {
        first: window.firstUnit,
        owned: window.ownedUnits,
        context: window.contextUnits,
        bytes,
      },
    ];
  }
  if (window.ownedUnits <= 1) {
    const mb = Math.round(bytes.length / (1024 * 1024));
    throw new BookFileError(
      `La page ${window.firstUnit + 1} du PDF pèse ${mb} Mo avec la suivante : trop lourde pour ` +
        "être lue par l'IA. Réduisez la résolution du PDF, puis recommencez.",
    );
  }
  const left = Math.ceil(window.ownedUnits / 2);
  const right = window.ownedUnits - left;
  const contextWanted = window.contextUnits;
  const total = source.pageCount;
  return [
    ...(await buildPdfChunks(
      source,
      {
        firstUnit: window.firstUnit,
        ownedUnits: left,
        contextUnits: Math.min(contextWanted, total - window.firstUnit - left),
      },
      maxBytes,
    )),
    ...(await buildPdfChunks(
      source,
      {
        firstUnit: window.firstUnit + left,
        ownedUnits: right,
        contextUnits: Math.min(contextWanted, total - window.firstUnit - left - right),
      },
      maxBytes,
    )),
  ];
}

// ── Couverture ──────────────────────────────────────────────────────────────

/** Côté minimal d'une image pour qu'on la prenne pour une couverture. */
const MIN_COVER_SIDE = 300;

/** Largeur maximale de la couverture enregistrée. */
const COVER_MAX_WIDTH = 1200;

/**
 * Ramène une image de couverture à un JPEG de taille raisonnable.
 *
 * Rend `null` pour une image trop petite — un logo, une puce — ou illisible.
 * `sharp` se charge ici, à la demande.
 */
export async function toCoverJpeg(bytes: Uint8Array, origin: string): Promise<Buffer | null> {
  try {
    const { default: sharp } = await import("sharp");
    const image = sharp(Buffer.from(bytes)).rotate();
    const meta = await image.metadata();
    if ((meta.width ?? 0) < MIN_COVER_SIDE || (meta.height ?? 0) < MIN_COVER_SIDE) return null;
    return await image
      .resize({ width: COVER_MAX_WIDTH, withoutEnlargement: true })
      .jpeg({ quality: 85 })
      .toBuffer();
  } catch (err) {
    await logError({
      message: `Couverture du livre illisible (${origin}) — le livre sera créé sans couverture`,
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "IMPORT",
    });
    return null;
  }
}

/**
 * La plus grande image JPEG de la première page d'un PDF, ou `null`.
 *
 * Un PDF ne se rend pas en image sans moteur de rendu, et aucun n'est installé.
 * Mais une couverture est presque toujours une image plein cadre, et un PDF qui
 * embarque du JPEG le garde tel quel : on le sort du fichier sans le décoder.
 * Un PDF dont la première page n'est que du vectoriel n'a pas de couverture
 * ainsi extraite, et le livre se crée sans.
 */
export async function pdfFirstPageImage(source: PdfSource): Promise<Buffer | null> {
  const { PDFName, PDFDict, PDFRawStream, PDFArray } = source.lib;
  const resources = source.doc.getPage(0).node.Resources();
  const xobjects = resources?.lookupMaybe(PDFName.of("XObject"), PDFDict);
  if (!xobjects) return null;

  const dct = PDFName.of("DCTDecode");
  let best: Uint8Array | null = null;
  for (const [, ref] of xobjects.entries()) {
    const object = source.doc.context.lookup(ref);
    if (!(object instanceof PDFRawStream)) continue;
    if (object.dict.lookup(PDFName.of("Subtype")) !== PDFName.of("Image")) continue;
    const filter = object.dict.lookup(PDFName.of("Filter"));
    const isJpeg =
      filter === dct ||
      (filter instanceof PDFArray && filter.size() === 1 && filter.lookup(0) === dct);
    if (!isJpeg) continue;
    if (!best || object.contents.length > best.length) best = object.contents;
  }
  return best ? toCoverJpeg(best, "première page du PDF") : null;
}

/** L'image de couverture d'un EPUB, ramenée à un JPEG. */
export async function epubCoverImage(epub: EpubContent): Promise<Buffer | null> {
  if (!epub.coverPath) return null;
  let cover: Buffer | null;
  try {
    cover = await epub.archive.bytes(epub.coverPath);
  } catch (err) {
    // Couverture au-delà des bornes de lecture : le livre s'importe sans elle.
    await logError({
      message: "Couverture EPUB écartée : lecture de l'archive refusée",
      moduleType: "IMPORT",
      errorDescription: err instanceof Error ? err.message : String(err),
      extra: { coverPath: epub.coverPath },
    });
    return null;
  }
  if (cover == null) return null;
  return toCoverJpeg(cover, "EPUB");
}

// ── Livre ouvert ────────────────────────────────────────────────────────────

/** Une tranche prête à devenir un job d'import. */
export interface BookChunk {
  /** Rang de la tranche, à partir de 0. */
  index: number;
  /** « pages 4–6 » ou « partie 3 » : ce que la ligne de suivi affiche. */
  label: string;
  mimeType: string;
  extension: "pdf" | "txt";
  bytes: Buffer;
  window: BookWindowInfo;
}

export interface OpenedBook {
  kind: BookFileKind;
  /** Nombre de tranches prévu. Une tranche PDF trop lourde en donnera davantage. */
  windows: number;
  /** Pages d'un PDF ; `null` pour un texte. */
  pages: number | null;
  /** Caractères d'un texte ; `null` pour un PDF. */
  characters: number | null;
  /** Ce que le fichier dit de lui-même. Un PDF n'en dit souvent presque rien. */
  metadata: Partial<BookMetadata>;
  /** Le premier extrait d'un PDF, à faire lire par l'IA pour en tirer les métadonnées. */
  firstPagePdf: () => Promise<Buffer | null>;
  cover: () => Promise<Buffer | null>;
  chunks: () => AsyncGenerator<BookChunk>;
}

function checkWindowCount(windows: number): void {
  if (windows > MAX_WINDOWS) {
    throw new BookFileError(
      `Ce livre demanderait ${windows} traitements : au-delà de ${MAX_WINDOWS}, il faut le ` +
        "découper en plusieurs fichiers.",
    );
  }
}

function textBook(
  kind: "epub" | "docx",
  paragraphs: string[],
  metadata: Partial<BookMetadata>,
  cover: () => Promise<Buffer | null>,
): OpenedBook {
  const characters = paragraphs.reduce((sum, p) => sum + p.length + 1, 0);
  if (characters === 0) {
    throw new BookFileError(kind === "epub" ? EPUB_NO_TEXT_MESSAGE : DOCX_NO_TEXT_MESSAGE);
  }
  const windows = planTextWindows(paragraphs);
  checkWindowCount(windows.length);
  return {
    kind,
    windows: windows.length,
    pages: null,
    characters,
    metadata,
    firstPagePdf: async () => null,
    cover,
    chunks: async function* () {
      for (const window of windows) {
        yield {
          index: window.index,
          label: `partie ${window.index + 1}`,
          mimeType: "text/plain",
          extension: "txt",
          bytes: Buffer.from(textWindowContent(window), "utf8"),
          window: { kind: "text", context: window.context.length > 0 ? 1 : 0 },
        };
      }
    },
  };
}

/** Ouvre un livre, quel que soit son format, ou lève `BookFileError`. */
export async function openBookFile(bytes: Buffer, kind: BookFileKind): Promise<OpenedBook> {
  if (kind === "epub") {
    const epub = await readEpub(bytes);
    return textBook("epub", epub.paragraphs, epub.metadata, () => epubCoverImage(epub));
  }

  if (kind === "docx") {
    let text: string;
    try {
      text = await docxToPlainText(bytes);
    } catch (err) {
      throw new BookFileError(
        "Ce document Word n'a pas pu être lu : le fichier est abîmé ou trop volumineux. " +
          "Enregistrez-le de nouveau au format .docx, ou découpez-le en plusieurs fichiers, puis recommencez.",
        err,
      );
    }
    const paragraphs = text
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line.length > 0);
    return textBook("docx", paragraphs, {}, async () => null);
  }

  const source = await openPdf(bytes);
  if (source.pageCount === 0) throw new BookFileError("Ce PDF ne contient aucune page.");
  const windows = planWindows(source.pageCount);
  checkWindowCount(windows.length);
  return {
    kind: "pdf",
    windows: windows.length,
    pages: source.pageCount,
    characters: null,
    metadata: {
      titre: source.title ?? undefined,
      auteur: source.author ?? undefined,
    },
    firstPagePdf: () => extractPdfPages(source, 0, 1),
    cover: () => pdfFirstPageImage(source),
    chunks: async function* () {
      let index = 0;
      for (const window of windows) {
        for (const chunk of await buildPdfChunks(source, window)) {
          const last = chunk.first + chunk.owned;
          yield {
            index,
            label:
              chunk.owned === 1 ? `page ${chunk.first + 1}` : `pages ${chunk.first + 1}–${last}`,
            mimeType: PDF_MIME_TYPE,
            extension: "pdf",
            bytes: chunk.bytes,
            window: { kind: "pdf", owned: chunk.owned, context: chunk.context },
          };
          index += 1;
        }
      }
    },
  };
}
