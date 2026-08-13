const MAX_UPLOAD_SIZE_BYTES = 50 * 1024 * 1024;

const ALLOWED_EXTENSIONS = new Set(["pdf", "docx", "jpg", "jpeg", "png", "txt"]);
const ALLOWED_MIME_TYPES = new Set([
  "application/pdf",
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  "image/jpeg",
  "image/png",
  "text/plain",
  "text/plain; charset=utf-8",
]);

const EICAR_SIGNATURE = "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*";

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

export function scanUpload(input: ScanInput): ScanResult {
  const { fileName, mimeType, bytes } = input;
  if (!fileName || bytes.length === 0) {
    return { clean: false, reason: "Fichier vide ou nom invalide." };
  }
  if (bytes.length > MAX_UPLOAD_SIZE_BYTES) {
    return { clean: false, reason: "Fichier trop volumineux (max 50 Mo)." };
  }

  const ext = getExtension(fileName);
  if (!ALLOWED_EXTENSIONS.has(ext)) {
    return { clean: false, reason: `Extension non autorisee: .${ext || "inconnue"}` };
  }

  const normalizedMime = normalizeMimeType(mimeType);
  if (normalizedMime && !ALLOWED_MIME_TYPES.has(normalizedMime)) {
    return { clean: false, reason: `Type MIME non autorise: ${normalizedMime}` };
  }

  // Signature antivirus de test standard (EICAR).
  const asText = bytes.toString("utf8");
  if (asText.includes(EICAR_SIGNATURE)) {
    return { clean: false, reason: "Fichier detecte comme malveillant (signature EICAR)." };
  }

  const signatureMime = detectMimeFromSignature(bytes);
  if (ext !== "txt" && !signatureMime) {
    return { clean: false, reason: "Signature binaire invalide ou format de fichier non reconnu." };
  }

  const expectedFromExt = expectedMimeFromExtension(ext);
  const referenceMime = normalizedMime ?? expectedFromExt;

  if (signatureMime && referenceMime && signatureMime !== referenceMime) {
    return {
      clean: false,
      reason: `Incoherence entre contenu (${signatureMime}) et type declare (${referenceMime}).`,
    };
  }

  return { clean: true, normalizedMimeType: signatureMime ?? referenceMime };
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
      return "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
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

  // DOCX est un ZIP (PK\x03\x04, PK\x05\x06, PK\x07\x08)
  if (bytes.length >= 4 && bytes[0] === 0x50 && bytes[1] === 0x4b) {
    return "application/vnd.openxmlformats-officedocument.wordprocessingml.document";
  }

  return undefined;
}
