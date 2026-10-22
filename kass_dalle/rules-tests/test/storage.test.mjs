// Règles Storage (kass_dalle/storage.rules), rôle par rôle.
//
// Depuis la v0.24.48, une décision qui demande un rôle (dépôt, lecture ou
// listage d'administrateur) lit le jeton PUIS le document `users/{uid}` par
// une règle inter-services : l'émulateur Storage interroge l'émulateur
// Firestore, lancé avec lui (`emulators:exec --only firestore,storage`). Les
// `get` des dossiers publiés lisent le document seul (v0.24.55,
// `isApprovedReader()`). Même convention que firestore.test.mjs pour les
// failles ouvertes (`OPEN_FLAW`).

import { after, before, beforeEach, describe, it } from "node:test";
import { assertFails, assertSucceeds } from "@firebase/rules-unit-testing";
import { PERSONAS, as, createEnv, seedDocs, seedUsers } from "./helpers.mjs";

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

// Les autres fichiers de la suite vident Firestore : les documents
// `users/{uid}` que relisent les règles Storage se réécrivent avant chaque cas.

after(async () => {
  await env.cleanup();
});

beforeEach(async () => {
  await env.clearStorage();
  await seedUsers(env);
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

  // La lecture suit le rôle du DOCUMENT, pas celui du jeton (ticket #162,
  // point 1) : l'aligner sur le jeton a coupé l'accès au fondateur le
  // 2026-10-05, le temps que son jeton porte le claim. Ce test garde ce
  // retour arrière, sur un jeton sans AUCUN claim : isActive() teste la
  // présence de `revoked` avant de le comparer, une clé absente vaut « actif ».
  it("un compte sans claim de rôle lit une image publiée", async () => {
    await assertSucceeds(storage("readerNoClaim").ref(`covers/${OTHER}/image.jpg`).getMetadata());
  });

  for (const dir of PUBLISHED) {
    it(`${dir}/ : un compte en attente ne lit pas une image publiée`, async () => {
      await assertFails(storage("pending").ref(`${dir}/${OTHER}/image.jpg`).getMetadata());
    });

    it(`${dir}/ : un compte nommé à l'instant (jeton pending, document reader) lit`, async () => {
      await assertSucceeds(
        storage("promotedReader").ref(`${dir}/${OTHER}/image.jpg`).getMetadata(),
      );
    });

    it(`${dir}/ : un compte révoqué à l'instant (jeton non révoqué) ne lit plus`, async () => {
      await assertFails(
        storage("revokedStaleToken").ref(`${dir}/${OTHER}/image.jpg`).getMetadata(),
      );
    });
  }

  it("un compte sans document users/{uid} ne lit pas une image publiée", async () => {
    const ctx = env.authenticatedContext("no-doc", { role: "reader", revoked: false });
    await assertFails(ctx.storage().ref(`covers/${OTHER}/image.jpg`).getMetadata());
  });

  it("un document sans rôle se replie sur le claim pour lire", async () => {
    await seedDocs(env, {
      "users/doc-no-role": { is_revoked: false, email: "nr@example.com" },
    });
    const ctx = env.authenticatedContext("doc-no-role", { role: "reader", revoked: false });
    await assertSucceeds(ctx.storage().ref(`covers/${OTHER}/image.jpg`).getMetadata());
  });

  it("un lecteur, un éditeur et le fondateur obtiennent l'adresse d'une image publiée", async () => {
    for (const name of ["reader", "editor", "founder"]) {
      await assertSucceeds(storage(name).ref(`recipes/${OTHER}/image.jpg`).getDownloadURL());
    }
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

// ── rôle et révocation relus sur le document (v0.24.48) ──────────────────
//
// Le jeton vit une heure. Avant la v0.24.48, un administrateur rétrogradé ou
// un compte révoqué gardait ici les droits de son ancien jeton ; Firestore les
// lui retirait déjà (`roleOf()`, `isRevoked()`).

describe("rôle et révocation lus sur users/{uid}", () => {
  const DEMOTED = PERSONAS.demotedAdmin.uid;
  const STALE = PERSONAS.revokedStaleToken.uid;

  it("un administrateur rétrogradé (jeton admin, document editor) ne lit plus rejected/", async () => {
    await assertFails(storage("demotedAdmin").ref(`rejected/${READER}/refusee.jpg`).getMetadata());
  });

  it("un administrateur rétrogradé ne lit plus la quarantaine d'un autre", async () => {
    await assertFails(storage("demotedAdmin").ref(`quarantine/${OTHER}/photo.jpg`).getMetadata());
  });

  it("un administrateur rétrogradé ne liste plus covers/", async () => {
    await assertFails(storage("demotedAdmin").ref("covers").listAll());
  });

  it("un administrateur rétrogradé garde les droits de son nouveau rôle (éditeur)", async () => {
    await assertSucceeds(put("demotedAdmin", `quarantine/${DEMOTED}/f.pdf`, "application/pdf"));
  });

  it("un administrateur dont le jeton et le document concordent lit rejected/ et liste covers/", async () => {
    await assertSucceeds(storage("admin").ref(`rejected/${READER}/refusee.jpg`).getMetadata());
    await assertSucceeds(storage("admin").ref("covers").listAll());
  });

  it("un administrateur révoqué à l'instant (jeton non révoqué) ne lit plus rejected/", async () => {
    await seedDocs(env, {
      "users/stale-admin": { role: "admin", is_revoked: true, email: "sa@example.com" },
    });
    const ctx = env.authenticatedContext("stale-admin", { role: "admin", revoked: false });
    await assertFails(ctx.storage().ref(`rejected/${READER}/refusee.jpg`).getMetadata());
  });

  it("un compte révoqué à l'instant ne dépose plus rien dans sa quarantaine", async () => {
    await assertFails(put("revokedStaleToken", `quarantine/${STALE}/f.jpg`, "image/jpeg"));
    await assertFails(put("revokedStaleToken", `quarantine/${STALE}/f.pdf`, "application/pdf"));
    await assertFails(
      put("revokedStaleToken", `quarantine/${STALE}/livres/l.epub`, "application/epub+zip"),
    );
  });

  it("un compte révoqué à l'instant ne dépose plus de capture de ticket", async () => {
    await assertFails(put("revokedStaleToken", `tickets/${STALE}/t/screenshot.png`, "image/png"));
  });

  it("un éditeur rétrogradé lecteur ne dépose plus de PDF ni de livre, garde ses photos", async () => {
    await seedDocs(env, {
      "users/demoted-editor": { role: "reader", is_revoked: false, email: "de@example.com" },
    });
    const ctx = env.authenticatedContext("demoted-editor", { role: "editor", revoked: false });
    const up = (path, type) => ctx.storage().ref(path).put(small(), { contentType: type });
    await assertFails(up("quarantine/demoted-editor/f.pdf", "application/pdf"));
    await assertFails(up("quarantine/demoted-editor/livres/l.epub", "application/epub+zip"));
    await assertSucceeds(up("quarantine/demoted-editor/f.jpg", "image/jpeg"));
  });

  it("un rôle inconnu sur le document ferme l'accès, même avec un jeton admin", async () => {
    await seedDocs(env, {
      "users/odd-admin": { role: "admin ", is_revoked: false, email: "odd@example.com" },
    });
    const ctx = env.authenticatedContext("odd-admin", { role: "admin", revoked: false });
    await assertFails(ctx.storage().ref(`rejected/${READER}/refusee.jpg`).getMetadata());
    await assertFails(
      ctx.storage().ref("quarantine/odd-admin/f.jpg").put(small(), { contentType: "image/jpeg" }),
    );
  });

  it("un jeton éditeur sans document users/{uid} ne dépose rien", async () => {
    const ctx = env.authenticatedContext("no-doc", { role: "editor", revoked: false });
    await assertFails(
      ctx.storage().ref("quarantine/no-doc/f.jpg").put(small(), { contentType: "image/jpeg" }),
    );
  });

  it("un document sans rôle se replie sur le claim, comme roleOf() côté Firestore", async () => {
    await seedDocs(env, {
      "users/doc-no-role": { is_revoked: false, email: "nr@example.com" },
    });
    const ctx = env.authenticatedContext("doc-no-role", { role: "editor", revoked: false });
    await assertSucceeds(
      ctx
        .storage()
        .ref("quarantine/doc-no-role/f.pdf")
        .put(small(), { contentType: "application/pdf" }),
    );
  });

  // Écart assumé : le jeton reste la première porte. Un compte nommé à
  // l'instant attend son jeton (une heure au plus), comme avant la v0.24.48 ;
  // Firestore, lui, l'accepte tout de suite.
  it("un compte nommé à l'instant (jeton pending) attend son jeton pour déposer", async () => {
    await assertFails(
      put("promotedReader", `quarantine/${PERSONAS.promotedReader.uid}/f.jpg`, "image/jpeg"),
    );
  });

  // Non-régression des chemins courants, documents à jour.
  it("lecteur, éditeur et administrateur cohérents déposent sur leurs chemins courants", async () => {
    await assertSucceeds(put("reader", `quarantine/${READER}/n.jpg`, "image/jpeg"));
    await assertSucceeds(put("reader", `tickets/${READER}/t9/screenshot.png`, "image/png"));
    await assertSucceeds(put("editor", `quarantine/${EDITOR}/n.pdf`, "application/pdf"));
    await assertSucceeds(
      put("editor", `quarantine/${EDITOR}/livres/n.epub`, "application/epub+zip"),
    );
    await assertSucceeds(put("admin", `quarantine/${PERSONAS.admin.uid}/n.png`, "image/png"));
  });

  it("le fondateur lit rejected/ et dépose un livre", async () => {
    await assertSucceeds(storage("founder").ref(`rejected/${READER}/refusee.jpg`).getMetadata());
    await assertSucceeds(
      put("founder", `quarantine/${PERSONAS.founder.uid}/livres/l.pdf`, "application/pdf"),
    );
  });
});
