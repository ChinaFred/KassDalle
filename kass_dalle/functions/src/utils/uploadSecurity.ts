const MAX_UPLOAD_SIZE_BYTES = 50 * 1024 * 1024;

/**
 * Plafond d'un livre entier : PDF ou EPUB envoyé pour être découpé en recettes.
 *
 * Six fois celui d'une page. Un livre ne se lit pas en mémoire d'un bloc :
 * `scanUploadHead` n'en lit que l'en-tête, et l'analyse de contenu se fait en
 * flux. La règle Storage du dossier `quarantine/{uid}/livres/` porte la même
 * valeur — les deux doivent bouger ensemble.
 */
export const MAX_BOOK_UPLOAD_SIZE_BYTES = 300 * 1024 * 1024;

const ALLOWED_EXTENSIONS = new Set(["pdf", "docx", "epub", "jpg", "jpeg", "png", "txt"]);
const EPUB_MIME = "application/epub+zip";
const DOCX_MIME = "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
const ALLOWED_MIME_TYPES = new Set([
  "application/pdf",
  DOCX_MIME,
  EPUB_MIME,
  "image/jpeg",
  "image/png",
  "text/plain",
  "text/plain; charset=utf-8",
]);

/**
 * Signature d'une archive ZIP.
 *
 * Un DOCX et un EPUB sont tous deux des archives ZIP : la signature ne permet
 * pas de les distinguer, et l'extension déclarée tranche entre les deux.
 */
const ZIP_SIGNATURE = "application/zip";
const ZIP_BASED_MIME_TYPES = new Set([DOCX_MIME, EPUB_MIME]);

const EICAR_SIGNATURE = "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*";
const EICAR_BYTES = Buffer.from(EICAR_SIGNATURE, "utf8");

export interface ScanInput {
  fileName: string;
  mimeType?: string;
  bytes: Buffer;
}

export interface ScanResult {
  clean: boolean;
  reason?: string;
  normalizedMimeType?: string;
}

/** Ce que les contrôles sur le nom, la taille et le type déclarés laissent passer. */
type DeclaredCheck = { blocked: ScanResult } | { ext: string; normalizedMime: string | undefined };

function checkDeclared(
  fileName: string,
  mimeType: string | undefined,
  size: number,
  maxBytes: number,
): DeclaredCheck {
  if (!fileName || size === 0) {
    return { blocked: { clean: false, reason: "Fichier vide ou nom invalide." } };
  }
  if (size > maxBytes) {
    const mb = Math.round(maxBytes / (1024 * 1024));
    return { blocked: { clean: false, reason: `Fichier trop volumineux (max ${mb} Mo).` } };
  }

  const ext = getExtension(fileName);
  if (!ALLOWED_EXTENSIONS.has(ext)) {
    return {
      blocked: { clean: false, reason: `Extension non autorisee: .${ext || "inconnue"}` },
    };
  }

  const normalizedMime = normalizeMimeType(mimeType);
  if (normalizedMime && !ALLOWED_MIME_TYPES.has(normalizedMime)) {
    return {
      blocked: { clean: false, reason: `Type MIME non autorise: ${normalizedMime}` },
    };
  }
  return { ext, normalizedMime };
}

/** Le contenu concorde-t-il avec ce qui est déclaré ? `head` porte au moins l'en-tête. */
function checkSignature(head: Buffer, ext: string, normalizedMime: string | undefined): ScanResult {
  const signatureMime = detectMimeFromSignature(head);
  if (ext !== "txt" && !signatureMime) {
    return { clean: false, reason: "Signature binaire invalide ou format de fichier non reconnu." };
  }

  const expectedFromExt = expectedMimeFromExtension(ext);
  const referenceMime = normalizedMime ?? expectedFromExt;

  if (signatureMime === ZIP_SIGNATURE) {
    // Une archive ZIP n'est admise que sous l'un des deux formats qui en sont.
    if (!referenceMime || !ZIP_BASED_MIME_TYPES.has(referenceMime)) {
      return {
        clean: false,
        reason: `Incoherence entre contenu (archive ZIP) et type declare (${referenceMime ?? "inconnu"}).`,
      };
    }
    return { clean: true, normalizedMimeType: referenceMime };
  }

  if (signatureMime && referenceMime && signatureMime !== referenceMime) {
    return {
      clean: false,
      reason: `Incoherence entre contenu (${signatureMime}) et type declare (${referenceMime}).`,
    };
  }

  return { clean: true, normalizedMimeType: signatureMime ?? referenceMime };
}

export function scanUpload(input: ScanInput, maxBytes: number = MAX_UPLOAD_SIZE_BYTES): ScanResult {
  const { fileName, mimeType, bytes } = input;
  const declared = checkDeclared(fileName, mimeType, bytes.length, maxBytes);
  if ("blocked" in declared) return declared.blocked;

  // Signature antivirus de test standard (EICAR).
  if (bytes.includes(EICAR_BYTES)) {
    return { clean: false, reason: "Fichier detecte comme malveillant (signature EICAR)." };
  }

  return checkSignature(bytes, declared.ext, declared.normalizedMime);
}

/**
 * Contrôle d'un livre entier sans le charger : nom, taille, type et en-tête.
 *
 * Reprend les contrôles de `scanUpload`, à une exception près : la signature
 * EICAR ne se cherche pas ici, puisque le fichier n'est pas en mémoire. Le
 * flux qui la cherche est `streamContainsEicar`, appelé par le même appelant.
 */
export function scanUploadHead(input: {
  fileName: string;
  mimeType?: string;
  size: number;
  head: Buffer;
}): ScanResult {
  const declared = checkDeclared(
    input.fileName,
    input.mimeType,
    input.size,
    MAX_BOOK_UPLOAD_SIZE_BYTES,
  );
  if ("blocked" in declared) return declared.blocked;
  return checkSignature(input.head, declared.ext, declared.normalizedMime);
}

/**
 * Cherche la signature EICAR dans un flux, sans en garder plus d'un morceau.
 *
 * Une signature peut être coupée entre deux morceaux : la fin du morceau
 * précédent, de la longueur de la signature moins un octet, est donc reportée
 * devant le suivant.
 */
export async function streamContainsEicar(chunks: AsyncIterable<Buffer>): Promise<boolean> {
  let tail: Buffer = Buffer.alloc(0);
  for await (const chunk of chunks) {
    const window: Buffer = Buffer.concat([tail, chunk]);
    if (window.includes(EICAR_BYTES)) return true;
    tail = window.subarray(Math.max(0, window.length - (EICAR_BYTES.length - 1)));
  }
  return false;
}

function getExtension(fileName: string): string {
  const dot = fileName.lastIndexOf(".");
  if (dot < 0 || dot === fileName.length - 1) return "";
  return fileName.substring(dot + 1).toLowerCase();
}

function normalizeMimeType(mimeType?: string): string | undefined {
  if (!mimeType) return undefined;
  return mimeType.trim().toLowerCase();
}

function expectedMimeFromExtension(ext: string): string | undefined {
  switch (ext) {
    case "pdf":
      return "application/pdf";
    case "docx":
      return DOCX_MIME;
    case "epub":
      return EPUB_MIME;
    case "jpg":
    case "jpeg":
      return "image/jpeg";
    case "png":
      return "image/png";
    case "txt":
      return "text/plain";
    default:
      return undefined;
  }
}

function detectMimeFromSignature(bytes: Buffer): string | undefined {
  if (
    bytes.length >= 4 &&
    bytes[0] === 0x25 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x44 &&
    bytes[3] === 0x46
  ) {
    return "application/pdf";
  }

  if (
    bytes.length >= 8 &&
    bytes[0] === 0x89 &&
    bytes[1] === 0x50 &&
    bytes[2] === 0x4e &&
    bytes[3] === 0x47 &&
    bytes[4] === 0x0d &&
    bytes[5] === 0x0a &&
    bytes[6] === 0x1a &&
    bytes[7] === 0x0a
  ) {
    return "image/png";
  }

  if (bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) {
    return "image/jpeg";
  }

  // DOCX et EPUB sont des archives ZIP (PK\x03\x04, PK\x05\x06, PK\x07\x08).
  if (bytes.length >= 4 && bytes[0] === 0x50 && bytes[1] === 0x4b) {
    return ZIP_SIGNATURE;
  }

  return undefined;
}
