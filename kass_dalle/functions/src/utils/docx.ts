/**
 * Lecture du texte d'un document Word.
 *
 * Un `.docx` est une archive ZIP contenant du XML : le texte visible vit dans
 * `word/document.xml`. Le déplier est un problème résolu et déterministe —
 * aucune intelligence artificielle n'est nécessaire pour cette étape, et en
 * confier la charge à un modèle reviendrait à payer un raisonnement pour faire
 * le travail d'une bibliothèque.
 *
 * Trois raisons de le faire ici plutôt que de laisser le binaire partir tel
 * quel :
 *
 *  1. **Le poste redevient routable.** L'API d'Anthropic n'accepte en pièce
 *     jointe que le PDF et le texte brut ; celle de Google déplie le DOCX de
 *     son côté. Un import Word partait donc chez Gemini quelle que soit la
 *     politique de routage — une bascule de moteur silencieusement annulée par
 *     un format de fichier.
 *  2. **C'est moins cher, quel que soit le moteur.** Du texte déjà propre coûte
 *     moins de jetons d'entrée qu'un binaire à déchiffrer.
 *  3. **C'est reproductible.** Un dépliage par du code rend toujours la même
 *     chose ; un dépliage par un modèle, non.
 */

import { BoundedZip } from "./boundedZip";

/** Type MIME d'un document Word moderne. */
export const DOCX_MIME_TYPE =
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document";

export function isDocxMimeType(mimeType: string): boolean {
  return mimeType === DOCX_MIME_TYPE;
}

/** Entrée de l'archive qui porte le corps du document. */
const DOCUMENT_ENTRY = "word/document.xml";

/**
 * Entités XML que Word écrit dans le texte.
 *
 * `&amp;` est traité en dernier : le décoder d'abord transformerait
 * `&amp;lt;` en `<`, c'est-à-dire du texte en balise.
 */
function decodeXmlEntities(value: string): string {
  return value
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, code: string) => String.fromCodePoint(Number(code)))
    .replace(/&amp;/g, "&");
}

/**
 * Texte lisible d'un `word/document.xml`.
 *
 * Exporté pour être testé seul : c'est la seule partie qui demande du
 * jugement, et la seule qui puisse se tromper en silence.
 *
 * Le texte visible d'OOXML vit exclusivement dans les éléments `<w:t>`. On
 * découpe donc d'abord sur les fins de paragraphe — un paragraphe vaut une
 * ligne, ce qui préserve les listes d'ingrédients et les étapes — puis on ne
 * retient, dans chaque paragraphe, que le contenu de ces éléments. Tout
 * ramasser à l'aveugle ferait entrer les codes de champ (`<w:instrText>`) dans
 * la recette.
 */
export function docxXmlToPlainText(xml: string): string {
  // Tabulations et sauts de ligne explicites sont des éléments **frères** des
  // `<w:t>`, pas leur contenu : les remplacer avant d'extraire le texte les
  // perdrait tous. Il faut donc lire les trois dans l'ordre du document —
  // « Farine <tab> 200 g » se lit sinon « Farine200 g ».
  const TOKEN = /<w:t\b[^>]*>([\s\S]*?)<\/w:t>|<w:tab\b[^>]*\/?>|<w:br\b[^>]*\/?>/g;

  const lines: string[] = [];
  for (const paragraph of xml.split(/<\/w:p>/)) {
    let line = "";
    for (const match of paragraph.matchAll(TOKEN)) {
      if (match[1] !== undefined) line += decodeXmlEntities(match[1]);
      else if (match[0].startsWith("<w:tab")) line += "\t";
      else line += "\n";
    }
    // Une ligne vide est une respiration voulue par l'auteur ; plusieurs à la
    // suite ne veulent plus rien dire.
    lines.push(line.trimEnd());
  }

  return lines
    .join("\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/**
 * Texte d'un document Word, ou une erreur.
 *
 * Lève `ZipLimitError` quand l'archive dépasse les bornes de lecture.
 *
 * Ne rend jamais une chaîne vide en silence : un document illisible doit
 * remonter, pour que l'appelant serve le binaire au moteur qui sait le lire
 * plutôt que d'envoyer du vide à celui qui ne le sait pas.
 */
export async function docxToPlainText(bytes: Buffer): Promise<string> {
  // Lecture bornée : un DOCX est une archive envoyée par l'utilisateur, et une
  // bombe zip y tiendrait en quelques mégaoctets (`ZipLimitError`).
  const archive = await BoundedZip.open(bytes);
  const xml = await archive.text(DOCUMENT_ENTRY);
  if (xml == null) {
    throw new Error(`archive Word sans ${DOCUMENT_ENTRY}`);
  }

  const text = docxXmlToPlainText(xml);
  if (text.length === 0) {
    throw new Error("document Word sans texte lisible");
  }
  return text;
}
