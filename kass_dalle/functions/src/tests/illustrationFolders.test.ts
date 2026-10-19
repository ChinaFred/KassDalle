/**
 * Dossier Storage des illustrations d'une recette : contrôle du backfill
 * « Dossiers des illustrations ». Logique pure.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import {
  LEGACY_APP_BUCKET,
  illustrationFolderIssue,
  recipeIllustrationIssues,
} from "../backfills/illustrationFolders";
import { summarizeIllustrationFolders } from "../callable/illustrationFoldersBackfillCallable";

const BUCKET = "kassdale-6d948.firebasestorage.app";
const opts = { buckets: [BUCKET, LEGACY_APP_BUCKET] };

function downloadUrl(path: string, bucket = BUCKET) {
  return `https://firebasestorage.googleapis.com/v0/b/${bucket}/o/${encodeURIComponent(path)}?alt=media&token=t`;
}

describe("illustrationFolderIssue", () => {
  test("illustrations/ et recipes/ : conformes, chemin décodé", () => {
    assert.equal(illustrationFolderIssue(downloadUrl("illustrations/u1/a.jpg"), opts), null);
    assert.equal(illustrationFolderIssue(downloadUrl("recipes/r1/thumb.jpg"), opts), null);
    assert.equal(illustrationFolderIssue(`gs://${BUCKET}/recipes/r1/a.jpg`, opts), null);
    assert.equal(
      illustrationFolderIssue(
        `https://storage.googleapis.com/${BUCKET}/illustrations/u/a.jpg`,
        opts,
      ),
      null,
    );
  });

  test("ancien bucket du projet : conforme", () => {
    assert.equal(
      illustrationFolderIssue(downloadUrl("illustrations/u/a.jpg", LEGACY_APP_BUCKET), opts),
      null,
    );
  });

  test("autre dossier : son premier segment, sans l'uid", () => {
    assert.equal(illustrationFolderIssue(downloadUrl("scans/uid123/p.jpg"), opts), "scans/");
    assert.equal(illustrationFolderIssue(downloadUrl("rejected/uid/p.jpg"), opts), "rejected/");
    assert.equal(illustrationFolderIssue(downloadUrl("a.jpg"), opts), "racine du bucket");
  });

  test("le dossier seul, sans fichier : pas conforme", () => {
    assert.equal(illustrationFolderIssue(downloadUrl("illustrations/"), opts), "chemin mal formé");
  });

  test("segment .. : chemin mal formé", () => {
    assert.equal(
      illustrationFolderIssue(downloadUrl("illustrations/../scans/u/p.jpg"), opts),
      "chemin mal formé",
    );
  });

  test("dossier au nom inattendu : non recopié", () => {
    assert.equal(
      illustrationFolderIssue(downloadUrl("jean@example.com/p.jpg"), opts),
      "dossier inattendu",
    );
  });

  test("autre bucket, autre hôte, chemin nu, valeur vide", () => {
    assert.equal(
      illustrationFolderIssue(downloadUrl("illustrations/u/a.jpg", "autre"), opts),
      "autre bucket",
    );
    assert.equal(
      illustrationFolderIssue("https://example.com/illustrations/a.jpg", opts),
      "hors du stockage de l'application",
    );
    assert.equal(illustrationFolderIssue("illustrations/u/a.jpg", opts), "chemin sans adresse");
    assert.equal(illustrationFolderIssue("", opts), "adresse vide ou illisible");
    assert.equal(illustrationFolderIssue(42, opts), "adresse vide ou illisible");
  });
});

describe("recipeIllustrationIssues", () => {
  test("champs absents ou vides : conforme", () => {
    assert.deepEqual(recipeIllustrationIssues({}, opts), []);
    assert.deepEqual(recipeIllustrationIssues({ image_urls: [], thumbnail_urls: [] }, opts), []);
  });

  test("images puis vignettes, sans doublon", () => {
    const data = {
      image_urls: [downloadUrl("illustrations/u/a.jpg"), downloadUrl("scans/u/p.jpg")],
      thumbnail_urls: [downloadUrl("scans/u/t.jpg"), downloadUrl("rejected/u/t.jpg")],
    };
    assert.deepEqual(recipeIllustrationIssues(data, opts), ["scans/", "rejected/"]);
  });

  test("champ qui n'est pas une liste : signalé", () => {
    assert.deepEqual(recipeIllustrationIssues({ image_urls: "x" }, opts), [
      "image_urls n'est pas une liste",
    ]);
  });
});

describe("summarizeIllustrationFolders", () => {
  const base = {
    examinees: 3,
    conformes: 3,
    horsDossiers: 0,
    echouees: 0,
    depuisLeDebut: true,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: true,
    aRevoir: { items: [], total: 0 },
  };

  test("parcours entier depuis le début, rien à revoir : terminé", () => {
    const s = summarizeIllustrationFolders(base);
    assert.equal(s.complete, true);
    assert.equal(s.remaining, 0);
    assert.equal(s.toReview, 0);
  });

  test("passage repris en cours de collection : jamais terminé", () => {
    const s = summarizeIllustrationFolders({ ...base, depuisLeDebut: false });
    assert.equal(s.complete, false);
    assert.equal(s.remaining, null);
  });

  test("recettes à revoir : comptées", () => {
    const s = summarizeIllustrationFolders({ ...base, aRevoir: { items: [], total: 2 } });
    assert.equal(s.toReview, 2);
  });
});

describe("journal des refus", () => {
  test("URL illisible et chemin mal encodé : rien de la référence dans console.warn ni console.error", () => {
    const warned: string[] = [];
    const errored: string[] = [];
    const originalWarn = console.warn;
    const originalError = console.error;
    console.warn = (...args: unknown[]) => {
      warned.push(args.map((a) => String(a)).join(" "));
    };
    console.error = (...args: unknown[]) => {
      errored.push(args.map((a) => String(a)).join(" "));
    };
    try {
      const unreadable =
        "https://firebasestorage.googleapis.com:99999/v0/b/x/o/scans%2Fuid42%2Fp.jpg?token=secret1";
      const badEncoding = `https://firebasestorage.googleapis.com/v0/b/${BUCKET}/o/scans%2Fuid42%E0%A4%A?token=secret2`;
      const badPublic = `https://storage.googleapis.com/${BUCKET}/scans/uid42%E0%A4%A`;
      assert.equal(illustrationFolderIssue(unreadable, opts), "hors du stockage de l'application");
      assert.equal(illustrationFolderIssue(badEncoding, opts), "hors du stockage de l'application");
      assert.equal(illustrationFolderIssue(badPublic, opts), "hors du stockage de l'application");
    } finally {
      console.warn = originalWarn;
      console.error = originalError;
    }
    // L'URL publique mal encodée est tracée une fois, en erreur, message seul.
    assert.equal(errored.length, 1);
    assert.ok(errored[0].includes("URL publique mal encodée"));
    const all = [...warned, ...errored].join("\n");
    for (const fragment of ["secret1", "secret2", "uid42", "token=", "scans"]) {
      assert.ok(!all.includes(fragment), `la console contient « ${fragment} »`);
    }
  });
});
