/**
 * Lecture du texte d'un document Word.
 *
 * Un `.docx` est une archive ZIP de XML. Le déplier ici plutôt que de confier
 * le binaire au modèle rend le poste routable — l'API d'Anthropic n'accepte en
 * pièce jointe que le PDF et le texte, si bien qu'un import Word partait chez
 * Gemini quelle que soit la politique de routage.
 *
 * Les cas ci-dessous couvrent ce qui peut se tromper en silence : une recette
 * dont les lignes se collent, une esperluette qui redevient une balise, un
 * code de champ qui entre dans la liste des ingrédients.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import JSZip from "jszip";

import { docxXmlToPlainText, docxToPlainText, isDocxMimeType, DOCX_MIME_TYPE } from "../utils/docx";

/** Un paragraphe OOXML, tel que Word l'écrit. */
function paragraph(...runs: string[]): string {
  return `<w:p><w:pPr/>${runs.map((r) => `<w:r><w:t xml:space="preserve">${r}</w:t></w:r>`).join("")}</w:p>`;
}

function document(body: string): string {
  return `<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="x"><w:body>${body}</w:body></w:document>`;
}

describe("isDocxMimeType", () => {
  test("reconnaît le type MIME de Word", () => {
    assert.equal(isDocxMimeType(DOCX_MIME_TYPE), true);
  });

  test("ne confond pas un PDF ni une image avec un document Word", () => {
    assert.equal(isDocxMimeType("application/pdf"), false);
    assert.equal(isDocxMimeType("image/jpeg"), false);
  });
});

describe("docxXmlToPlainText", () => {
  test("un paragraphe par ligne : une recette garde ses étapes séparées", () => {
    // C'est le cas qui compte : tout coller ferait « 200 g de farine3 œufs ».
    const xml = document(paragraph("200 g de farine") + paragraph("3 œufs"));
    assert.equal(docxXmlToPlainText(xml), "200 g de farine\n3 œufs");
  });

  test("les fragments d'un même paragraphe se recollent sans espace parasite", () => {
    // Word découpe un paragraphe en « runs » dès qu'un mot change de style.
    const xml = document(paragraph("Préchauffer le four à ", "180", " °C"));
    assert.equal(docxXmlToPlainText(xml), "Préchauffer le four à 180 °C");
  });

  test("tabulations et sauts de ligne explicites sont du contenu", () => {
    const xml = document(
      `<w:p><w:r><w:t>Farine</w:t></w:r><w:r><w:tab/><w:t>200 g</w:t></w:r></w:p>`,
    );
    assert.equal(docxXmlToPlainText(xml), "Farine\t200 g");
  });

  test("les entités XML redeviennent du texte", () => {
    const xml = document(paragraph("Sel &amp; poivre"));
    assert.equal(docxXmlToPlainText(xml), "Sel & poivre");
  });

  test("une entité échappée deux fois ne devient pas une balise", () => {
    // Décoder `&amp;` en premier transformerait `&amp;lt;` en `<`, c'est-à-dire
    // du texte en balise — et le fragment suivant disparaîtrait.
    const xml = document(paragraph("a &amp;lt; b"));
    assert.equal(docxXmlToPlainText(xml), "a &lt; b");
  });

  test("les codes de champ n'entrent pas dans la recette", () => {
    // `instrText` porte des instructions Word (numéros de page, renvois),
    // jamais du texte visible. Tout ramasser à l'aveugle les ferait entrer.
    const xml = document(
      `<w:p><w:r><w:instrText>PAGE \\* MERGEFORMAT</w:instrText></w:r><w:r><w:t>Tarte</w:t></w:r></w:p>`,
    );
    assert.equal(docxXmlToPlainText(xml), "Tarte");
  });

  test("les lignes vides en série sont ramenées à une respiration", () => {
    const xml = document(
      paragraph("Titre") + paragraph("") + paragraph("") + paragraph("") + paragraph("Suite"),
    );
    assert.equal(docxXmlToPlainText(xml), "Titre\n\nSuite");
  });

  test("un document sans texte visible rend une chaîne vide", () => {
    assert.equal(docxXmlToPlainText(document("<w:p><w:pPr/></w:p>")), "");
  });
});

describe("docxToPlainText — sur une vraie archive", () => {
  async function buildDocx(body: string): Promise<Buffer> {
    const zip = new JSZip();
    zip.file("word/document.xml", document(body));
    return zip.generateAsync({ type: "nodebuffer" });
  }

  test("le texte traverse le ZIP intact", async () => {
    const bytes = await buildDocx(paragraph("Tarte aux pommes") + paragraph("4 pommes"));
    assert.equal(await docxToPlainText(bytes), "Tarte aux pommes\n4 pommes");
  });

  test("une archive sans corps de document est signalée, pas rendue vide", async () => {
    // Rendre une chaîne vide enverrait un document sans contenu au modèle, qui
    // répondrait « aucune recette » : un échec qui ressemble à un succès.
    const zip = new JSZip();
    zip.file("word/styles.xml", "<x/>");
    const bytes = await zip.generateAsync({ type: "nodebuffer" });
    await assert.rejects(() => docxToPlainText(bytes), /word\/document\.xml/);
  });

  test("un document sans texte lisible est signalé", async () => {
    const bytes = await buildDocx("<w:p><w:pPr/></w:p>");
    await assert.rejects(() => docxToPlainText(bytes), /sans texte lisible/);
  });

  test("un fichier qui n'est pas une archive est signalé", async () => {
    await assert.rejects(() => docxToPlainText(Buffer.from("ceci n'est pas un zip")));
  });
});
