/**
 * Lecture et découpage d'un livre entier.
 *
 * Ce qui peut se tromper sans lever d'erreur : une page transcrite deux fois
 * (deux brouillons de la même recette), une page transcrite par personne (une
 * recette absente du livre), une liste d'ingrédients collée en un seul
 * paragraphe. Les cas ci-dessous vérifient d'abord que chaque page appartient à
 * exactement une tranche.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import JSZip from "jszip";
import { PDFDocument } from "pdf-lib";
import sharp from "sharp";

import {
  BookFileError,
  EPUB_INVALID_MESSAGE,
  EPUB_NO_TEXT_MESSAGE,
  DOCX_NO_TEXT_MESSAGE,
  buildPdfChunks,
  detectBookFileKind,
  htmlToParagraphs,
  openBookFile,
  openPdf,
  pdfFirstPageImage,
  planTextWindows,
  planWindows,
  readEpub,
  technicalErrorText,
  textWindowContent,
} from "../books/bookFile";
import { BOOK_WINDOW_CONTEXT_MARKER } from "../gemini/promptsExtraction";

describe("planWindows", () => {
  test("chaque page est transcrite par exactement une fenêtre", () => {
    for (const total of [1, 2, 3, 4, 7, 10, 100]) {
      const seen = new Array<number>(total).fill(0);
      for (const w of planWindows(total)) {
        for (let i = 0; i < w.ownedUnits; i++) seen[w.firstUnit + i] += 1;
      }
      assert.deepEqual(seen, new Array(total).fill(1), `${total} pages`);
    }
  });

  test("le contexte prolonge la fenêtre sans dépasser la fin du livre", () => {
    const windows = planWindows(10);
    assert.deepEqual(
      windows.map((w) => [w.firstUnit, w.ownedUnits, w.contextUnits]),
      [
        [0, 3, 1],
        [3, 3, 1],
        [6, 3, 1],
        [9, 1, 0],
      ],
    );
  });

  test("un livre vide ou une valeur absurde ne donne aucune fenêtre", () => {
    assert.deepEqual(planWindows(0), []);
    assert.deepEqual(planWindows(-3), []);
    assert.deepEqual(planWindows(2.5), []);
  });
});

describe("planTextWindows", () => {
  const paragraph = (n: number) => `Paragraphe ${n} ${"x".repeat(200)}`;

  test("chaque paragraphe est transcrit par une seule fenêtre", () => {
    const paragraphs = Array.from({ length: 60 }, (_, i) => paragraph(i));
    const windows = planTextWindows(paragraphs, 1000, 300);
    const owned = windows.flatMap((w) => w.owned.split("\n"));
    assert.deepEqual(owned, paragraphs);
  });

  test("le contexte est le début de la fenêtre suivante, et la dernière n'en a pas", () => {
    const paragraphs = Array.from({ length: 12 }, (_, i) => paragraph(i));
    const windows = planTextWindows(paragraphs, 500, 300);
    assert.ok(windows.length > 1);
    for (let i = 0; i < windows.length - 1; i++) {
      const next = windows[i + 1].owned.split("\n")[0];
      assert.equal(windows[i].context.split("\n")[0], next);
    }
    assert.equal(windows[windows.length - 1].context, "");
  });

  test("un paragraphe plus long que la fenêtre est coupé, sans perdre de texte", () => {
    const sentence = "Mélangez la farine avec le sel. ";
    const long = sentence.repeat(400).trim();
    const windows = planTextWindows([long], 1000, 200);
    assert.ok(windows.length > 1);
    const rebuilt = windows
      .map((w) => w.owned)
      .join(" ")
      .replace(/\s+/g, " ");
    assert.equal(rebuilt, long.replace(/\s+/g, " "));
  });

  test("la ligne de séparation n'apparaît que s'il y a du contexte", () => {
    const [first, last] = [
      { index: 0, owned: "A", context: "B" },
      { index: 1, owned: "B", context: "" },
    ];
    assert.ok(textWindowContent(first).includes(BOOK_WINDOW_CONTEXT_MARKER));
    assert.equal(textWindowContent(last), "B");
  });
});

describe("htmlToParagraphs", () => {
  test("une liste d'ingrédients reste une ligne par ingrédient", () => {
    const html = "<html><body><ul><li>200 g de farine</li><li>3 &oelig;ufs</li></ul></body></html>";
    assert.deepEqual(htmlToParagraphs(html), ["200 g de farine", "3 œufs"]);
  });

  test("ignore l'en-tête, les scripts, les styles et les commentaires", () => {
    const html =
      "<head><title>Livre</title></head><style>p{}</style><!-- note --><p>Texte</p><script>x()</script>";
    assert.deepEqual(htmlToParagraphs(html), ["Texte"]);
  });

  test("décode les entités numériques et l'espace insécable", () => {
    assert.deepEqual(htmlToParagraphs("<p>Sel&#160;&amp;&#x20;poivre</p>"), ["Sel & poivre"]);
  });

  test("un saut de ligne <br> sépare deux lignes", () => {
    assert.deepEqual(htmlToParagraphs("<p>Étape 1<br/>Étape 2</p>"), ["Étape 1", "Étape 2"]);
  });

  test("une entité inconnue reste telle quelle plutôt que de disparaître", () => {
    assert.deepEqual(htmlToParagraphs("<p>a &inconnue; b</p>"), ["a &inconnue; b"]);
  });
});

describe("detectBookFileKind", () => {
  test("lit le type MIME d'abord, l'extension ensuite", () => {
    assert.equal(detectBookFileKind("application/pdf", "x.bin"), "pdf");
    assert.equal(detectBookFileKind("application/epub+zip", undefined), "epub");
    assert.equal(detectBookFileKind(undefined, "livre.EPUB"), "epub");
    assert.equal(detectBookFileKind("application/octet-stream", "livre.docx"), "docx");
    assert.equal(detectBookFileKind("image/png", "page.png"), null);
  });
});

// ── EPUB ─────────────────────────────────────────────────────────────────────

const CONTAINER = `<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>`;

const OPF = `<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Le Riz Jaune</dc:title>
    <dc:creator>Thaï Liou</dc:creator>
    <dc:creator>Une Autre</dc:creator>
    <dc:publisher>Larousse</dc:publisher>
    <dc:date>2023-05-10</dc:date>
    <dc:language>fr-FR</dc:language>
    <dc:identifier>urn:isbn:978-2-03-599999-1</dc:identifier>
    <dc:description>&lt;p&gt;Des recettes asiatiques.&lt;/p&gt;</dc:description>
  </metadata>
  <manifest>
    <item id="cover" href="images/couv.jpg" media-type="image/jpeg" properties="cover-image"/>
    <item id="c1" href="text/chap%201.xhtml" media-type="application/xhtml+xml"/>
    <item id="c2" href="text/chap2.xhtml" media-type="application/xhtml+xml"/>
    <item id="notes" href="text/notes.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
    <itemref idref="c2"/>
    <itemref idref="notes" linear="no"/>
  </spine>
</package>`;

async function buildEpub(): Promise<Buffer> {
  const zip = new JSZip();
  zip.file("mimetype", "application/epub+zip");
  zip.file("META-INF/container.xml", CONTAINER);
  zip.file("OEBPS/content.opf", OPF);
  zip.file(
    "OEBPS/text/chap 1.xhtml",
    "<html><body><h1>Riz cantonais</h1><p>Pour 4 personnes</p><ul><li>300 g de riz</li><li>2 œufs</li></ul></body></html>",
  );
  zip.file(
    "OEBPS/text/chap2.xhtml",
    "<html><body><h1>Bao</h1><p>Pétrissez la pâte.</p></body></html>",
  );
  zip.file("OEBPS/text/notes.xhtml", "<html><body><p>Notes de fin à ignorer</p></body></html>");
  const cover = await sharp({
    create: { width: 600, height: 900, channels: 3, background: { r: 200, g: 160, b: 20 } },
  })
    .jpeg()
    .toBuffer();
  zip.file("OEBPS/images/couv.jpg", cover);
  return zip.generateAsync({ type: "nodebuffer" });
}

describe("readEpub", () => {
  test("lit les métadonnées de l'OPF", async () => {
    const epub = await readEpub(await buildEpub());
    assert.equal(epub.metadata.titre, "Le Riz Jaune");
    assert.equal(epub.metadata.auteur, "Thaï Liou, Une Autre");
    assert.equal(epub.metadata.editeur, "Larousse");
    assert.equal(epub.metadata.annee, 2023);
    assert.equal(epub.metadata.langue, "fr");
    assert.equal(epub.metadata.isbn, "9782035999991");
    assert.equal(epub.metadata.description, "Des recettes asiatiques.");
  });

  test("rend le texte dans l'ordre de lecture, sans les pages hors lecture linéaire", async () => {
    const epub = await readEpub(await buildEpub());
    assert.deepEqual(epub.paragraphs, [
      "Riz cantonais",
      "Pour 4 personnes",
      "300 g de riz",
      "2 œufs",
      "Bao",
      "Pétrissez la pâte.",
    ]);
  });

  test("retrouve la couverture désignée par le manifeste, lien encodé compris", async () => {
    const epub = await readEpub(await buildEpub());
    assert.equal(epub.coverPath, "OEBPS/images/couv.jpg");
  });

  test("une archive qui n'est pas un EPUB lève une erreur lisible", async () => {
    const zip = new JSZip();
    zip.file("autre.txt", "rien");
    // Le membre lit un texte simple ; le nom du fichier manquant reste dans
    // `detail`, pour les journaux.
    await assert.rejects(
      async () => readEpub(await zip.generateAsync({ type: "nodebuffer" })),
      (err: unknown) =>
        err instanceof BookFileError &&
        err.message === EPUB_INVALID_MESSAGE &&
        err.detail === "META-INF/container.xml manquant" &&
        technicalErrorText(err).includes("container.xml"),
    );
    await assert.rejects(
      () => readEpub(Buffer.from("ceci n'est pas une archive")),
      (err: unknown) => err instanceof BookFileError,
    );
  });
});

test("un EPUB sans fichier OPF lève le même message, détail à part", async () => {
  const zip = new JSZip();
  zip.file(
    "META-INF/container.xml",
    '<container><rootfiles><rootfile full-path="OEBPS/absent.opf"/></rootfiles></container>',
  );
  await assert.rejects(
    async () => readEpub(await zip.generateAsync({ type: "nodebuffer" })),
    (err: unknown) =>
      err instanceof BookFileError &&
      err.message === EPUB_INVALID_MESSAGE &&
      err.detail === "fichier OPF introuvable : OEBPS/absent.opf" &&
      !/OPF|container|xml/i.test(err.message),
  );
});

describe("openBookFile — EPUB", () => {
  test("découpe le texte en tranches et rend une couverture JPEG", async () => {
    const book = await openBookFile(await buildEpub(), "epub");
    assert.equal(book.kind, "epub");
    assert.equal(book.windows, 1);
    assert.equal(book.pages, null);
    const chunks: string[] = [];
    for await (const chunk of book.chunks()) {
      assert.equal(chunk.mimeType, "text/plain");
      assert.equal(chunk.extension, "txt");
      assert.equal(chunk.label, "partie 1");
      chunks.push(chunk.bytes.toString("utf8"));
    }
    assert.equal(chunks.length, 1);
    assert.ok(chunks[0].includes("300 g de riz"));
    assert.ok(!chunks[0].includes("Notes de fin"));

    const cover = await book.cover();
    assert.ok(cover);
    const meta = await sharp(cover).metadata();
    assert.equal(meta.format, "jpeg");
  });

  test("un EPUB sans texte lisible est refusé, pas importé vide", async () => {
    const zip = new JSZip();
    zip.file("META-INF/container.xml", CONTAINER);
    zip.file(
      "OEBPS/content.opf",
      `<package><metadata xmlns:dc="x"><dc:title>Images</dc:title></metadata>
       <manifest><item id="p1" href="p1.xhtml" media-type="application/xhtml+xml"/></manifest>
       <spine><itemref idref="p1"/></spine></package>`,
    );
    zip.file("OEBPS/p1.xhtml", "<html><body><img src='a.jpg'/></body></html>");
    await assert.rejects(
      async () => openBookFile(await zip.generateAsync({ type: "nodebuffer" }), "epub"),
      (err: unknown) => err instanceof BookFileError && err.message === EPUB_NO_TEXT_MESSAGE,
    );
  });
});

// ── PDF ──────────────────────────────────────────────────────────────────────

async function buildPdf(pages: number, withCover = false): Promise<Buffer> {
  const doc = await PDFDocument.create();
  doc.setTitle("Cuisine du monde");
  doc.setAuthor("Un Auteur");
  for (let i = 0; i < pages; i++) {
    const page = doc.addPage([400, 600]);
    page.drawText(`Page ${i + 1}`, { x: 50, y: 500 });
    if (i === 0 && withCover) {
      const jpeg = await sharp({
        create: { width: 800, height: 1200, channels: 3, background: { r: 30, g: 90, b: 160 } },
      })
        .jpeg()
        .toBuffer();
      const image = await doc.embedJpg(jpeg);
      page.drawImage(image, { x: 0, y: 0, width: 400, height: 600 });
    }
  }
  return Buffer.from(await doc.save());
}

async function pagesOf(bytes: Buffer): Promise<number> {
  return (await PDFDocument.load(bytes)).getPageCount();
}

describe("openBookFile — PDF", () => {
  test("annonce le nombre de pages, les tranches et les métadonnées du fichier", async () => {
    const book = await openBookFile(await buildPdf(10), "pdf");
    assert.equal(book.kind, "pdf");
    assert.equal(book.pages, 10);
    assert.equal(book.windows, 4);
    assert.equal(book.metadata.titre, "Cuisine du monde");
    assert.equal(book.metadata.auteur, "Un Auteur");
  });

  test("chaque tranche porte ses pages, plus une page de contexte sauf la dernière", async () => {
    const book = await openBookFile(await buildPdf(10), "pdf");
    const seen: Array<{ label: string; pages: number; owned?: number; context: number }> = [];
    for await (const chunk of book.chunks()) {
      seen.push({
        label: chunk.label,
        pages: await pagesOf(chunk.bytes),
        owned: chunk.window.owned,
        context: chunk.window.context,
      });
    }
    assert.deepEqual(seen, [
      { label: "pages 1–3", pages: 4, owned: 3, context: 1 },
      { label: "pages 4–6", pages: 4, owned: 3, context: 1 },
      { label: "pages 7–9", pages: 4, owned: 3, context: 1 },
      { label: "page 10", pages: 1, owned: 1, context: 0 },
    ]);
  });

  test("le premier extrait d'un PDF est sa première page seule", async () => {
    const book = await openBookFile(await buildPdf(5), "pdf");
    const first = await book.firstPagePdf();
    assert.ok(first);
    assert.equal(await pagesOf(first), 1);
  });

  test("un PDF illisible lève une erreur destinée à l'utilisateur", async () => {
    await assert.rejects(
      () => openBookFile(Buffer.from("%PDF-1.4 pas vraiment"), "pdf"),
      (err: unknown) => err instanceof BookFileError && /n'a pas pu être lu/.test(err.message),
    );
  });

  test("plus de tranches que le plafond : refusé avec le nombre de traitements", async () => {
    // 1 300 pages donneraient 434 tranches. Le PDF est construit une fois, à vide.
    const doc = await PDFDocument.create();
    for (let i = 0; i < 1300; i++) doc.addPage([10, 10]);
    const bytes = Buffer.from(await doc.save());
    await assert.rejects(
      () => openBookFile(bytes, "pdf"),
      (err: unknown) => err instanceof BookFileError && /434 traitements/.test(err.message),
    );
  });
});

describe("buildPdfChunks", () => {
  test("une tranche trop lourde est coupée en deux, chaque moitié gardant son contexte", async () => {
    const source = await openPdf(await buildPdf(10));
    const whole = await buildPdfChunks(source, { firstUnit: 0, ownedUnits: 3, contextUnits: 1 });
    assert.equal(whole.length, 1);

    // Un plafond qu'aucune tranche de quatre pages ne tient, mais que deux pages tiennent.
    const limit = whole[0].bytes.length - 1;
    const split = await buildPdfChunks(
      source,
      { firstUnit: 0, ownedUnits: 3, contextUnits: 1 },
      limit,
    );
    assert.ok(split.length >= 2);
    // Les pages transcrites se suivent sans trou ni recouvrement.
    let next = 0;
    for (const chunk of split) {
      assert.equal(chunk.first, next);
      next += chunk.owned;
    }
    assert.equal(next, 3);
  });

  test("une page seule qui dépasse la limite est refusée, avec son numéro", async () => {
    const source = await openPdf(await buildPdf(4));
    await assert.rejects(
      () => buildPdfChunks(source, { firstUnit: 2, ownedUnits: 1, contextUnits: 1 }, 10),
      (err: unknown) => err instanceof BookFileError && /page 3/.test(err.message),
    );
  });
});

describe("pdfFirstPageImage", () => {
  test("sort l'image JPEG de la première page, sans la décoder", async () => {
    const source = await openPdf(await buildPdf(3, true));
    const cover = await pdfFirstPageImage(source);
    assert.ok(cover);
    const meta = await sharp(cover).metadata();
    assert.equal(meta.format, "jpeg");
    assert.equal(meta.width, 800);
  });

  test("rend null quand la première page n'a aucune image", async () => {
    const source = await openPdf(await buildPdf(3, false));
    assert.equal(await pdfFirstPageImage(source), null);
  });

  test("un livre sans texte dit quoi faire : passer par un PDF", () => {
    for (const message of [EPUB_NO_TEXT_MESSAGE, DOCX_NO_TEXT_MESSAGE]) {
      assert.match(message, /PDF/);
      assert.match(message, /importez/);
    }
  });
});
