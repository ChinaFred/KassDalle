/**
 * Ce qui accompagne l'import d'un livre : la consigne donnée au modèle, la
 * lecture d'une tranche sur un job, le titre de repli, le contrôle de fichier et
 * l'estimation de coût.
 *
 * Le contrôle de fichier a changé pour accueillir l'EPUB — une archive ZIP,
 * comme le DOCX — et pour lire un livre de 300 Mo sans le charger : un contenu
 * ZIP sous une extension d'image doit rester refusé.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { BOOK_WINDOW_CONTEXT_MARKER, bookWindowPreamble } from "../gemini/promptsExtraction";
import { parseBookWindow, titleFromFileName } from "../pipeline/bookImport";
import { costPerWindowOfBooks, meanCostPerScan } from "../books/importEstimate";
import {
  MAX_BOOK_UPLOAD_SIZE_BYTES,
  scanUpload,
  scanUploadHead,
  streamContainsEicar,
} from "../utils/uploadSecurity";

describe("bookWindowPreamble", () => {
  test("PDF : dit quelles pages sont à transcrire et laquelle sert de contexte", () => {
    const text = bookWindowPreamble({ kind: "pdf", owned: 3, context: 1 });
    assert.match(text, /compte 4 pages/);
    assert.match(text, /pages 1 à 3 sont celles que tu transcris/);
    assert.match(text, /La page 4 ne sert qu'à terminer/);
    assert.match(text, /ignore-la/);
  });

  test("PDF, dernière tranche : aucune page de contexte n'est annoncée", () => {
    const text = bookWindowPreamble({ kind: "pdf", owned: 1, context: 0 });
    assert.match(text, /compte 1 page\./);
    assert.match(text, /La page 1 est celle que tu transcris/);
    assert.doesNotMatch(text, /ne sert qu'à terminer/);
  });

  test("texte : cite exactement la ligne de séparation écrite dans le texte", () => {
    const text = bookWindowPreamble({ kind: "text", context: 1 });
    assert.ok(text.includes(BOOK_WINDOW_CONTEXT_MARKER));
    const last = bookWindowPreamble({ kind: "text", context: 0 });
    assert.ok(!last.includes(BOOK_WINDOW_CONTEXT_MARKER));
  });
});

describe("parseBookWindow", () => {
  test("relit la tranche écrite sur le job", () => {
    assert.deepEqual(parseBookWindow({ kind: "pdf", owned: 3, context: 1 }), {
      kind: "pdf",
      owned: 3,
      context: 1,
    });
    assert.deepEqual(parseBookWindow({ kind: "text", context: 0 }), { kind: "text", context: 0 });
  });

  test("un job ordinaire n'a pas de tranche", () => {
    assert.equal(parseBookWindow(undefined), undefined);
    assert.equal(parseBookWindow(null), undefined);
    assert.equal(parseBookWindow("pdf"), undefined);
    assert.equal(parseBookWindow({ kind: "image", context: 1 }), undefined);
  });
});

describe("titleFromFileName", () => {
  test("retire l'extension, l'horodatage de l'envoi et les tirets bas", () => {
    assert.equal(titleFromFileName("1758900000000_Le_Riz_Jaune.pdf"), "Le Riz Jaune");
    assert.equal(titleFromFileName("Cuisine.epub"), "Cuisine");
  });

  test("un nom vide ne donne pas un titre vide", () => {
    assert.equal(titleFromFileName(undefined), "Livre importé");
    assert.equal(titleFromFileName(".pdf"), "Livre importé");
  });
});

describe("contrôle de fichier — livres", () => {
  const zip = Buffer.from([0x50, 0x4b, 0x03, 0x04, 0, 0, 0, 0]);
  const pdf = Buffer.from("%PDF-1.7\n...");

  test("un EPUB est une archive ZIP acceptée sous son extension", () => {
    const result = scanUpload({
      fileName: "livre.epub",
      mimeType: "application/epub+zip",
      bytes: zip,
    });
    assert.equal(result.clean, true);
    assert.equal(result.normalizedMimeType, "application/epub+zip");
  });

  test("un DOCX reste accepté", () => {
    const result = scanUpload({ fileName: "recette.docx", bytes: zip });
    assert.equal(result.clean, true);
    assert.match(result.normalizedMimeType ?? "", /wordprocessingml/);
  });

  test("une archive ZIP sous une extension d'image reste refusée", () => {
    const result = scanUpload({ fileName: "photo.jpg", bytes: zip });
    assert.equal(result.clean, false);
    assert.match(result.reason ?? "", /Incoherence/);
  });

  test("les formats d'une page de recette restent acceptés, sous le plafond de 50 Mo", () => {
    const jpeg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0]);
    const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
    const cases: Array<[string, Buffer, string | undefined, string]> = [
      ["page.pdf", pdf, "application/pdf", "application/pdf"],
      ["page.jpg", jpeg, "image/jpeg", "image/jpeg"],
      ["page.PNG", png, "image/png", "image/png"],
      [
        "texte.txt",
        Buffer.from("200 g de farine"),
        "text/plain; charset=utf-8",
        "text/plain; charset=utf-8",
      ],
    ];
    for (const [fileName, bytes, mimeType, expected] of cases) {
      const result = scanUpload({ fileName, mimeType, bytes });
      assert.equal(result.clean, true, fileName);
      assert.equal(result.normalizedMimeType, expected, fileName);
    }
    // Sans plafond passé, une page reste limitée à 50 Mo : le plafond des livres
    // ne s'applique que par `scanUploadHead`.
    const big = scanUploadHead({ fileName: "page.jpg", size: 60 * 1024 * 1024, head: jpeg });
    assert.equal(big.clean, true);
    const bigPage = scanUpload({
      fileName: "page.jpg",
      bytes: Buffer.alloc(51 * 1024 * 1024, 0xff),
    });
    assert.equal(bigPage.clean, false);
    assert.match(bigPage.reason ?? "", /max 50 Mo/);
  });

  test("un PDF déclaré EPUB est refusé", () => {
    const result = scanUpload({ fileName: "livre.epub", bytes: pdf });
    assert.equal(result.clean, false);
  });

  test("scanUploadHead lit la taille annoncée, pas les octets", () => {
    const ok = scanUploadHead({
      fileName: "livre.pdf",
      mimeType: "application/pdf",
      size: 200 * 1024 * 1024,
      head: pdf,
    });
    assert.equal(ok.clean, true);

    const tooBig = scanUploadHead({
      fileName: "livre.pdf",
      size: MAX_BOOK_UPLOAD_SIZE_BYTES + 1,
      head: pdf,
    });
    assert.equal(tooBig.clean, false);
    assert.match(tooBig.reason ?? "", /max 300 Mo/);
  });

  test("scanUploadHead refuse une signature qui ne correspond pas à l'extension", () => {
    const result = scanUploadHead({ fileName: "livre.pdf", size: 1000, head: zip });
    assert.equal(result.clean, false);
  });

  test("la signature EICAR est trouvée même coupée entre deux morceaux du flux", async () => {
    const eicar = "X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*";
    const cut = 17;
    async function* chunks(): AsyncGenerator<Buffer> {
      yield Buffer.from("xxxxxxxxxx" + eicar.slice(0, cut));
      yield Buffer.from(eicar.slice(cut) + "yyyy");
    }
    assert.equal(await streamContainsEicar(chunks()), true);

    async function* clean(): AsyncGenerator<Buffer> {
      yield Buffer.from("Pâte à crêpes, 250 g de farine");
      yield Buffer.from("et deux œufs");
    }
    assert.equal(await streamContainsEicar(clean()), false);
  });
});

describe("meanCostPerScan", () => {
  test("additionne les appels d'un scan puis fait la moyenne des scans", () => {
    const result = meanCostPerScan([
      { scanId: "a", costUsd: 0.1 },
      { scanId: "a", costUsd: 0.1 },
      { scanId: "b", costUsd: 0.3 },
      { scanId: "c", costUsd: 0.1 },
    ]);
    assert.equal(result.scans, 3);
    assert.ok(Math.abs((result.meanUsd ?? 0) - 0.2) < 1e-9);
  });

  test("écarte un scan dont un appel n'a pas de montant", () => {
    const result = meanCostPerScan(
      [
        { scanId: "a", costUsd: 0.1 },
        { scanId: "a", costUsd: null },
        { scanId: "b", costUsd: 0.2 },
        { scanId: "c", costUsd: 0.4 },
      ],
      2,
    );
    assert.equal(result.scans, 2);
    assert.ok(Math.abs((result.meanUsd ?? 0) - 0.3) < 1e-9);
  });

  test("sous le minimum de scans, la mesure est absente et non approximée", () => {
    const result = meanCostPerScan([
      { scanId: "a", costUsd: 0.1 },
      { scanId: "b", costUsd: 0.2 },
    ]);
    assert.equal(result.meanUsd, null);
    assert.equal(result.scans, 2);
  });

  test("aucun appel : pas de mesure", () => {
    assert.deepEqual(meanCostPerScan([]), { meanUsd: null, scans: 0 });
  });
});

describe("costPerWindowOfBooks", () => {
  test("somme des coûts sur somme des tranches : un grand livre pèse plus qu'un petit", () => {
    const result = costPerWindowOfBooks([
      { windows: 100, costUsd: 20 },
      { windows: 10, costUsd: 5 },
    ]);
    assert.equal(result.books, 2);
    assert.ok(Math.abs((result.perWindowUsd ?? 0) - 25 / 110) < 1e-9);
  });

  test("écarte un livre dont un appel n'a pas de montant", () => {
    const result = costPerWindowOfBooks([
      { windows: 50, costUsd: null },
      { windows: 40, costUsd: 8 },
    ]);
    assert.equal(result.books, 1);
    assert.ok(Math.abs((result.perWindowUsd ?? 0) - 0.2) < 1e-9);
  });

  test("aucun livre mesurable : pas de mesure, et pas de valeur inventée", () => {
    assert.deepEqual(costPerWindowOfBooks([]), { perWindowUsd: null, books: 0 });
    assert.deepEqual(costPerWindowOfBooks([{ windows: 0, costUsd: 3 }]), {
      perWindowUsd: null,
      books: 0,
    });
    assert.deepEqual(costPerWindowOfBooks([{ windows: 20, costUsd: 0 }]), {
      perWindowUsd: null,
      books: 0,
    });
  });
});
