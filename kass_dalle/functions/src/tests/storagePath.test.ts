/**
 * Chemin Storage venu d'un client (audit sécurité, faille 6) : seuls les
 * dossiers du flux sont lisibles, toute autre forme est refusée. Logique pure.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import {
  PUBLISHED_IMAGE_PREFIXES,
  StoragePathRefusedError,
  allowedStoragePath,
  isWellFormedObjectPath,
  promotedScanPrefix,
  resolveAllowedStoragePath,
  storageObjectPathOf,
} from "../utils/storagePath";

const BUCKET = "kassdale-6d948.firebasestorage.app";
const opts = { bucketName: BUCKET };
const own = [promotedScanPrefix("moi")];

function downloadUrl(path: string, bucket = BUCKET, host = "firebasestorage.googleapis.com") {
  return `https://${host}/v0/b/${bucket}/o/${encodeURIComponent(path)}?alt=media&token=t`;
}

describe("storageObjectPathOf", () => {
  test("chemin nu, gs:// et URL de téléchargement donnent le même chemin", () => {
    const path = "scans/moi/123_page.jpg";
    assert.equal(storageObjectPathOf(path, opts), path);
    assert.equal(storageObjectPathOf(`gs://${BUCKET}/${path}`, opts), path);
    assert.equal(storageObjectPathOf(downloadUrl(path), opts), path);
  });

  test("autre bucket : refusé", () => {
    assert.equal(storageObjectPathOf(downloadUrl("scans/moi/a.jpg", "autre"), opts), null);
    assert.equal(storageObjectPathOf("gs://autre/scans/moi/a.jpg", opts), null);
  });

  test("autre hôte ou autre schéma : refusé", () => {
    const path = "scans/moi/a.jpg";
    assert.equal(storageObjectPathOf(downloadUrl(path, BUCKET, "evil.example.com"), opts), null);
    assert.equal(storageObjectPathOf(downloadUrl(path).replace("https:", "http:"), opts), null);
    assert.equal(storageObjectPathOf("file:///etc/passwd", opts), null);
    assert.equal(storageObjectPathOf("data:image/png;base64,AAAA", opts), null);
  });

  test("émulateur : admis seulement si demandé", () => {
    const url = downloadUrl("scans/moi/a.jpg", BUCKET, "127.0.0.1:9199").replace("https:", "http:");
    assert.equal(storageObjectPathOf(url, opts), null);
    assert.equal(storageObjectPathOf(url, { ...opts, allowEmulator: true }), "scans/moi/a.jpg");
  });

  test("encodage invalide ou référence vide : refusé", () => {
    assert.equal(
      storageObjectPathOf(
        `https://firebasestorage.googleapis.com/v0/b/${BUCKET}/o/scans%2Fmoi%E0%A4%A`,
        opts,
      ),
      null,
    );
    assert.equal(storageObjectPathOf("", opts), null);
  });
});

describe("isWellFormedObjectPath", () => {
  test("segments vides, . et .., antislash, contrôle, / en tête : refusés", () => {
    for (const bad of [
      "scans/moi/../autre/a.jpg",
      "scans/moi/./a.jpg",
      "scans//moi/a.jpg",
      "/scans/moi/a.jpg",
      "scans/moi/",
      "scans\\moi\\a.jpg",
      "scans/moi/a\u0000.jpg",
      "",
    ]) {
      assert.equal(isWellFormedObjectPath(bad), false, bad);
    }
    assert.equal(isWellFormedObjectPath("scans/moi/livres/1_livre.pdf"), true);
  });
});

describe("allowedStoragePath — import (scans du propriétaire)", () => {
  test("ses propres scans : page, livre, tranche de livre", () => {
    for (const path of [
      "scans/moi/1700_page.jpg",
      "scans/moi/livres/1700_livre.pdf",
      "scans/moi/book_import_job1/0001.pdf",
    ]) {
      assert.equal(allowedStoragePath(downloadUrl(path), own, opts), path);
    }
  });

  test("rejected/, quarantaine, scans d'un autre, dossier publié : refusés", () => {
    for (const path of [
      "rejected/moi/a.jpg",
      "quarantine/moi/a.jpg",
      "quarantine/autre/a.jpg",
      "scans/autre/a.jpg",
      "scans/moi2/a.jpg",
      "illustrations/moi/a.jpg",
      "scans/moi/../autre/a.jpg",
    ]) {
      assert.equal(allowedStoragePath(path, own, opts), null, path);
      assert.equal(allowedStoragePath(downloadUrl(path), own, opts), null, path);
    }
  });

  test("le dossier lui-même, sans fichier : refusé", () => {
    assert.equal(allowedStoragePath("scans/moi/", own, opts), null);
  });

  test("propriétaire vide : aucun préfixe valide", () => {
    assert.equal(allowedStoragePath("scans//a.jpg", [promotedScanPrefix("")], opts), null);
  });
});

describe("allowedStoragePath — images publiées", () => {
  test("illustrations et images de recette : admises", () => {
    for (const path of ["illustrations/autre/1_plating.jpg", "recipes/r1/illus_1.png"]) {
      assert.equal(allowedStoragePath(downloadUrl(path), PUBLISHED_IMAGE_PREFIXES, opts), path);
    }
  });

  test("refusées, quarantaine, scans : refusés", () => {
    for (const path of ["rejected/autre/a.jpg", "quarantine/autre/a.jpg", "scans/autre/a.jpg"]) {
      assert.equal(allowedStoragePath(downloadUrl(path), PUBLISHED_IMAGE_PREFIXES, opts), null);
    }
  });
});

describe("resolveAllowedStoragePath", () => {
  test("lève StoragePathRefusedError sur un refus", () => {
    assert.throws(
      () => resolveAllowedStoragePath("rejected/moi/a.jpg", own, opts),
      StoragePathRefusedError,
    );
    assert.equal(resolveAllowedStoragePath("scans/moi/a.jpg", own, opts), "scans/moi/a.jpg");
  });
});
