// Règles Storage (kass_dalle/storage.rules), rôle par rôle.
//
// Les règles Storage ne lisent que le jeton : rôle et révocation viennent des
// claims frappés par `syncUserClaims`. Même convention que firestore.test.mjs
// pour les failles ouvertes (`OPEN_FLAW`).

import { after, before, beforeEach, describe, it } from "node:test";
import { assertFails, assertSucceeds } from "@firebase/rules-unit-testing";
import { OPEN_FLAW, PERSONAS, as, createEnv } from "./helpers.mjs";

let env;

const NO_CLAIM_GAP = {
  todo: "écart constaté 2026-10-09 : isActive() refuse un jeton sans claim revoked",
};

const storage = (name) => as(env, name).storage();

const READER = PERSONAS.reader.uid;
const OTHER = PERSONAS.otherReader.uid;

const MB = 1024 * 1024;
const small = () => new Uint8Array([1, 2, 3, 4]);
const put = (name, path, contentType, bytes = small()) =>
  storage(name).ref(path).put(bytes, { contentType });

const PUBLISHED = ["covers", "scans", "illustrations", "recipes", "users"];

before(async () => {
  env = await createEnv();
});

after(async () => {
  await env.cleanup();
});

beforeEach(async () => {
  await env.clearStorage();
  await env.withSecurityRulesDisabled(async (ctx) => {
    const s = ctx.storage();
    const files = [
      ...PUBLISHED.map((dir) => `${dir}/${OTHER}/image.jpg`),
      `quarantine/${OTHER}/photo.jpg`,
      `quarantine/${READER}/photo.jpg`,
      `rejected/${READER}/refusee.jpg`,
    ];
    for (const path of files) {
      await s.ref(path).put(small(), { contentType: "image/jpeg" });
    }
  });
});

// ── dossiers publiés ─────────────────────────────────────────────────────

describe("dossiers publiés", () => {
  for (const dir of PUBLISHED) {
    it(`${dir}/ : même un administrateur n'écrit pas`, async () => {
      await assertFails(put("admin", `${dir}/${PERSONAS.admin.uid}/x.jpg`, "image/jpeg"));
    });

    it(`${dir}/ : un éditeur n'écrit pas dans son propre dossier`, async () => {
      await assertFails(put("editor", `${dir}/${PERSONAS.editor.uid}/x.jpg`, "image/jpeg"));
    });

    it(`${dir}/ : un lecteur lit`, async () => {
      await assertSucceeds(storage("reader").ref(`${dir}/${OTHER}/image.jpg`).getMetadata());
    });

    it(`${dir}/ : un compte révoqué ne lit pas`, async () => {
      await assertFails(storage("revoked").ref(`${dir}/${OTHER}/image.jpg`).getMetadata());
    });

    it(`${dir}/ : un anonyme ne lit pas`, async () => {
      await assertFails(storage("anonymous").ref(`${dir}/${OTHER}/image.jpg`).getMetadata());
    });
  }

  it("un administrateur ne supprime pas une image publiée", async () => {
    await assertFails(storage("admin").ref(`covers/${OTHER}/image.jpg`).delete());
  });

  it("un compte en attente ne liste pas un dossier publié", OPEN_FLAW, async () => {
    await assertFails(storage("pending").ref("covers").listAll());
  });

  // La lecture reste sur isActive() (storage.rules, « isApprovedToken ») :
  // l'aligner sur le rôle a coupé l'accès au fondateur le 2026-10-05, le temps
  // que son jeton porte le claim. Ce test garde ce retour arrière.
  //
  // Écart constaté le 2026-10-09 contre l'émulateur : un jeton sans AUCUN
  // claim est refusé. `request.auth.token.revoked != true` lève une erreur
  // sur une clé absente, et l'erreur vaut refus — le commentaire de
  // isActive() (« traité comme actif ») ne se vérifie pas. Un jeton
  // `{ revoked: false }` sans rôle, lui, lit. Marqué `todo` jusqu'à la
  // correction de isActive() (test de présence `'revoked' in request.auth.token`).
  it("un compte sans claim de rôle lit une image publiée", NO_CLAIM_GAP, async () => {
    await assertSucceeds(storage("readerNoClaim").ref(`covers/${OTHER}/image.jpg`).getMetadata());
  });

  // Comportement retenu : un compte en attente lit une image publiée, il ne
  // liste pas le dossier. Aligner la lecture sur le rôle ferait échouer ce test.
  it("un compte en attente lit une image publiée", async () => {
    await assertSucceeds(storage("pending").ref(`covers/${OTHER}/image.jpg`).getMetadata());
  });
});

// ── quarantaine ──────────────────────────────────────────────────────────

describe("quarantaine — propriété et rôle", () => {
  it("un lecteur dépose une photo dans sa quarantaine", async () => {
    await assertSucceeds(put("reader", `quarantine/${READER}/new.jpg`, "image/jpeg"));
  });

  it("un lecteur ne dépose rien dans la quarantaine d'un autre", async () => {
    await assertFails(put("reader", `quarantine/${OTHER}/new.jpg`, "image/jpeg"));
  });

  it("un lecteur ne lit pas la quarantaine d'un autre", async () => {
    await assertFails(storage("reader").ref(`quarantine/${OTHER}/photo.jpg`).getMetadata());
  });

  it("un lecteur lit sa propre quarantaine", async () => {
    await assertSucceeds(storage("reader").ref(`quarantine/${READER}/photo.jpg`).getMetadata());
  });

  it("un administrateur lit la quarantaine d'un autre", async () => {
    await assertSucceeds(storage("admin").ref(`quarantine/${OTHER}/photo.jpg`).getMetadata());
  });

  it("un éditeur ne lit pas la quarantaine d'un autre", async () => {
    await assertFails(storage("editor").ref(`quarantine/${OTHER}/photo.jpg`).getMetadata());
  });

  it("un compte en attente ne dépose rien, même chez lui", async () => {
    await assertFails(put("pending", `quarantine/${PERSONAS.pending.uid}/new.jpg`, "image/jpeg"));
  });

  it("un compte révoqué ne dépose rien, même chez lui", async () => {
    await assertFails(put("revoked", `quarantine/${PERSONAS.revoked.uid}/new.jpg`, "image/jpeg"));
  });

  it("un compte sans claim de rôle ne dépose rien", async () => {
    await assertFails(
      put("readerNoClaim", `quarantine/${PERSONAS.readerNoClaim.uid}/new.jpg`, "image/jpeg"),
    );
  });

  it("un anonyme ne dépose rien", async () => {
    await assertFails(put("anonymous", `quarantine/${READER}/new.jpg`, "image/jpeg"));
  });
});

describe("quarantaine — types et tailles", () => {
  for (const type of [
    "image/png",
    "application/pdf",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "text/plain; charset=utf-8",
  ]) {
    it(`accepte ${type}`, async () => {
      await assertSucceeds(put("reader", `quarantine/${READER}/f`, type));
    });
  }

  for (const type of ["image/gif", "image/svg+xml", "application/zip", "text/html"]) {
    it(`refuse ${type}`, async () => {
      await assertFails(put("reader", `quarantine/${READER}/f`, type));
    });
  }

  it("refuse un EPUB hors de livres/", async () => {
    await assertFails(put("reader", `quarantine/${READER}/livre.epub`, "application/epub+zip"));
  });

  it("accepte un EPUB sous livres/", async () => {
    await assertSucceeds(
      put("reader", `quarantine/${READER}/livres/livre.epub`, "application/epub+zip"),
    );
  });

  // Les deux blocs `match` se recouvrent : sous livres/, un type accepté par
  // l'un OU l'autre passe (une photo de moins de 50 Mo aussi). Un type
  // qu'aucun des deux n'accepte reste refusé.
  it("refuse une archive ZIP sous livres/", async () => {
    await assertFails(put("reader", `quarantine/${READER}/livres/livre.zip`, "application/zip"));
  });

  it("refuse un fichier de 50 Mo hors de livres/", async () => {
    await assertFails(
      put("reader", `quarantine/${READER}/gros.pdf`, "application/pdf", new Uint8Array(50 * MB)),
    );
  });

  it("accepte un fichier de 50 Mo sous livres/", async () => {
    await assertSucceeds(
      put(
        "reader",
        `quarantine/${READER}/livres/gros.pdf`,
        "application/pdf",
        new Uint8Array(50 * MB),
      ),
    );
  });
});

// ── rejected/ ────────────────────────────────────────────────────────────

describe("rejected/", () => {
  it("un administrateur lit une image refusée", async () => {
    await assertSucceeds(storage("admin").ref(`rejected/${READER}/refusee.jpg`).getMetadata());
  });

  it("l'auteur ne relit pas sa propre image refusée", async () => {
    await assertFails(storage("reader").ref(`rejected/${READER}/refusee.jpg`).getMetadata());
  });

  it("un éditeur ne lit pas une image refusée", async () => {
    await assertFails(storage("editor").ref(`rejected/${READER}/refusee.jpg`).getMetadata());
  });

  it("un administrateur révoqué ne lit pas une image refusée", async () => {
    const ctx = env.authenticatedContext("revoked-admin", { role: "admin", revoked: true });
    await assertFails(ctx.storage().ref(`rejected/${READER}/refusee.jpg`).getMetadata());
  });

  it("personne n'écrit dans rejected/, pas même un administrateur", async () => {
    await assertFails(put("admin", `rejected/${PERSONAS.admin.uid}/x.jpg`, "image/jpeg"));
  });
});
