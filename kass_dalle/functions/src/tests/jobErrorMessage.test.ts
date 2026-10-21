/**
 * Message d'un job d'import en échec (audit #151, ticket #171) : le texte brut
 * d'une exception (gRPC, SDK, fournisseur, bibliothèque) ne va jamais dans
 * `error_message`, que le membre lit. Logique pure.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import {
  ARCHIVE_LIMIT_MESSAGE,
  MEMBER_WRITTEN_FAILURES,
  PIPELINE_ERROR_MESSAGE,
  PROVIDER_QUOTA_MESSAGE,
  SOURCE_REFUSED_MESSAGE,
  TAGGING_TRUNCATED_MESSAGE,
  jobErrorMessage,
} from "../pipeline/jobErrorMessage";
import { BookFileError, openBookFile, technicalErrorText } from "../books/bookFile";

const RAW = "13 INTERNAL: Received RST_STREAM with code 2";

describe("jobErrorMessage", () => {
  test("échec générique : texte fixe, jamais le texte brut", () => {
    assert.equal(jobErrorMessage("pipeline_error", RAW), PIPELINE_ERROR_MESSAGE);
  });

  test("quota du fournisseur : texte fixe, pas le message du fournisseur", () => {
    assert.equal(
      jobErrorMessage("quota_exceeded", "429 Resource has been exhausted (e.g. check quota)."),
      PROVIDER_QUOTA_MESSAGE,
    );
  });

  test("archive, chemin refusé, balisage coupé : textes fixes", () => {
    assert.equal(
      jobErrorMessage("archive_limit_exceeded", "entrée « word/document.xml » trop volumineuse"),
      ARCHIVE_LIMIT_MESSAGE,
    );
    assert.equal(jobErrorMessage("forbidden_source_path", RAW), SOURCE_REFUSED_MESSAGE);
    assert.equal(jobErrorMessage("tagging_truncated", RAW), TAGGING_TRUNCATED_MESSAGE);
  });

  test("raison inconnue : texte générique", () => {
    assert.equal(jobErrorMessage("nouvelle_raison", RAW), PIPELINE_ERROR_MESSAGE);
  });

  test("messages rédigés pour le membre : recopiés tels quels", () => {
    for (const reason of MEMBER_WRITTEN_FAILURES) {
      assert.equal(jobErrorMessage(reason, "Phrase pour le membre."), "Phrase pour le membre.");
    }
    assert.deepEqual([...MEMBER_WRITTEN_FAILURES].sort(), [
      "book_file_unreadable",
      "budget_exceeded",
      "foreign_book",
      "too_large",
      "too_many_pages",
    ]);
  });

  test("message rédigé mais vide : texte générique", () => {
    assert.equal(jobErrorMessage("budget_exceeded", "  "), PIPELINE_ERROR_MESSAGE);
  });
});

describe("BookFileError — détail technique hors du message", () => {
  test("PDF illisible : le texte de pdf-lib reste dans detail", async () => {
    let caught: unknown;
    try {
      await openBookFile(Buffer.from("%PDF-1.4 pas vraiment"), "pdf");
    } catch (err) {
      caught = err;
    }
    assert.ok(caught instanceof BookFileError);
    assert.equal(
      caught.message,
      "Ce PDF n'a pas pu être lu : le fichier est abîmé ou n'est pas un PDF. " +
        "Exportez-le de nouveau, puis recommencez.",
    );
    assert.ok(caught.detail && caught.detail.length > 0);
    assert.ok(technicalErrorText(caught).includes(caught.detail));
  });

  test("sans cause : pas de détail, le texte technique est le message", () => {
    const err = new BookFileError("Ce PDF ne contient aucune page.");
    assert.equal(err.detail, null);
    assert.equal(technicalErrorText(err), "Ce PDF ne contient aucune page.");
  });
});
