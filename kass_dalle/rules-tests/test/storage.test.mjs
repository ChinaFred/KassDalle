// Règles Storage (kass_dalle/storage.rules), rôle par rôle.
//
// Les règles Storage ne lisent que le jeton : rôle et révocation viennent des
// claims frappés par `syncUserClaims`. Même convention que firestore.test.mjs
// pour les failles ouvertes (`OPEN_FLAW`).

import { after, before, beforeEach, describe, it } from "node:test";
import { assertFails, assertSucceeds } from "@firebase/rules-unit-testing";
import { PERSONAS, as, createEnv } from "./helpers.mjs";

let env;

const storage = (name) => as(env, name).storage();

const READER = PERSONAS.reader.uid;
const OTHER = PERSONAS.otherReader.uid;
const EDITOR = PERSONAS.editor.uid;

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

  // Lire un fichier dont on a l'adresse reste ouvert ; lister le dossier
  // d'un autre ne l'est pas.
  it("un lecteur ne liste pas le dossier scans/ d'un autre", async () => {
    await assertFails(storage("reader").ref(`scans/${OTHER}`).listAll());
  });

  it("un lecteur liste son propre dossier scans/", async () => {
    await assertSucceeds(storage("reader").ref(`scans/${READER}`).listAll());
  });

  it("un administrateur liste le dossier scans/ d'un autre", async () => {
    await assertSucceeds(storage("admin").ref(`scans/${OTHER}`).listAll());
  });

  for (const dir of ["covers", `illustrations/${OTHER}`, `users/${OTHER}`]) {
    it(`un lecteur ne liste pas ${dir}`, async () => {
      await assertFails(storage("reader").ref(dir).listAll());
    });

    it(`un administrateur liste ${dir}`, async () => {
      await assertSucceeds(storage("admin").ref(dir).listAll());
    });
  }

  it("un lecteur ne liste pas le dossier d'une recette", async () => {
    await assertFails(storage("reader").ref(`recipes/${OTHER}`).listAll());
  });

  it("un administrateur liste le dossier d'une recette", async () => {
    await assertSucceeds(storage("admin").ref(`recipes/${OTHER}`).listAll());
  });

  it("un administrateur ne supprime pas une image publiée", async () => {
    await assertFails(storage("admin").ref(`covers/${OTHER}/image.jpg`).delete());
  });

  it("un compte en attente ne liste pas un dossier publié", async () => {
    await assertFails(storage("pending").ref("covers").listAll());
  });

  // La lecture reste sur isActive() (storage.rules, « isApprovedToken ») :
  // l'aligner sur le rôle a coupé l'accès au fondateur le 2026-10-05, le temps
  // que son jeton porte le claim. Ce test garde ce retour arrière, sur un
  // jeton sans AUCUN claim : isActive() teste la présence de `revoked` avant
  // de le comparer, une clé absente vaut « actif ».
  it("un compte sans claim de rôle lit une image publiée", async () => {
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
  // Un éditeur ou un administrateur dépose tous les types d'un import.
  for (const type of [
    "image/png",
    "application/pdf",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "text/plain; charset=utf-8",
  ]) {
    it(`un éditeur dépose ${type}`, async () => {
      await assertSucceeds(put("editor", `quarantine/${EDITOR}/f`, type));
    });
  }

  for (const type of ["image/gif", "image/svg+xml", "application/zip", "text/html"]) {
    it(`refuse ${type}, même à un éditeur`, async () => {
      await assertFails(put("editor", `quarantine/${EDITOR}/f`, type));
    });
  }

  it("refuse un EPUB hors de livres/", async () => {
    await assertFails(put("editor", `quarantine/${EDITOR}/livre.epub`, "application/epub+zip"));
  });

  it("un éditeur dépose un EPUB sous livres/", async () => {
    await assertSucceeds(
      put("editor", `quarantine/${EDITOR}/livres/livre.epub`, "application/epub+zip"),
    );
  });

  it("un administrateur dépose un EPUB sous livres/", async () => {
    await assertSucceeds(
      put("admin", `quarantine/${PERSONAS.admin.uid}/livres/livre.epub`, "application/epub+zip"),
    );
  });

  // Les deux blocs `match` se recouvrent : sous livres/, un type accepté par
  // l'un OU l'autre passe (une photo de moins de 50 Mo aussi). Un type
  // qu'aucun des deux n'accepte reste refusé.
  it("refuse une archive ZIP sous livres/", async () => {
    await assertFails(put("editor", `quarantine/${EDITOR}/livres/livre.zip`, "application/zip"));
  });

  it("refuse un fichier de 50 Mo hors de livres/", async () => {
    await assertFails(
      put("editor", `quarantine/${EDITOR}/gros.pdf`, "application/pdf", new Uint8Array(50 * MB)),
    );
  });

  it("un éditeur dépose un PDF de 50 Mo sous livres/", async () => {
    await assertSucceeds(
      put(
        "editor",
        `quarantine/${EDITOR}/livres/gros.pdf`,
        "application/pdf",
        new Uint8Array(50 * MB),
      ),
    );
  });
});

// Un lecteur n'importe pas (`requireEditor`, `isEditor()` sur les jobs) : il ne
// dépose que les photos à modérer — couverture « Recette libre », illustration
// d'une de ses recettes (audit #151, ticket #162).
describe("quarantaine — ce que dépose un lecteur", () => {
  for (const type of ["image/jpeg", "image/png"]) {
    it(`un lecteur dépose ${type}`, async () => {
      await assertSucceeds(put("reader", `quarantine/${READER}/f`, type));
    });
  }

  for (const type of [
    "application/pdf",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "text/plain; charset=utf-8",
  ]) {
    it(`un lecteur ne dépose pas ${type}`, async () => {
      await assertFails(put("reader", `quarantine/${READER}/f`, type));
    });
  }

  it("un lecteur ne dépose pas d'EPUB sous livres/", async () => {
    await assertFails(
      put("reader", `quarantine/${READER}/livres/livre.epub`, "application/epub+zip"),
    );
  });

  it("un lecteur ne dépose pas de PDF sous livres/", async () => {
    await assertFails(put("reader", `quarantine/${READER}/livres/livre.pdf`, "application/pdf"));
  });

  // Les deux blocs se recouvrent : sans l'exclusion de livres/ dans le bloc
  // général, cette photo passerait.
  it("un lecteur ne dépose pas de photo sous livres/", async () => {
    await assertFails(put("reader", `quarantine/${READER}/livres/photo.jpg`, "image/jpeg"));
  });

  it("un lecteur ne dépose pas de photo de 50 Mo", async () => {
    await assertFails(
      put("reader", `quarantine/${READER}/gros.jpg`, "image/jpeg", new Uint8Array(50 * MB)),
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

// ── tickets/ ─────────────────────────────────────────────────────────────

describe("tickets/ — capture d'un ticket", () => {
  const mine = (ext = "png") => `tickets/${READER}/t1/screenshot.${ext}`;

  beforeEach(async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx.storage().ref(`tickets/${OTHER}/t2/screenshot.png`).put(small(), {
        contentType: "image/png",
      });
      await ctx.storage().ref(mine("jpg")).put(small(), { contentType: "image/jpeg" });
    });
  });

  it("l'auteur dépose une capture PNG ou JPEG dans son dossier", async () => {
    await assertSucceeds(put("reader", mine("png"), "image/png"));
    await assertSucceeds(put("reader", mine("jpg"), "image/jpeg"));
  });

  it("refuse un autre nom de fichier ou un autre type", async () => {
    await assertFails(put("reader", `tickets/${READER}/t1/autre.png`, "image/png"));
    await assertFails(put("reader", `tickets/${READER}/t1/screenshot.gif`, "image/gif"));
    await assertFails(put("reader", mine("png"), "application/pdf"));
  });

  it("refuse une capture de plus de 5 Mo", async () => {
    await assertFails(put("reader", mine("png"), "image/png", new Uint8Array(5 * MB + 1)));
  });

  it("personne ne dépose dans le dossier d'un autre, pas même l'administrateur", async () => {
    await assertFails(put("reader", `tickets/${OTHER}/t2/screenshot.png`, "image/png"));
    await assertFails(put("admin", `tickets/${OTHER}/t2/screenshot.png`, "image/png"));
  });

  it("un compte en attente, révoqué ou anonyme ne dépose rien", async () => {
    await assertFails(
      put("pending", `tickets/${PERSONAS.pending.uid}/t/screenshot.png`, "image/png"),
    );
    await assertFails(
      put("revoked", `tickets/${PERSONAS.revoked.uid}/t/screenshot.png`, "image/png"),
    );
    await assertFails(put("anonymous", `tickets/anon/t/screenshot.png`, "image/png"));
  });

  it("l'auteur et l'administrateur lisent la capture, un autre membre non", async () => {
    await assertSucceeds(storage("reader").ref(mine("jpg")).getMetadata());
    await assertSucceeds(storage("admin").ref(mine("jpg")).getMetadata());
    await assertFails(storage("otherReader").ref(mine("jpg")).getMetadata());
    await assertFails(storage("editor").ref(mine("jpg")).getMetadata());
  });

  it("un autre membre approuvé ne liste pas le dossier de l'auteur", async () => {
    await assertFails(storage("otherReader").ref(`tickets/${READER}`).listAll());
    await assertFails(storage("otherReader").ref(`tickets/${READER}/t1`).listAll());
    await assertFails(storage("editor").ref(`tickets/${READER}/t1`).listAll());
  });

  it("un compte révoqué ne relit pas sa capture", async () => {
    await env.withSecurityRulesDisabled(async (ctx) => {
      await ctx
        .storage()
        .ref(`tickets/${PERSONAS.revoked.uid}/t/screenshot.png`)
        .put(small(), { contentType: "image/png" });
    });
    await assertFails(
      storage("revoked").ref(`tickets/${PERSONAS.revoked.uid}/t/screenshot.png`).getMetadata(),
    );
  });

  it("l'auteur ne supprime pas sa capture", async () => {
    await assertFails(storage("reader").ref(mine("jpg")).delete());
  });
});
