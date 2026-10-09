/**
 * Lecture bornée d'une archive ZIP — la parade à la bombe zip (DOCX, EPUB).
 *
 * Les bornes se vérifient pendant le dépliage, pas sur les tailles déclarées :
 * ces cas construisent de vraies archives très compressées et vérifient que
 * la lecture s'arrête au franchissement.
 */

import { test, describe, mock } from "node:test";
import assert from "node:assert/strict";
import JSZip from "jszip";

import {
  BoundedZip,
  ZipLimitError,
  countCentralSignatures,
  type ZipLimits,
} from "../utils/boundedZip";
import { docxToPlainText } from "../utils/docx";
import { BookFileError, readEpub } from "../books/bookFile";

const SMALL: ZipLimits = { maxEntries: 5, maxEntryBytes: 1000, maxTotalBytes: 1500 };

async function zipOf(files: Record<string, string>): Promise<Buffer> {
  const zip = new JSZip();
  for (const [path, content] of Object.entries(files)) zip.file(path, content);
  return zip.generateAsync({ type: "nodebuffer", compression: "DEFLATE" });
}

describe("BoundedZip", () => {
  test("lit une entrée sous les bornes", async () => {
    const archive = await BoundedZip.open(await zipOf({ "a.txt": "bonjour" }), SMALL);
    assert.equal(await archive.text("a.txt"), "bonjour");
    assert.equal(await archive.text("absent.txt"), null);
  });

  test("refuse une archive qui contient trop d'entrées", async () => {
    const files: Record<string, string> = {};
    for (let i = 0; i < 6; i++) files[`f${i}.txt`] = "x";
    await assert.rejects(BoundedZip.open(await zipOf(files), SMALL), ZipLimitError);
  });

  test("arrête une entrée qui se déplie au-delà de sa borne", async () => {
    const bytes = await zipOf({ "bombe.txt": "0".repeat(10_000) });
    assert.ok(bytes.length < 1000, "l'archive elle-même reste petite");
    const archive = await BoundedZip.open(bytes, SMALL);
    await assert.rejects(archive.text("bombe.txt"), ZipLimitError);
  });

  test("arrête la lecture cumulée au-delà de la borne totale", async () => {
    const archive = await BoundedZip.open(
      await zipOf({ "a.txt": "a".repeat(900), "b.txt": "b".repeat(900) }),
      SMALL,
    );
    assert.equal((await archive.text("a.txt"))?.length, 900);
    await assert.rejects(archive.text("b.txt"), ZipLimitError);
  });
});

describe("bombe zip — DOCX et EPUB", () => {
  test("un DOCX dont le corps dépasse la borne par défaut est refusé", async () => {
    const huge = "<w:p><w:r><w:t>a</w:t></w:r></w:p>".repeat(2_000_000); // ≈ 70 Mo
    const bytes = await zipOf({ "word/document.xml": huge });
    await assert.rejects(docxToPlainText(bytes), ZipLimitError);
  });

  test("un EPUB dont une page dépasse la borne devient une BookFileError", async () => {
    const container =
      '<container><rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles></container>';
    const opf =
      '<package><manifest><item id="p1" href="p1.xhtml" media-type="application/xhtml+xml"/>' +
      '</manifest><spine><itemref idref="p1"/></spine></package>';
    const bytes = await zipOf({
      "META-INF/container.xml": container,
      "OEBPS/content.opf": opf,
      "OEBPS/p1.xhtml": "<p>" + "a".repeat(60 * 1024 * 1024) + "</p>",
    });
    await assert.rejects(readEpub(bytes), BookFileError);
  });
});

const EOCD = Buffer.from([0x50, 0x4b, 0x05, 0x06]);
const FIVE: ZipLimits = { maxEntries: 5, maxEntryBytes: 1e6, maxTotalBytes: 1e6 };

/** Une archive de `n` entrées, sans compression. */
async function archiveOf(n: number): Promise<Buffer> {
  const zip = new JSZip();
  for (let i = 0; i < n; i++) zip.file(`f${i}`, "x");
  return zip.generateAsync({ type: "nodebuffer" });
}

/** Vérifie que `open` refuse l'archive sans jamais appeler `JSZip.loadAsync`. */
async function refusedBeforeLoad(bytes: Buffer, limits: ZipLimits = FIVE): Promise<void> {
  const load = mock.method(JSZip, "loadAsync");
  try {
    await assert.rejects(BoundedZip.open(bytes, limits), ZipLimitError);
    assert.equal(load.mock.callCount(), 0, "JSZip.loadAsync ne doit pas être appelé");
  } finally {
    load.mock.restore();
  }
}

describe("countCentralSignatures — compte sur les octets, pas sur les annonces", () => {
  test("une vraie archive : autant de signatures que d'entrées", async () => {
    const bytes = await zipOf({ "a.txt": "a", "b.txt": "b", "c/d.txt": "d" });
    const entries = Object.keys((await JSZip.loadAsync(bytes)).files).length;
    assert.equal(countCentralSignatures(bytes, 1000), entries);
  });

  test("s'arrête à la borne", async () => {
    assert.equal(countCentralSignatures(await archiveOf(50), 6), 6);
  });
});

describe("archives forgées — refusées avant JSZip.loadAsync", () => {
  test("EOCD au-delà de la fenêtre de recherche : 70 000 octets après l'archive", async () => {
    const bytes = Buffer.concat([await archiveOf(50), Buffer.alloc(70_000, 0x41)]);
    await refusedBeforeLoad(bytes);
  });

  test("même archive, compteur de l'EOCD ramené à 1", async () => {
    const big = await archiveOf(50);
    const eocd = big.lastIndexOf(EOCD);
    big.writeUInt16LE(1, eocd + 8);
    big.writeUInt16LE(1, eocd + 10);
    await refusedBeforeLoad(Buffer.concat([big, Buffer.alloc(70_000, 0x41)]));
  });

  test("octets préfixés avec un en-tête central leurre à la position non décalée", async () => {
    const big = await archiveOf(50);
    const eocd = big.lastIndexOf(EOCD);
    const small = await archiveOf(1);
    const smallEocd = small.lastIndexOf(EOCD);
    const decoy = small.subarray(small.readUInt32LE(smallEocd + 16), smallEocd);
    const cdOffset = big.readUInt32LE(eocd + 16);
    const prefix = Buffer.alloc(cdOffset + 16, 0);
    decoy.copy(prefix, cdOffset);
    const bytes = Buffer.concat([prefix, big]);
    const forgedEocd = prefix.length + eocd;
    bytes.writeUInt16LE(1, forgedEocd + 8);
    bytes.writeUInt16LE(1, forgedEocd + 10);
    await refusedBeforeLoad(bytes);
  });

  test("ZIP64 avec un faux localisateur devant l'EOCD", async () => {
    const big = await archiveOf(50);
    const eocd = big.lastIndexOf(EOCD);
    const locator = Buffer.alloc(20);
    locator.writeUInt32LE(0x07064b50, 0);
    locator.writeBigUInt64LE(0n, 8); // pointe sur un faux enregistrement ZIP64
    const tail = Buffer.from(big.subarray(eocd));
    tail.writeUInt16LE(1, 8);
    tail.writeUInt16LE(1, 10);
    await refusedBeforeLoad(Buffer.concat([big.subarray(0, eocd), locator, tail]));
  });

  test("archive de plus de maxEntries entrées suivie de 70 000 octets, bornes par défaut", async () => {
    const bytes = Buffer.concat([await archiveOf(10_001), Buffer.alloc(70_000, 0x41)]);
    await refusedBeforeLoad(bytes, {
      maxEntries: 10_000,
      maxEntryBytes: 50 * 1024 * 1024,
      maxTotalBytes: 200 * 1024 * 1024,
    });
  });
});

describe("archives légitimes — acceptées", () => {
  test("une archive valide précédée d'octets préfixés", async () => {
    const bytes = Buffer.concat([Buffer.alloc(1000, 0x41), await zipOf({ "a.txt": "bonjour" })]);
    const archive = await BoundedZip.open(bytes, FIVE);
    assert.equal(await archive.text("a.txt"), "bonjour");
  });

  test("un vrai DOCX et un vrai EPUB passent", async () => {
    const docx = await zipOf({
      "[Content_Types].xml": "<Types/>",
      "word/_rels/document.xml.rels": "<Relationships/>",
      "word/document.xml":
        "<w:document><w:body><w:p><w:r><w:t>Farine</w:t></w:r></w:p></w:body></w:document>",
    });
    const epub = await zipOf({
      mimetype: "application/epub+zip",
      "META-INF/container.xml": "<container/>",
      "OEBPS/content.opf": "<package/>",
      "OEBPS/p1.xhtml": "<p>a</p>",
    });
    assert.equal(await docxToPlainText(docx), "Farine");
    assert.ok(await BoundedZip.open(epub));
  });
});
