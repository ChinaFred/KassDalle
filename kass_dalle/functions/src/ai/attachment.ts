/**
 * Préparation d'une pièce jointe avant l'appel au modèle.
 *
 * Les deux fournisseurs n'acceptent pas les mêmes formats. Google déplie un
 * document Word de son côté ; Anthropic n'accepte en pièce jointe que le PDF
 * et le texte. Un import Word partait donc chez Gemini **quelle que soit la
 * politique de routage** — une bascule de moteur silencieusement annulée par
 * un format de fichier, et invisible autrement qu'en lisant le code.
 *
 * Plutôt que d'accepter cette exception, on la supprime : le document est
 * converti en texte ici, avant que le routeur ne choisisse. Le poste redevient
 * routable, coûte moins cher chez les deux moteurs, et le résultat cesse de
 * dépendre de qui a lu le fichier.
 */

import { logError, logInfo } from "../logging";
import { ZipLimitError } from "../utils/boundedZip";
import { docxToPlainText, isDocxMimeType } from "../utils/docx";
import { filePart, textPart, type ModelCallContext, type ModelPart } from "./types";

/**
 * En-tête posé devant le texte extrait.
 *
 * Sans lui, le modèle reçoit un mur de texte sans savoir d'où il vient, et
 * confond volontiers le contenu du document avec la consigne qui le suit.
 */
const DOCX_TEXT_HEADER = "--- Texte extrait d'un document Word ---";

/**
 * Pièce jointe prête pour le modèle.
 *
 * Un document Word devient du texte ; tout le reste part inchangé. Si la
 * conversion échoue, le binaire est servi tel quel — Gemini sait le lire, et
 * un import qui aboutit vaut mieux qu'un import qui échoue pour cause de
 * routage. L'incident est journalisé : c'est la seule façon de savoir qu'un
 * poste est retombé sur l'autre moteur sans l'avoir demandé.
 */
export async function attachmentPart(
  mimeType: string,
  bytes: Buffer,
  ctx: ModelCallContext,
): Promise<ModelPart> {
  // Un texte brut est du texte : le passer en pièce jointe le rangeait parmi les
  // documents, que Claude refuse, et le routage retombait sur Gemini. C'est le
  // cas d'un livre numérique découpé en tranches — voir `books/bookFile.ts`.
  if (mimeType.split(";")[0].trim().toLowerCase() === "text/plain") {
    return textPart(bytes.toString("utf8"));
  }

  if (!isDocxMimeType(mimeType)) {
    return filePart(mimeType, bytes);
  }

  try {
    const text = await docxToPlainText(bytes);
    await logInfo({
      message: "Document Word converti en texte avant l'appel au modèle",
      correlationId: ctx.correlationId,
      moduleType: ctx.moduleType,
      userId: ctx.userId,
      feature: ctx.feature,
      extra: { bytes: bytes.length, characters: text.length },
    });
    return textPart(`${DOCX_TEXT_HEADER}\n${text}`);
  } catch (err) {
    await logError({
      message: "Document Word illisible — le binaire part tel quel, donc chez Gemini",
      correlationId: ctx.correlationId,
      moduleType: ctx.moduleType,
      userId: ctx.userId,
      feature: ctx.feature,
      errorDescription: err instanceof Error ? err.message : String(err),
      extra: { bytes: bytes.length, zipLimit: err instanceof ZipLimitError },
    });
    // Une archive qui dépasse les bornes de lecture ne part pas chez un modèle :
    // elle n'est pas un document à lire, et le traitement s'arrête en erreur.
    if (err instanceof ZipLimitError) throw err;
    return filePart(mimeType, bytes);
  }
}
