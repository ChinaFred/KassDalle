/**
 * Modération d'images : JPEG et PNG seulement, type lu sur les octets
 * (ticket #157). Le type déclaré par le client n'entre pas en compte.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  MODERATION_IMAGE_MIME_TYPES,
  moderationImageMime,
  scanUpload,
  storedModerationMime,
} from "../utils/uploadSecurity";

const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10]);
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00]);
const PDF = Buffer.from("%PDF-1.7\n");
const ZIP = Buffer.from([0x50, 0x4b, 0x03, 0x04, 0x00]);
const TEXT = Buffer.from("<html><script>alert(1)</script></html>");
const WEBP = Buffer.from("RIFF\x00\x00\x00\x00WEBPVP8 ", "latin1");

describe("moderationImageMime", () => {
  test("JPEG et PNG reconnus sur leur signature", () => {
    assert.equal(moderationImageMime(JPEG), "image/jpeg");
    assert.equal(moderationImageMime(PNG), "image/png");
  });

  test("formats d'import refusés : PDF, archive (DOCX, EPUB), texte", () => {
    assert.equal(moderationImageMime(PDF), null);
    assert.equal(moderationImageMime(ZIP), null);
    assert.equal(moderationImageMime(TEXT), null);
  });

  test("WebP refusé, et fichier vide", () => {
    assert.equal(moderationImageMime(WEBP), null);
    assert.equal(moderationImageMime(Buffer.alloc(0)), null);
  });

  test("un texte, quel que soit son nom, n'est pas une image à modérer", () => {
    assert.equal(moderationImageMime(TEXT), null);
  });
});

describe("scanUpload — un .txt se déclare texte", () => {
  test("déclaré image/jpeg ou application/pdf : refusé", () => {
    for (const mimeType of ["image/jpeg", "application/pdf"]) {
      const scan = scanUpload({ fileName: "a.txt", mimeType, bytes: TEXT });
      assert.equal(scan.clean, false, mimeType);
    }
  });

  test("déclaré texte ou sans type : admis, rendu en type texte", () => {
    assert.equal(
      scanUpload({ fileName: "a.txt", mimeType: "text/plain", bytes: TEXT }).normalizedMimeType,
      "text/plain",
    );
    assert.equal(
      scanUpload({ fileName: "a.txt", mimeType: "text/plain; charset=utf-8", bytes: TEXT })
        .normalizedMimeType,
      "text/plain; charset=utf-8",
    );
    assert.equal(scanUpload({ fileName: "a.txt", bytes: TEXT }).normalizedMimeType, "text/plain");
  });

  test("un .txt aux octets d'image : refusé", () => {
    assert.equal(
      scanUpload({ fileName: "a.txt", mimeType: "text/plain", bytes: JPEG }).clean,
      false,
    );
  });

  test("seuls deux types admis", () => {
    assert.deepEqual([...MODERATION_IMAGE_MIME_TYPES].sort(), ["image/jpeg", "image/png"]);
  });
});

describe("storedModerationMime — promotion manuelle", () => {
  test("JPEG et PNG gardés, casse et espaces normalisés", () => {
    assert.equal(storedModerationMime("image/jpeg"), "image/jpeg");
    assert.equal(storedModerationMime(" Image/PNG "), "image/png");
  });

  test("tout autre type refusé", () => {
    for (const v of ["text/html", "application/pdf", "image/svg+xml", "image/webp", "", null, 3]) {
      assert.equal(storedModerationMime(v), null, String(v));
    }
  });
});
