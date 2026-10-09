/**
 * Modération : origine d'une image et propriété de la destination.
 *
 * Deux contournements fermés en v0.23.8 :
 *  - le client déclarait `origin: "ai"` ou `"asset"`, et l'image était
 *    approuvée sans analyse ;
 *  - n'importe quel compte publiait la couverture d'un livre ou l'illustration
 *    d'une recette d'autrui.
 *
 * Logique pure : ni Firestore, ni Storage, ni moteur d'analyse.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import {
  BUNDLED_ASSET_SHA256,
  clientDeclaredOrigin,
  resolveImageOrigin,
  sha256Hex,
} from "../moderation/origin";
import {
  isValidDocumentId,
  legacyFileMayHaveChanged,
  ownedTargetCollection,
  pinnedGeneration,
  targetOwnershipDenial,
} from "../moderation/promote";

const ASSETS_DIR = path.join(__dirname, "..", "..", "..", "assets");

describe("origine déclarée par le client", () => {
  test("« ai » venant d'un client devient « user »", () => {
    assert.equal(clientDeclaredOrigin("ai"), "user");
  });

  test("« asset » reste à vérifier", () => {
    assert.equal(clientDeclaredOrigin("asset"), "asset");
  });

  test("absente ou inconnue : « user »", () => {
    assert.equal(clientDeclaredOrigin(undefined), "user");
    assert.equal(clientDeclaredOrigin("admin"), "user");
  });
});

describe("origine retenue sur les octets", () => {
  test("un « asset » à l'empreinte inconnue est analysé comme une image d'utilisateur", () => {
    const sha = sha256Hex(new Uint8Array([0xff, 0xd8, 0xff, 0x00]));
    assert.deepEqual(resolveImageOrigin("asset", sha), { origin: "user", downgraded: true });
  });

  test("un « asset » livré avec l'application passe sans analyse", () => {
    const sha = Object.keys(BUNDLED_ASSET_SHA256)[0];
    assert.deepEqual(resolveImageOrigin("asset", sha), { origin: "asset", downgraded: false });
  });

  test("« user » et « ai » (serveur) passent tels quels", () => {
    assert.deepEqual(resolveImageOrigin("user", "x"), { origin: "user", downgraded: false });
    assert.deepEqual(resolveImageOrigin("ai", "x"), { origin: "ai", downgraded: false });
  });

  test("une clé héritée d'Object n'est pas une empreinte connue", () => {
    assert.equal(resolveImageOrigin("asset", "constructor").origin, "user");
  });

  // Une couverture livrée qui change sans que son empreinte suive serait
  // analysée — et facturée — à chaque création de livre système.
  test("les empreintes correspondent aux fichiers de kass_dalle/assets/", () => {
    for (const [sha, assetPath] of Object.entries(BUNDLED_ASSET_SHA256)) {
      const bytes = readFileSync(path.join(ASSETS_DIR, path.basename(assetPath)));
      assert.equal(sha256Hex(bytes), sha, assetPath);
    }
  });
});

describe("propriété de la destination", () => {
  const base = {
    callerUid: "reader",
    docExists: true,
    callerIsAdmin: false,
  };

  test("couverture d'un livre d'autrui : refusée", () => {
    assert.notEqual(
      targetOwnershipDenial({
        ...base,
        kind: "book_cover",
        ownerId: "b1",
        docCreatedBy: "other",
      }),
      null,
    );
  });

  test("illustration de la recette d'autrui : refusée, même pour un éditeur", () => {
    assert.notEqual(
      targetOwnershipDenial({
        ...base,
        callerUid: "editor",
        kind: "recipe_illustration",
        ownerId: "r1",
        docCreatedBy: "other",
      }),
      null,
    );
  });

  test("le créateur illustre son livre et sa recette", () => {
    for (const kind of ["book_cover", "recipe_illustration"] as const) {
      assert.equal(
        targetOwnershipDenial({ ...base, kind, ownerId: "x", docCreatedBy: "reader" }),
        null,
      );
    }
  });

  test("l'administrateur agit comme le créateur", () => {
    assert.equal(
      targetOwnershipDenial({
        ...base,
        callerIsAdmin: true,
        kind: "book_cover",
        ownerId: "b1",
        docCreatedBy: "other",
      }),
      null,
    );
  });

  test("document absent ou identifiant manquant : refusé, administrateur compris", () => {
    assert.notEqual(
      targetOwnershipDenial({
        ...base,
        callerIsAdmin: true,
        docExists: false,
        kind: "book_cover",
        ownerId: "b1",
        docCreatedBy: undefined,
      }),
      null,
    );
    assert.notEqual(
      targetOwnershipDenial({
        ...base,
        kind: "recipe_illustration",
        ownerId: null,
        docCreatedBy: "reader",
      }),
      null,
    );
  });

  test("created_by vide n'appartient à personne", () => {
    assert.notEqual(
      targetOwnershipDenial({
        ...base,
        callerUid: "",
        kind: "book_cover",
        ownerId: "b1",
        docCreatedBy: "",
      }),
      null,
    );
  });

  test("destinations personnelles : pas de document à vérifier", () => {
    assert.equal(ownedTargetCollection("draft_illustration"), null);
    assert.equal(ownedTargetCollection("free_recipe_cover"), null);
    assert.equal(
      targetOwnershipDenial({
        ...base,
        kind: "draft_illustration",
        ownerId: null,
        docExists: false,
        docCreatedBy: undefined,
      }),
      null,
    );
  });
});

describe("identifiant du document illustré", () => {
  test("un « / » ou un identifiant réservé est refusé", () => {
    for (const bad of ["a/b", "../x", ".", "..", "__id__", "", 42, null]) {
      assert.equal(isValidDocumentId(bad), false, String(bad));
    }
  });

  test("un identifiant Firestore ordinaire passe", () => {
    assert.equal(isValidDocumentId("aZ09xYz123"), true);
    assert.equal(isValidDocumentId("book_import_job-1"), true);
  });
});

// Entre l'analyse et la promotion, l'envoyeur pouvait réécrire son fichier :
// la copie relisait la nouvelle version. La génération lue avant l'analyse
// est épinglée.
describe("génération épinglée", () => {
  test("une génération numérique est gardée telle quelle", () => {
    assert.equal(pinnedGeneration("1712345678901234"), "1712345678901234");
    assert.equal(pinnedGeneration(1712345678901234), 1712345678901234);
  });

  test("absente ou illisible : pas d'épinglage (documents antérieurs)", () => {
    for (const v of [undefined, null, "", "abc", 0, -1, Number.NaN]) {
      assert.equal(pinnedGeneration(v), undefined, String(v));
    }
  });
});

// Document antérieur à l'épinglage : sans preuve que le fichier n'a pas
// changé depuis l'analyse, l'approbation est refusée.
describe("fichier possiblement réécrit (documents antérieurs)", () => {
  const created = Date.parse("2026-10-01T10:00:00Z");

  test("mis à jour après la création du document : refusé", () => {
    assert.equal(legacyFileMayHaveChanged("2026-10-01T10:05:00Z", created), true);
  });

  test("inchangé depuis : permis", () => {
    assert.equal(legacyFileMayHaveChanged("2026-10-01T09:59:00Z", created), false);
  });

  test("date illisible ou création inconnue : refusé", () => {
    assert.equal(legacyFileMayHaveChanged(undefined, created), true);
    assert.equal(legacyFileMayHaveChanged("2026-10-01T09:59:00Z", null), true);
  });
});
