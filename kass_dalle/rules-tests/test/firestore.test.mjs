// Règles Firestore (kass_dalle/firestore.rules), rôle par rôle.
//
// Deux natures de tests :
//  - les tests normaux décrivent le comportement ACTUEL jugé sain : ils
//    doivent passer, et la CI échoue s'ils cassent ;
//  - les tests marqués `OPEN_FLAW` décrivent le comportement CORRIGÉ d'une
//    faille relevée par l'audit du 2026-10-09 et encore ouverte. Ils échouent
//    aujourd'hui sans faire échouer la suite ; la correction retire l'option.

import { after, before, beforeEach, describe, it } from "node:test";
import { assertFails, assertSucceeds } from "@firebase/rules-unit-testing";
import firebase from "firebase/compat/app";
import "firebase/compat/firestore";
import {
  FOUNDER_EMAIL,
  PERSONAS,
  as,
  createEnv,
  currentScansKey,
  seedDocs,
  seedUsers,
} from "./helpers.mjs";

let env;

// Transformations du SDK compat, celui que rend `ctx.firestore()`.
const { FieldValue } = firebase.firestore;
const increment = (n) => FieldValue.increment(n);
const deleteField = () => FieldValue.delete();
const serverTimestamp = () => FieldValue.serverTimestamp();

const db = (name) => as(env, name).firestore();

const READER = PERSONAS.reader.uid;
const OTHER = PERSONAS.otherReader.uid;
const EDITOR = PERSONAS.editor.uid;

before(async () => {
  env = await createEnv();
});

after(async () => {
  await env.cleanup();
});

beforeEach(async () => {
  await env.clearFirestore();
  await seedUsers(env);
  await seedDocs(env, {
    "books/public": { title: "Livre commun", created_by: EDITOR, is_private: false, tags: [] },
    "books/private-other": {
      title: "Carnet privé",
      created_by: OTHER,
      is_private: true,
      tags: [],
    },
    "books/private-reader": {
      title: "Mon carnet",
      created_by: READER,
      is_private: true,
      tags: [],
    },
    "books/public-other": {
      title: "Livre d'un autre",
      created_by: OTHER,
      is_private: false,
      tags: [],
    },
    "books/system": { title: "Recettes libres", created_by: EDITOR, tags: ["__libres"] },
    "books/web_editor": {
      title: "Mes recettes du web",
      created_by: EDITOR,
      tags: ["__web"],
      is_private: true,
    },
    "books/private-editor": {
      title: "Carnet de l'éditeur",
      created_by: EDITOR,
      is_private: true,
      tags: [],
    },
    "books/public-reader": {
      title: "Mon livre partagé",
      created_by: READER,
      is_private: false,
      tags: [],
    },
    "recipes/validated": {
      title: "Tarte",
      created_by: OTHER,
      review_status: "validated",
      is_private: false,
    },
    "recipes/validated-private-other": {
      title: "Recette secrète",
      created_by: OTHER,
      review_status: "validated",
      is_private: true,
    },
    "recipes/validated-private-reader": {
      title: "Ma recette secrète",
      created_by: READER,
      review_status: "validated",
      is_private: true,
    },
    "recipes/editor-own": { title: "Gratin", created_by: EDITOR, review_status: "validated" },
    "recipes/draft-other": {
      title: "Brouillon",
      created_by: OTHER,
      review_status: "draft",
      is_private: false,
    },
    "recipes/in-reader-private-book": {
      title: "Ma soupe secrète",
      book_id: "private-reader",
      created_by: READER,
      review_status: "validated",
      is_private: true,
    },
    "recipes/reader-in-other-book": {
      title: "Ma page chez un autre",
      book_id: "public-other",
      created_by: READER,
      review_status: "validated",
      is_private: false,
    },
    "recipes/legacy-no-flag": { title: "Ancienne", created_by: OTHER, review_status: "validated" },
    "recipes/draft-reader": { title: "Mon brouillon", created_by: READER, review_status: "draft" },
    "recipes/web-reader": {
      title: "Quiche",
      created_by: READER,
      review_status: "draft",
      origin: "web",
      source_url: "https://www.site.fr/quiche",
      source_site: "site.fr",
      source_author: "Marie Dupont",
      source_nutrition: { per_portion: { kcal: 420 }, portions: 6, ingredients_fingerprint: "" },
      source_nutrition_check: { state: "ok", portions: 6, ratios: { kcal: 1 }, gaps: [] },
    },
    "recipes/web-editor-author": {
      title: "Quiche",
      created_by: EDITOR,
      review_status: "draft",
      origin: "web",
      source_url: "https://www.site.fr/quiche",
      source_site: "site.fr",
      source_author: "Marie Dupont",
      source_nutrition: { per_portion: { kcal: 420 }, portions: 6, ingredients_fingerprint: "" },
    },
    "recipes/web-editor": {
      title: "Quiche",
      created_by: EDITOR,
      review_status: "draft",
      origin: "web",
      source_url: "https://www.site.fr/quiche",
      source_site: "site.fr",
    },
    "recipes/web-other-private": {
      title: "Secret du web",
      created_by: OTHER,
      review_status: "validated",
      is_private: true,
      source_url: "https://secret.example/recette",
      source_site: "secret.example",
    },
    "recipes/in-public-book": {
      title: "Soupe",
      book_id: "public-other",
      created_by: OTHER,
      review_status: "validated",
      is_private: false,
    },
    "recipes/in-private-book": {
      title: "Soupe secrète",
      book_id: "private-other",
      created_by: OTHER,
      review_status: "validated",
      is_private: true,
    },
    "recipes/validated-private-other/annotations/a1": { uid: OTHER, text: "note privée" },
    "recipes/validated/annotations/mine": { uid: READER, text: "ma note" },
    "recipe_ratings/r1": {
      user_id: READER,
      recipe_id: "validated",
      rating: 4,
      updated_at: new Date(),
    },
    "recipe_ratings/r-other": { user_id: OTHER, recipe_id: "validated", rating: 3 },
    "recipe_ratings/r-other-private": {
      user_id: OTHER,
      recipe_id: "validated-private-other",
      rating: 5,
    },
    "recipes/validated/annotations/other": { uid: OTHER, text: "note d'un autre" },
    "recipes/validated/origine/texte": { langue: "en", titre: "Banana bread" },
    "recipes/validated-private-other/origine/texte": { langue: "en", titre: "Secret" },
    "groups/g1": { name: "Famille", owner_id: READER, member_ids: [READER] },
    // La famille : lecteur, autre lecteur et éditeur partagent un groupe.
    // `stranger` n'en partage aucun. La portée est ce qu'écrit
    // `syncGroupReach` à partir des groupes.
    "groups/famille": { name: "Famille", owner_id: OTHER, member_ids: [OTHER, READER, EDITOR] },
    "group_reach/reader": { uids: [EDITOR, OTHER] },
    "group_reach/other-reader": { uids: [EDITOR, READER] },
    "group_reach/editor": { uids: [OTHER, READER] },
    "group_reach/reader-no-claim": { uids: [EDITOR] },
    "app_config/usage": { storage_bytes: 10, updated_at: 1 },
    "app_config/ai_pricing": { models: {} },
    "app_config/nutrition_policy": { mode: "strict" },
    "app_config/backfill_schedules": {
      nutrition: { enabled: true, days: [1, 2, 3, 4, 5, 6, 7], hour: 5 },
    },
    "app_config/backfill_run_nutrition": {
      doc_type: "backfill_run",
      key: "nutrition",
      dernier_passage_statut: "termine",
    },
    "processing_jobs/job-reader": { created_by: READER, status: "processing" },
    "processing_jobs/job-editor": { created_by: EDITOR, status: "error" },
    "processing_jobs/url-done": { created_by: EDITOR, status: "done", type: "recipeUrlImport" },
    "processing_jobs/url-timeout": {
      created_by: EDITOR,
      status: "error",
      type: "recipeUrlImport",
      error_code: "timeout",
    },
    "processing_jobs/url-timeout-2": {
      created_by: EDITOR,
      status: "error",
      type: "recipeUrlImport",
      error_code: "timeout",
      url_retry_count: 2,
    },
    "processing_jobs/url-processing": {
      created_by: EDITOR,
      status: "processing",
      type: "recipeUrlImport",
      url_retry_count: 1,
    },
    "processing_jobs/url-blocked": {
      created_by: EDITOR,
      status: "error",
      type: "recipeUrlImport",
      error_code: "page_blocked",
    },
    "planned_meals/m1": { uid: READER, date: "2026-10-09" },
    "planned_meals/m-editor": { uid: EDITOR, date: "2026-10-12" },
    "ai_usage/u1": { uid: READER, cost_usd: 0.01 },
    "ai_usage/u2": { uid: OTHER, cost_usd: 0.02 },
    "ai_daily_spend/d1": { uid: READER, total: 0.01 },
    "url_import_daily/editor_2026-10-11": { uid: EDITOR, day: "2026-10-11", count: 3 },
    "web_search_daily/reader_2026-10-12": { uid: READER, day: "2026-10-12", count: 4 },
    "web_search_cache/abc": { query: "quiche", results: [], cached_at: "2026-10-12" },
    "nutrition_ingredients/farine": { name: "farine", kcal: 364, shopping_product: "farine" },
    "users/founder": PERSONAS.founder.doc,
    "user_profiles/other-reader": { display_name: "Autre Lecteur", preferred_name: null },
  });
});

// ── users ────────────────────────────────────────────────────────────────

describe("users — création de compte", () => {
  const fresh = (claims = { email: "new@example.com", email_verified: true }) =>
    env.authenticatedContext("newcomer", claims).firestore();

  it("refuse la création quand l'adresse du jeton n'est pas vérifiée", async () => {
    await assertFails(
      fresh({ email: "new@example.com", email_verified: false })
        .doc("users/newcomer")
        .set({ role: "pending", is_revoked: false, email: "new@example.com" }),
    );
  });

  it("refuse la création quand le jeton ne dit pas si l'adresse est vérifiée", async () => {
    await assertFails(
      fresh({ email: "new@example.com" })
        .doc("users/newcomer")
        .set({ role: "pending", is_revoked: false, email: "new@example.com" }),
    );
  });

  it("accepte la création quand l'adresse du jeton est vérifiée", async () => {
    await assertSucceeds(
      fresh({ email: "new@example.com", email_verified: true })
        .doc("users/newcomer")
        .set({ role: "pending", is_revoked: false, email: "new@example.com" }),
    );
  });

  it("un compte neuf se crée en pending, non révoqué, à l'adresse de son jeton", async () => {
    await assertSucceeds(
      fresh()
        .doc("users/newcomer")
        .set({ role: "pending", is_revoked: false, email: "new@example.com" }),
    );
  });

  it("refuse la création avec le rôle admin", async () => {
    await assertFails(
      fresh()
        .doc("users/newcomer")
        .set({ role: "admin", is_revoked: false, email: "new@example.com" }),
    );
  });

  it("refuse la création avec le rôle reader", async () => {
    await assertFails(
      fresh()
        .doc("users/newcomer")
        .set({ role: "reader", is_revoked: false, email: "new@example.com" }),
    );
  });

  it("refuse une adresse différente de celle du jeton", async () => {
    await assertFails(
      fresh().doc("users/newcomer").set({
        role: "pending",
        is_revoked: false,
        email: "china.fred.75@gmail.com",
      }),
    );
  });

  it("refuse la création du document d'un autre uid", async () => {
    await assertFails(
      fresh()
        .doc("users/someone-else")
        .set({ role: "pending", is_revoked: false, email: "new@example.com" }),
    );
  });

  it("refuse la création anonyme", async () => {
    await assertFails(
      db("anonymous")
        .doc("users/newcomer")
        .set({ role: "pending", is_revoked: false, email: "new@example.com" }),
    );
  });

  it("refuse un nom Google de 61 caractères à la création", async () => {
    await assertFails(
      fresh().doc("users/newcomer").set({
        role: "pending",
        is_revoked: false,
        email: "new@example.com",
        display_name: "a".repeat(61),
      }),
    );
  });

  it("accepte un nom Google de 60 caractères à la création", async () => {
    await assertSucceeds(
      fresh().doc("users/newcomer").set({
        role: "pending",
        is_revoked: false,
        email: "new@example.com",
        display_name: "a".repeat(60),
      }),
    );
  });

  // `string.size()` compte en unités UTF-16 : un emoji vaut 2. Les deux
  // `truncateName` (Dart, TypeScript) coupent de la même façon, donc un nom
  // Google de 30 emoji, la plus longue coupe possible, passe la règle.
  it("accepte un nom de 30 emoji à la création", async () => {
    await assertSucceeds(
      fresh().doc("users/newcomer").set({
        role: "pending",
        is_revoked: false,
        email: "new@example.com",
        display_name: "😀".repeat(30),
      }),
    );
  });

  it("refuse un nom de 31 emoji (62 unités UTF-16) à la création", async () => {
    await assertFails(
      fresh().doc("users/newcomer").set({
        role: "pending",
        is_revoked: false,
        email: "new@example.com",
        display_name: "😀".repeat(31),
      }),
    );
  });
});

describe("users — longueur des noms", () => {
  it("un lecteur ne pose pas un nom préféré de 61 caractères", async () => {
    await assertFails(
      db("reader").doc(`users/${READER}`).update({ preferred_name: "a".repeat(61) }),
    );
  });

  it("un lecteur pose un nom préféré de 60 caractères", async () => {
    await assertSucceeds(
      db("reader").doc(`users/${READER}`).update({ preferred_name: "a".repeat(60) }),
    );
  });

  it("un lecteur efface son nom préféré", async () => {
    await assertSucceeds(db("reader").doc(`users/${READER}`).update({ preferred_name: null }));
  });

  it("un nom préféré qui n'est pas une chaîne est refusé", async () => {
    await assertFails(
      db("reader").doc(`users/${READER}`).update({ preferred_name: { x: "a".repeat(10) } }),
    );
  });

  it("un lecteur ne pose pas un nom Google de 61 caractères", async () => {
    await assertFails(
      db("reader").doc(`users/${READER}`).update({ display_name: "a".repeat(61) }),
    );
  });

  it("un administrateur ne pose pas un nom préféré de 61 caractères", async () => {
    await assertFails(
      db("admin").doc(`users/${READER}`).update({ preferred_name: "a".repeat(61) }),
    );
  });

  it("un compte ancien au nom trop long reste modifiable sans toucher au nom", async () => {
    await seedDocs(env, {
      "users/long-name": {
        role: "reader",
        is_revoked: false,
        email: "long@example.com",
        display_name: "a".repeat(80),
      },
    });
    await assertSucceeds(db("admin").doc("users/long-name").update({ role: "editor" }));
  });
});

describe("users — rôle et révocation", () => {
  it("un lecteur ne change pas son propre rôle", async () => {
    await assertFails(db("reader").doc(`users/${READER}`).update({ role: "admin" }));
  });

  it("un lecteur ne lève pas sa propre révocation", async () => {
    await assertFails(
      db("revoked").doc(`users/${PERSONAS.revoked.uid}`).update({ is_revoked: false }),
    );
  });

  // `applyRevokedInvitation` se déclenche sur cette écriture : un compte
  // révoqué invité de nouveau par e-mail retrouve l'accès en se connectant.
  it("un compte révoqué écrit sa connexion (last_seen_at, nom, photo)", async () => {
    await assertSucceeds(
      db("revoked")
        .doc(`users/${PERSONAS.revoked.uid}`)
        .update({
          last_seen_at: new Date("2026-10-12T10:00:00Z"),
          display_name: "Gabriel",
          photo_url: "https://lh3.googleusercontent.com/a/photo",
        }),
    );
  });

  it("un compte révoqué ne se donne pas de rôle en écrivant sa connexion", async () => {
    await assertFails(
      db("revoked")
        .doc(`users/${PERSONAS.revoked.uid}`)
        .update({ last_seen_at: serverTimestamp(), role: "admin" }),
    );
  });

  it("un compte pending ne se nomme pas lui-même", async () => {
    await assertFails(
      db("pending").doc(`users/${PERSONAS.pending.uid}`).update({ role: "reader" }),
    );
  });

  it("un lecteur ne change pas son adresse", async () => {
    await assertFails(
      db("reader").doc(`users/${READER}`).update({ email: "china.fred.75@gmail.com" }),
    );
  });

  it("un lecteur modifie un champ neutre de son profil", async () => {
    await assertSucceeds(db("reader").doc(`users/${READER}`).update({ display_name: "Lou" }));
  });

  it("un administrateur nomme un compte en attente", async () => {
    await assertSucceeds(
      db("admin").doc(`users/${PERSONAS.pending.uid}`).update({ role: "reader" }),
    );
  });

  it("un éditeur ne nomme personne", async () => {
    await assertFails(db("editor").doc(`users/${PERSONAS.pending.uid}`).update({ role: "reader" }));
  });

  it("un administrateur révoqué ne nomme personne", async () => {
    const ctx = env
      .authenticatedContext("revoked-admin", { role: "admin", revoked: true })
      .firestore();
    await seedDocs(env, {
      "users/revoked-admin": { role: "admin", is_revoked: true, email: "ra@example.com" },
    });
    await assertFails(ctx.doc(`users/${PERSONAS.pending.uid}`).update({ role: "admin" }));
  });
});

describe("users — fondateur", () => {
  it("un administrateur ne change pas le rôle du fondateur", async () => {
    await assertFails(db("admin").doc("users/founder").update({ role: "reader" }));
  });

  it("un administrateur ne révoque pas le fondateur", async () => {
    await assertFails(db("admin").doc("users/founder").update({ is_revoked: true }));
  });

  it("un administrateur ne supprime pas le fondateur", async () => {
    await assertFails(db("admin").doc("users/founder").delete());
  });

  it("le fondateur touche à son propre rôle", async () => {
    await assertSucceeds(db("founder").doc("users/founder").update({ role: "admin" }));
  });

  it("un administrateur ne change pas l'adresse du fondateur", async () => {
    await assertFails(db("admin").doc("users/founder").update({ email: "x@example.com" }));
  });

  it("un administrateur ne retire pas l'adresse du fondateur", async () => {
    const { default: firebase } = await import("firebase/compat/app");
    await import("firebase/compat/firestore");
    await assertFails(
      db("admin").doc("users/founder").update({ email: firebase.firestore.FieldValue.delete() }),
    );
  });

  it("le fondateur, connecté par Google à l'adresse vérifiée, change le rôle du document fondateur", async () => {
    await assertSucceeds(db("founder").doc("users/founder").update({ role: "editor" }));
  });

  // Audit sécurité (« à confirmer ») : l'adresse seule suffisait.
  for (const [label, token] of [
    ["adresse non vérifiée", { email_verified: false, firebase: { sign_in_provider: "google.com" } }],
    ["connexion par mot de passe", { email_verified: true, firebase: { sign_in_provider: "password" } }],
    ["sans email_verified", { firebase: { sign_in_provider: "google.com" } }],
  ]) {
    it(`un administrateur à l'adresse du fondateur (${label}) ne destitue pas le fondateur`, async () => {
      await seedDocs(env, {
        "users/fake-founder": { role: "admin", is_revoked: false, email: FOUNDER_EMAIL },
      });
      const ctx = env
        .authenticatedContext("fake-founder", {
          role: "admin",
          revoked: false,
          email: FOUNDER_EMAIL,
          ...token,
        })
        .firestore();
      await assertFails(ctx.doc("users/founder").update({ role: "reader" }));
    });
  }

  it("changer l'adresse puis le rôle du fondateur échoue dès la première écriture", async () => {
    await assertFails(
      db("admin").doc("users/founder").update({ email: "x@example.com", role: "reader" }),
    );
    await assertFails(db("admin").doc("users/founder").update({ role: "reader" }));
  });
});

// Audit sécurité : la couverture « Recette libre » est recopiée dans le
// profil public ; une adresse externe y passait sans modération.
describe("users — couverture « Recette libre »", () => {
  const COVER =
    "https://firebasestorage.googleapis.com/v0/b/kassdale-6d948.firebasestorage.app/o/" +
    `users%2F${READER}%2Ffree_recipe_cover_1760000000000.jpg?alt=media&token=abc-123`;

  it("un lecteur ne pose pas une adresse externe sur son compte", async () => {
    await assertFails(
      db("reader").doc(`users/${READER}`).update({ free_recipe_cover_url: "https://exemple.org/x.png" }),
    );
  });

  it("un lecteur pose l'adresse Storage de sa couverture modérée", async () => {
    await assertSucceeds(db("reader").doc(`users/${READER}`).update({ free_recipe_cover_url: COVER }));
  });

  it("une adresse du bucket hors de users/ (quarantaine) est refusée", async () => {
    await assertFails(
      db("reader")
        .doc(`users/${READER}`)
        .update({ free_recipe_cover_url: COVER.replace("users%2F", "quarantine%2F") }),
    );
  });

  // Relecture sécurité : `[^/#]+` laissait remonter hors de users/{uid}/.
  for (const path of [
    `users%2F..%2Fquarantine%2F${READER}%2Fx.jpg`,
    `users%2F%2E%2E%2Fquarantine%2F${READER}%2Fx.jpg`,
    `users%2F${READER}%2F..%2F..%2Fquarantine%2F${READER}%2Ffree_recipe_cover_1.jpg`,
    `users%2F${READER}%2Ffree_recipe_cover_1%252Ejpg`,
    `users%2F${OTHER}%2Ffree_recipe_cover_1.jpg`,
  ]) {
    it(`une adresse détournée est refusée : ${path}`, async () => {
      const url =
        "https://firebasestorage.googleapis.com/v0/b/kassdale-6d948.firebasestorage.app/o/" +
        path +
        "?alt=media&token=t";
      await assertFails(db("reader").doc(`users/${READER}`).update({ free_recipe_cover_url: url }));
    });
  }

  it("une adresse de plus de 500 caractères est refusée", async () => {
    await assertFails(
      db("reader")
        .doc(`users/${READER}`)
        .update({ free_recipe_cover_url: COVER + "x".repeat(500) }),
    );
  });

  it("effacer la couverture reste permis", async () => {
    await assertSucceeds(db("reader").doc(`users/${READER}`).update({ free_recipe_cover_url: null }));
  });

  it("un compte neuf ne naît pas avec une couverture externe", async () => {
    const ctx = env.authenticatedContext("newcomer", {
      email: "new@example.com",
      email_verified: true,
    }).firestore();
    const base = { role: "pending", is_revoked: false, email: "new@example.com" };
    await assertFails(
      ctx.doc("users/newcomer").set({ ...base, free_recipe_cover_url: "https://exemple.org/x.png" }),
    );
    await assertSucceeds(ctx.doc("users/newcomer").set({ ...base, free_recipe_cover_url: null }));
  });
});

describe("users — adresse immuable", () => {
  it("un administrateur ne change pas l'adresse d'un autre compte", async () => {
    await assertFails(db("admin").doc(`users/${READER}`).update({ email: "x@example.com" }));
  });

  it("un administrateur ne change pas sa propre adresse", async () => {
    await assertFails(
      db("admin").doc(`users/${PERSONAS.admin.uid}`).update({ email: "x@example.com" }),
    );
  });

  it("le fondateur ne change pas son adresse", async () => {
    await assertFails(db("founder").doc("users/founder").update({ email: "x@example.com" }));
  });

  it("un administrateur modifie un champ neutre d'un autre compte", async () => {
    await assertSucceeds(
      db("admin").doc(`users/${READER}`).update({ preferred_name: "Lou" }),
    );
  });

  it("une réécriture qui garde la même adresse reste permise", async () => {
    await assertSucceeds(
      db("reader")
        .doc(`users/${READER}`)
        .update({ email: PERSONAS.reader.doc.email, display_name: "Lou" }),
    );
  });

  it("un compte ancien sans adresse reste nommable, sans qu'on lui en ajoute une", async () => {
    await seedDocs(env, { "users/legacy": { role: "pending", is_revoked: false } });
    await assertSucceeds(db("admin").doc("users/legacy").update({ role: "reader" }));
    await assertFails(db("admin").doc("users/legacy").update({ email: FOUNDER_EMAIL }));
  });
});

describe("users — lecture", () => {
  it("chacun lit son propre document, même en attente", async () => {
    await assertSucceeds(db("pending").doc(`users/${PERSONAS.pending.uid}`).get());
  });

  it("un lecteur ne lit pas le document d'un autre", async () => {
    await assertFails(db("reader").doc(`users/${OTHER}`).get());
  });

  // Fermé en v0.23.14 : les noms des autres membres se lisent désormais
  // dans `user_profiles/{uid}`.
  it("un éditeur ne lit pas le document d'un autre", async () => {
    await assertFails(db("editor").doc(`users/${OTHER}`).get());
  });

  it("un éditeur ne liste pas les comptes", async () => {
    await assertFails(db("editor").collection("users").limit(10).get());
  });

  it("un administrateur lit le document d'un autre", async () => {
    await assertSucceeds(db("admin").doc(`users/${OTHER}`).get());
  });

  it("un administrateur liste les comptes", async () => {
    await assertSucceeds(db("admin").collection("users").get());
  });

  it("un anonyme ne lit aucun document de compte", async () => {
    await assertFails(db("anonymous").doc(`users/${READER}`).get());
  });
});

// ── user_profiles ─────────────────────────────────────────────────────────

describe("user_profiles — profils publics", () => {
  const profile = { display_name: "Autre Lecteur", preferred_name: null };

  it("un lecteur lit le profil public d'un autre", async () => {
    await assertSucceeds(db("reader").doc(`user_profiles/${OTHER}`).get());
  });

  it("un éditeur lit le profil public d'un autre", async () => {
    await assertSucceeds(db("editor").doc(`user_profiles/${OTHER}`).get());
  });

  it("un lecteur liste les profils publics", async () => {
    await assertSucceeds(db("reader").collection("user_profiles").limit(200).get());
  });

  it("un compte en attente ne lit aucun profil", async () => {
    await assertFails(db("pending").doc(`user_profiles/${OTHER}`).get());
  });

  it("un compte révoqué ne lit aucun profil", async () => {
    await assertFails(db("revokedStaleToken").doc(`user_profiles/${OTHER}`).get());
  });

  it("un anonyme ne lit aucun profil", async () => {
    await assertFails(db("anonymous").doc(`user_profiles/${OTHER}`).get());
  });

  it("personne n'écrit son propre profil côté client", async () => {
    await assertFails(
      db("reader").doc(`user_profiles/${READER}`).set({ display_name: "Usurpé" }),
    );
  });

  it("un éditeur n'écrit pas le profil d'un autre", async () => {
    await assertFails(db("editor").doc(`user_profiles/${OTHER}`).update({ display_name: "X" }));
  });

  it("un administrateur n'écrit pas de profil côté client", async () => {
    await assertFails(db("admin").doc(`user_profiles/${OTHER}`).set(profile));
  });

  it("personne ne supprime un profil côté client", async () => {
    await assertFails(db("admin").doc(`user_profiles/${OTHER}`).delete());
  });
});

// ── books ────────────────────────────────────────────────────────────────

describe("books", () => {
  it("un lecteur lit un livre commun", async () => {
    await assertSucceeds(db("reader").doc("books/public").get());
  });

  it("le rôle se lit sur le document quand le jeton n'a pas de claim", async () => {
    await assertSucceeds(db("readerNoClaim").doc("books/public").get());
  });

  for (const who of ["pending", "revoked", "revokedStaleToken", "anonymous"]) {
    it(`${who} ne lit aucun livre`, async () => {
      await assertFails(db(who).doc("books/public").get());
    });
  }

  it("un lecteur ne crée pas de livre", async () => {
    await assertFails(db("reader").doc("books/new").set({ title: "x", created_by: READER }));
  });

  it("un éditeur crée un livre", async () => {
    await assertSucceeds(db("editor").doc("books/new").set({ title: "x", created_by: EDITOR }));
  });

  it("un éditeur révoqué n'écrit plus, même jeton périmé", async () => {
    await assertFails(db("revokedStaleToken").doc("books/public").update({ title: "y" }));
  });

  it("un éditeur ne supprime pas un livre système", async () => {
    await assertFails(db("editor").doc("books/system").delete());
  });

  it("un éditeur supprime un livre ordinaire", async () => {
    await assertSucceeds(db("editor").doc("books/public").delete());
  });

  it("un lecteur ne lit pas le livre privé d'un autre", async () => {
    await assertFails(db("reader").doc("books/private-other").get());
  });

  it("un lecteur lit son propre livre privé", async () => {
    await assertSucceeds(db("reader").doc("books/private-reader").get());
  });

  it("un administrateur lit le livre privé d'un autre", async () => {
    await assertSucceeds(db("admin").doc("books/private-other").get());
  });

  it("un éditeur modifie son propre livre", async () => {
    await assertSucceeds(db("editor").doc("books/public").update({ title: "y" }));
  });

  it("un éditeur ne lit pas le livre privé d'un autre", async () => {
    await assertFails(db("editor").doc("books/private-other").get());
  });

  it("un éditeur ne modifie pas le livre d'un autre", async () => {
    await assertFails(db("editor").doc("books/public-other").update({ title: "y" }));
  });

  it("un éditeur ne supprime pas le livre d'un autre", async () => {
    await assertFails(db("editor").doc("books/public-other").delete());
  });

  it("un éditeur ne crée pas de livre au nom d'un autre", async () => {
    await assertFails(db("editor").doc("books/new").set({ title: "x", created_by: OTHER }));
  });

  it("un éditeur ne change pas created_by de son livre", async () => {
    await assertFails(db("editor").doc("books/public").update({ created_by: OTHER }));
  });

  it("un administrateur modifie le livre privé d'un autre", async () => {
    await assertSucceeds(db("admin").doc("books/private-other").update({ title: "y" }));
  });

  it("un administrateur supprime le livre d'un autre", async () => {
    await assertSucceeds(db("admin").doc("books/public-other").delete());
  });

  it("un administrateur ne change pas created_by d'un livre", async () => {
    await assertFails(db("admin").doc("books/public-other").update({ created_by: EDITOR }));
  });

  // Le livre système appartient à l'éditeur : même son propriétaire ne
  // retire pas le tag qui le protège de la suppression.
  it("le propriétaire ne retire pas le tag d'un livre système", async () => {
    await assertFails(db("editor").doc("books/system").update({ tags: [] }));
  });

  it("un administrateur ne retire pas le tag d'un livre système", async () => {
    await assertFails(db("admin").doc("books/system").update({ tags: [] }));
  });

  it("le tag d'un livre système ne se perd pas en supprimant le champ", async () => {
    await assertFails(db("editor").doc("books/system").update({ tags: deleteField() }));
  });

  it("le propriétaire renomme un livre système", async () => {
    await assertSucceeds(db("editor").doc("books/system").update({ title: "Mes libres" }));
  });

  it("un livre système garde son tag et en reçoit un autre", async () => {
    await assertSucceeds(
      db("editor")
        .doc("books/system")
        .update({ tags: ["__libres", "dessert"] }),
    );
  });

  it("« Mes recettes du web » est un livre système : il ne se supprime pas", async () => {
    await assertFails(db("editor").doc("books/web_editor").delete());
  });

  it("un éditeur ne crée pas le livre web d'un autre compte (web_<uid>)", async () => {
    await assertFails(
      db("editor")
        .doc(`books/web_${OTHER}`)
        .set({ title: "Mes recettes du web", created_by: EDITOR, is_private: false }),
    );
  });

  it("un éditeur ne crée pas le livre web de repli d'un autre compte (web2_<uid>)", async () => {
    await assertFails(
      db("editor")
        .doc(`books/web2_${OTHER}`)
        .set({ title: "Mes recettes du web", created_by: EDITOR, is_private: false }),
    );
  });

  it("un éditeur ne crée pas le livre système d'un autre compte (libres_<uid>…)", async () => {
    for (const prefix of ["kassdalle", "libres", "secretes"]) {
      await assertFails(
        db("editor")
          .doc(`books/${prefix}_${OTHER}`)
          .set({ titre: "Mes recettes libres", created_by: EDITOR, tags: [], is_private: false }),
      );
    }
  });

  it("un éditeur lit son propre livre système encore absent (transaction du client)", async () => {
    await assertSucceeds(db("editor").doc(`books/secretes_${EDITOR}`).get());
  });

  it("un lecteur ou un compte en attente ne lit pas son identifiant fixe absent", async () => {
    await assertFails(db("reader").doc(`books/secretes_${READER}`).get());
    await assertFails(db("pending").doc("books/secretes_pending").get());
  });

  it("un éditeur ne lit pas l'identifiant fixe absent d'un autre compte", async () => {
    await assertFails(db("editor").doc(`books/secretes_${OTHER}`).get());
  });

  it("un administrateur ne crée pas le livre système d'un autre compte côté client", async () => {
    await assertFails(
      db("admin")
        .doc(`books/libres_${OTHER}`)
        .set({ titre: "Mes recettes libres", created_by: PERSONAS.admin.uid, tags: [], is_private: false }),
    );
  });

  it("un identifiant voisin du motif réservé reste un livre ordinaire", async () => {
    await assertSucceeds(
      db("editor")
        .doc("books/libresX")
        .set({ titre: "Libres", created_by: EDITOR, tags: [], is_private: false }),
    );
  });

  it("un éditeur crée ses propres livres système sous leur identifiant fixe", async () => {
    await assertSucceeds(
      db("editor")
        .doc(`books/libres_${EDITOR}`)
        .set({ titre: "Mes recettes libres", created_by: EDITOR, tags: ["__libres"], is_private: false }),
    );
  });

  it("un éditeur ne crée pas de livre portant le tag __web", async () => {
    await assertFails(
      db("editor")
        .doc("books/piege")
        .set({ title: "x", created_by: EDITOR, tags: ["__web"], is_private: false }),
    );
  });

  it("les autres livres système restent créés par le client", async () => {
    await assertSucceeds(
      db("editor")
        .doc("books/libres-neuf")
        .set({ title: "Mes recettes libres", created_by: EDITOR, tags: ["__libres"] }),
    );
  });

  it("« Mes recettes du web » garde son tag", async () => {
    await assertFails(db("editor").doc("books/web_editor").update({ tags: ["web"] }));
  });

  // `_ensureWebBookCover` (appelée par `ensureSystemBooks`) pose la couverture
  // côté client : le créateur doit pouvoir écrire `url_couverture` sur le
  // livre créé par le serveur.
  it("le créateur pose la couverture de « Mes recettes du web »", async () => {
    await assertSucceeds(
      db("editor")
        .doc("books/web_editor")
        .update({ url_couverture: "https://example.com/c.png", updated_at: serverTimestamp() }),
    );
  });

  it("un autre compte ne pose pas la couverture de « Mes recettes du web »", async () => {
    await assertFails(
      db("reader")
        .doc("books/web_editor")
        .update({ url_couverture: "https://example.com/c.png", updated_at: serverTimestamp() }),
    );
  });

  it("un livre ordinaire change ses tags librement", async () => {
    await assertSucceeds(db("editor").doc("books/public").update({ tags: ["été"] }));
  });
});

// ── recipes ──────────────────────────────────────────────────────────────

describe("recipes — lecture", () => {
  it("un lecteur lit une recette validée commune", async () => {
    await assertSucceeds(db("reader").doc("recipes/validated").get());
  });

  it("un lecteur ne lit pas le brouillon d'un autre", async () => {
    await assertFails(db("reader").doc("recipes/draft-other").get());
  });

  it("un lecteur lit son propre brouillon", async () => {
    await assertSucceeds(db("reader").doc("recipes/draft-reader").get());
  });

  // Droit conservé : un éditeur relit le brouillon PARTAGÉ d'un autre. La
  // confidentialité (is_private) l'emporte — créateur seul, plus
  // l'administrateur — et l'éditeur ne modifie pas ce brouillon.
  it("un éditeur lit le brouillon partagé d'un autre", async () => {
    await assertSucceeds(db("editor").doc("recipes/draft-other").get());
  });

  for (const who of ["pending", "revoked", "anonymous"]) {
    it(`${who} ne lit aucune recette`, async () => {
      await assertFails(db(who).doc("recipes/validated").get());
    });
  }

  it("un lecteur lit sa propre recette privée", async () => {
    await assertSucceeds(db("reader").doc("recipes/validated-private-reader").get());
  });

  it("un administrateur lit la recette privée d'un autre", async () => {
    await assertSucceeds(db("admin").doc("recipes/validated-private-other").get());
  });

  it("un lecteur ne lit pas la recette privée validée d'un autre", async () => {
    await assertFails(db("reader").doc("recipes/validated-private-other").get());
  });

  it("un éditeur ne lit pas la recette privée d'un autre", async () => {
    await assertFails(db("editor").doc("recipes/validated-private-other").get());
  });

  // Un document sans `is_private` n'est pas prouvé partagé : seul son
  // créateur (ou un administrateur) le lit.
  it("une recette sans is_private n'est lue que par son créateur", async () => {
    await assertFails(db("reader").doc("recipes/legacy-no-flag").get());
    await assertSucceeds(db("otherReader").doc("recipes/legacy-no-flag").get());
  });

  it("un lecteur ne lit pas une recette d'un livre privé d'autrui", async () => {
    await assertFails(db("reader").doc("recipes/in-private-book").get());
  });
});

describe("recipes — écriture", () => {
  // Le lecteur ne crée aucune recette (refonte de l'écran Explorer, lot 2) :
  // ni saisie, ni copie, ni création par l'IA, ni import. Ses recettes
  // existantes restent les siennes : il les modifie et les supprime.
  it("un lecteur ne crée pas de recette, même à son nom", async () => {
    await assertFails(
      db("reader")
        .doc("recipes/new")
        .set({ title: "x", created_by: READER, review_status: "draft" }),
    );
  });

  it("un lecteur ne crée pas de copie d'une recette", async () => {
    await assertFails(
      db("reader").doc("recipes/new").set({
        title: "x",
        created_by: READER,
        review_status: "draft",
        source_recipe_id: "validated",
      }),
    );
  });

  it("un éditeur crée son brouillon à son nom", async () => {
    await assertSucceeds(
      db("editor")
        .doc("recipes/new")
        .set({ title: "x", created_by: EDITOR, review_status: "draft" }),
    );
  });

  it("un administrateur crée son brouillon à son nom", async () => {
    await assertSucceeds(
      db("admin")
        .doc("recipes/new")
        .set({ title: "x", created_by: PERSONAS.admin.uid, review_status: "draft" }),
    );
  });

  it("un éditeur ne crée pas de recette au nom d'un autre", async () => {
    await assertFails(
      db("editor")
        .doc("recipes/new")
        .set({ title: "x", created_by: OTHER, review_status: "draft" }),
    );
  });

  it("un compte en attente ne crée pas de recette", async () => {
    await assertFails(
      db("pending")
        .doc("recipes/new")
        .set({ title: "x", created_by: PERSONAS.pending.uid, review_status: "draft" }),
    );
  });

  it("un lecteur ne modifie pas la recette d'un autre", async () => {
    await assertFails(db("reader").doc("recipes/validated").update({ title: "y" }));
  });

  it("un lecteur modifie sa recette", async () => {
    await assertSucceeds(db("reader").doc("recipes/draft-reader").update({ title: "y" }));
  });

  it("un lecteur ne supprime pas la recette d'un autre", async () => {
    await assertFails(db("reader").doc("recipes/validated").delete());
  });

  it("un lecteur ne vide pas created_by de sa recette", async () => {
    await assertFails(db("reader").doc("recipes/draft-reader").update({ created_by: "" }));
  });

  it("un lecteur ne donne pas sa recette à un autre (created_by)", async () => {
    await assertFails(db("reader").doc("recipes/draft-reader").update({ created_by: OTHER }));
  });

  it("un administrateur modifie la recette d'un autre", async () => {
    await assertSucceeds(db("admin").doc("recipes/validated").update({ title: "y" }));
  });

  it("un administrateur supprime la recette d'un autre", async () => {
    await assertSucceeds(db("admin").doc("recipes/validated").delete());
  });

  it("un éditeur ne modifie pas la recette d'un autre", async () => {
    await assertFails(db("editor").doc("recipes/validated").update({ title: "y" }));
  });

  it("un éditeur ne supprime pas la recette d'un autre", async () => {
    await assertFails(db("editor").doc("recipes/validated").delete());
  });

  it("un éditeur ne change pas created_by de sa propre recette", async () => {
    await assertFails(db("editor").doc("recipes/editor-own").update({ created_by: OTHER }));
  });

  it("un éditeur modifie sa propre recette", async () => {
    await assertSucceeds(db("editor").doc("recipes/editor-own").update({ title: "y" }));
  });

  it("un administrateur modifie la recette privée d'un autre", async () => {
    await assertSucceeds(db("admin").doc("recipes/validated-private-other").update({ title: "y" }));
  });

  it("un administrateur supprime la recette privée d'un autre", async () => {
    await assertSucceeds(db("admin").doc("recipes/validated-private-other").delete());
  });

  it("un administrateur ne change pas created_by d'une recette", async () => {
    await assertFails(db("admin").doc("recipes/validated").update({ created_by: EDITOR }));
  });

  it("un administrateur ne crée pas de recette au nom d'un autre", async () => {
    await assertFails(
      db("admin").doc("recipes/new").set({ title: "x", created_by: OTHER, review_status: "draft" }),
    );
  });
});

// Une recette prend la confidentialité de son livre, à toute écriture qui pose
// ou change son livre ou sa confidentialité.
describe("recipes — adresse de la page d'origine (source_url)", () => {
  it("un éditeur ne crée pas de recette avec une adresse inventée", async () => {
    await assertFails(
      db("editor").doc("recipes/new").set({
        title: "x",
        created_by: EDITOR,
        review_status: "draft",
        source_url: "https://www.site.fr/autre",
      }),
    );
  });

  it("une copie recopie l'adresse et le site de la recette copiée", async () => {
    await assertSucceeds(
      db("editor").doc("recipes/new").set({
        title: "x",
        created_by: EDITOR,
        review_status: "draft",
        source_recipe_id: "web-editor",
        source_url: "https://www.site.fr/quiche",
        source_site: "site.fr",
      }),
    );
  });

  it("une copie ne pose pas un autre nom de site", async () => {
    await assertFails(
      db("editor").doc("recipes/new").set({
        title: "x",
        created_by: EDITOR,
        review_status: "draft",
        source_recipe_id: "web-editor",
        source_url: "https://www.site.fr/quiche",
        source_site: "autre.fr",
      }),
    );
  });

  it("l'adresse ne se vérifie pas contre une recette privée d'un autre", async () => {
    await assertFails(
      db("editor").doc("recipes/new").set({
        title: "x",
        created_by: EDITOR,
        review_status: "draft",
        source_recipe_id: "web-other-private",
        source_url: "https://secret.example/recette",
        source_site: "secret.example",
      }),
    );
  });

  it("le propriétaire ne modifie pas le nom du site", async () => {
    await assertFails(db("reader").doc("recipes/web-reader").update({ source_site: "x.fr" }));
  });

  it("une copie ne change pas l'adresse au passage", async () => {
    await assertFails(
      db("editor").doc("recipes/new").set({
        title: "x",
        created_by: EDITOR,
        review_status: "draft",
        source_recipe_id: "web-editor",
        source_url: "https://www.site.fr/autre",
      }),
    );
  });

  it("le propriétaire ne modifie pas l'adresse", async () => {
    await assertFails(
      db("reader").doc("recipes/web-reader").update({ source_url: "https://autre.fr/x" }),
    );
  });

  it("le propriétaire n'efface pas l'adresse", async () => {
    await assertFails(db("reader").doc("recipes/web-reader").update({ source_url: deleteField() }));
  });

  it("une édition qui réécrit la même adresse passe", async () => {
    await assertSucceeds(
      db("reader")
        .doc("recipes/web-reader")
        .update({ title: "Quiche lorraine", source_url: "https://www.site.fr/quiche" }),
    );
  });

  it("l'administrateur non plus ne pose pas une adresse", async () => {
    await assertFails(
      db("admin").doc("recipes/draft-reader").update({ source_url: "https://a.fr/x" }),
    );
  });
});

describe("recipes — auteur et nutrition de la page d'origine", () => {
  const copyOf = (extra) => ({
    title: "x",
    created_by: EDITOR,
    review_status: "draft",
    source_recipe_id: "web-editor-author",
    source_url: "https://www.site.fr/quiche",
    source_site: "site.fr",
    ...extra,
  });

  it("une copie recopie l'auteur de la recette copiée", async () => {
    await assertSucceeds(db("editor").doc("recipes/new").set(copyOf({ source_author: "Marie Dupont" })));
  });

  it("une copie ne pose pas un autre auteur", async () => {
    await assertFails(db("editor").doc("recipes/new").set(copyOf({ source_author: "Paul" })));
  });

  it("une recette saisie ne pose pas d'auteur", async () => {
    await assertFails(
      db("editor")
        .doc("recipes/new")
        .set({ title: "x", created_by: EDITOR, review_status: "draft", source_author: "Paul" }),
    );
  });

  it("la création ne pose ni nutrition du site ni écart", async () => {
    await assertFails(
      db("editor")
        .doc("recipes/new")
        .set(copyOf({ source_author: "Marie Dupont", source_nutrition: { per_portion: {} } })),
    );
    await assertFails(
      db("editor")
        .doc("recipes/new")
        .set({
          title: "x",
          created_by: EDITOR,
          review_status: "draft",
          source_nutrition_check: { state: "ok" },
        }),
    );
  });

  it("le propriétaire ne modifie ni l'auteur, ni la nutrition du site, ni l'écart", async () => {
    const ref = db("reader").doc("recipes/web-reader");
    await assertFails(ref.update({ source_author: "Paul" }));
    await assertFails(ref.update({ source_author: deleteField() }));
    await assertFails(ref.update({ "source_nutrition.per_portion.kcal": 100 }));
    await assertFails(ref.update({ source_nutrition_check: deleteField() }));
  });

  it("une édition qui réécrit le même auteur passe", async () => {
    await assertSucceeds(
      db("reader")
        .doc("recipes/web-reader")
        .update({ title: "Quiche lorraine", source_author: "Marie Dupont" }),
    );
  });
});

describe("recipes — confidentialité suivant le livre", () => {
  const draftE = (extra) => ({ title: "x", created_by: EDITOR, review_status: "draft", ...extra });

  it("création dans son livre privé avec is_private:false : refusée", async () => {
    await assertFails(
      db("editor")
        .doc("recipes/new")
        .set(draftE({ book_id: "private-editor", is_private: false })),
    );
  });

  it("création dans son livre privé sans is_private : refusée", async () => {
    await assertFails(
      db("editor")
        .doc("recipes/new")
        .set(draftE({ book_id: "private-editor" })),
    );
  });

  it("création dans son livre privé avec is_private:true : acceptée", async () => {
    await assertSucceeds(
      db("editor")
        .doc("recipes/new")
        .set(draftE({ book_id: "private-editor", is_private: true })),
    );
  });

  it("création dans son livre partagé avec is_private:false : acceptée", async () => {
    await assertSucceeds(
      db("editor")
        .doc("recipes/new")
        .set(draftE({ book_id: "public", is_private: false })),
    );
  });

  it("création dans un livre partagé avec is_private:true : refusée", async () => {
    await assertFails(
      db("editor")
        .doc("recipes/new")
        .set(draftE({ book_id: "public", is_private: true })),
    );
  });

  it("une recette de livre privé ne passe pas à is_private:false", async () => {
    await assertFails(
      db("reader").doc("recipes/in-reader-private-book").update({ is_private: false }),
    );
  });

  it("déplacée dans un livre privé sans changer is_private : refusé", async () => {
    await assertFails(
      db("reader")
        .doc("recipes/draft-reader")
        .update({ book_id: "private-reader", is_private: false }),
    );
  });

  it("déplacée dans un livre privé avec is_private:true : accepté", async () => {
    await assertSucceeds(
      db("reader")
        .doc("recipes/draft-reader")
        .update({ book_id: "private-reader", is_private: true }),
    );
  });

  it("une écriture qui ne touche ni livre ni confidentialité n'est pas contrôlée", async () => {
    await assertSucceeds(db("reader").doc("recipes/in-reader-private-book").update({ title: "y" }));
  });

  it("book_id contenant « / » : refusé", async () => {
    await assertFails(
      db("editor")
        .doc("recipes/new")
        .set(draftE({ book_id: "private-editor/x", is_private: false })),
    );
  });

  // Le livre doit exister (option A, v0.23.8).
  it("création avec un book_id inexistant : refusée", async () => {
    await assertFails(
      db("editor")
        .doc("recipes/new")
        .set(draftE({ book_id: "aucun-livre", is_private: false })),
    );
  });

  it("création sans livre avec is_private:true : acceptée", async () => {
    await assertSucceeds(
      db("editor")
        .doc("recipes/new")
        .set(draftE({ is_private: true })),
    );
  });

  it("recette sans livre passée à is_private:true : acceptée", async () => {
    await assertSucceeds(db("reader").doc("recipes/draft-reader").update({ is_private: true }));
  });

  // Une page détachée d'un livre privé reste privée (v0.23.8).
  it("détacher d'un livre privé en gardant is_private:true : accepté", async () => {
    await assertSucceeds(
      db("reader")
        .doc("recipes/in-reader-private-book")
        .update({ book_id: null, book_titre: null, is_private: true }),
    );
  });

  it("détacher du livre (book_id null) : accepté", async () => {
    await assertSucceeds(
      db("reader").doc("recipes/in-reader-private-book").update({ book_id: null }),
    );
  });
});

// Décision de l'utilisateur (option A) : on ne range une recette que dans ses
// propres livres ; l'administrateur partout. Une page déjà rangée chez un
// autre y reste.
describe("recipes — ranger dans ses propres livres", () => {
  const draftE = (extra) => ({ title: "x", created_by: EDITOR, review_status: "draft", ...extra });

  it("book_id qui n'est ni nul ni une chaîne : refusé", async () => {
    await assertFails(
      db("editor")
        .doc("recipes/new")
        .set(draftE({ book_id: 42 })),
    );
  });

  it("un éditeur ne crée pas de recette dans le livre d'un autre", async () => {
    await assertFails(
      db("editor")
        .doc("recipes/new")
        .set(draftE({ book_id: "public-other", is_private: false })),
    );
  });

  it("un lecteur ne déplace pas sa recette vers le livre d'un autre", async () => {
    await assertFails(
      db("reader")
        .doc("recipes/draft-reader")
        .update({ book_id: "public-other", is_private: false }),
    );
  });

  it("un éditeur ne range pas sa recette dans le livre d'un autre", async () => {
    await assertFails(
      db("editor").doc("recipes/editor-own").update({ book_id: "public-other", is_private: false }),
    );
  });

  it("un administrateur crée une recette dans le livre d'un autre", async () => {
    await assertSucceeds(
      db("admin").doc("recipes/new").set({
        title: "x",
        created_by: PERSONAS.admin.uid,
        review_status: "draft",
        book_id: "public-other",
        is_private: false,
      }),
    );
  });

  it("un administrateur déplace une recette vers le livre d'un autre", async () => {
    await assertSucceeds(
      db("admin").doc("recipes/validated").update({ book_id: "public-other", is_private: false }),
    );
  });

  it("une page déjà rangée chez un autre se modifie sans changer de livre", async () => {
    await assertSucceeds(db("reader").doc("recipes/reader-in-other-book").update({ title: "y" }));
  });

  it("une page déjà rangée chez un autre se détache", async () => {
    await assertSucceeds(
      db("reader").doc("recipes/reader-in-other-book").update({ book_id: null }),
    );
  });
});

describe("recipes — texte d'origine d'une traduction", () => {
  it("un lecteur lit le texte d'origine d'une recette visible", async () => {
    await assertSucceeds(db("reader").doc("recipes/validated/origine/texte").get());
  });

  it("un lecteur ne lit pas le texte d'origine d'une recette privée d'autrui", async () => {
    await assertFails(db("reader").doc("recipes/validated-private-other/origine/texte").get());
  });

  it("un compte en attente ne lit pas le texte d'origine", async () => {
    await assertFails(db("pending").doc("recipes/validated/origine/texte").get());
  });

  it("un administrateur ne réécrit pas le texte d'origine", async () => {
    await assertFails(
      db("admin").doc("recipes/validated/origine/texte").set({ langue: "en", titre: "x" }),
    );
  });

  it("un éditeur ne crée pas de texte d'origine", async () => {
    await assertFails(
      db("editor").doc("recipes/validated/origine/texte").set({ langue: "en", titre: "x" }),
    );
  });
});

describe("recipes — annotations", () => {
  it("un lecteur annote à son nom", async () => {
    await assertSucceeds(
      db("reader").doc("recipes/validated/annotations/new").set({ uid: READER, text: "ok" }),
    );
  });

  it("un lecteur n'annote pas au nom d'un autre", async () => {
    await assertFails(
      db("reader").doc("recipes/validated/annotations/new").set({ uid: OTHER, text: "ok" }),
    );
  });

  it("un compte en attente ne lit aucune annotation", async () => {
    await assertFails(db("pending").doc("recipes/validated/annotations/mine").get());
  });

  it("un lecteur ne lit pas l'annotation d'une recette privée d'autrui", async () => {
    await assertFails(db("reader").doc("recipes/validated-private-other/annotations/a1").get());
  });

  it("un lecteur ne transfère pas son annotation (uid figé)", async () => {
    await assertFails(
      db("reader").doc("recipes/validated/annotations/mine").update({ uid: OTHER }),
    );
  });

  it("un lecteur lit l'annotation d'un autre sur une recette visible", async () => {
    await assertSucceeds(db("reader").doc("recipes/validated/annotations/other").get());
  });

  it("un lecteur n'annote pas la recette privée d'autrui", async () => {
    await assertFails(
      db("reader")
        .doc("recipes/validated-private-other/annotations/new")
        .set({ uid: READER, text: "ok" }),
    );
  });

  it("un lecteur annote sa propre recette privée", async () => {
    await assertSucceeds(
      db("reader")
        .doc("recipes/validated-private-reader/annotations/new")
        .set({ uid: READER, text: "ok" }),
    );
  });

  it("un lecteur modifie le texte de son annotation", async () => {
    await assertSucceeds(
      db("reader").doc("recipes/validated/annotations/mine").update({ text: "corrigé" }),
    );
  });

  it("un lecteur ne modifie pas l'annotation d'un autre", async () => {
    await assertFails(
      db("reader").doc("recipes/validated/annotations/other").update({ text: "x" }),
    );
  });

  it("un administrateur supprime l'annotation d'un autre", async () => {
    await assertSucceeds(db("admin").doc("recipes/validated/annotations/other").delete());
  });

  it("un administrateur lit l'annotation d'une recette privée d'autrui", async () => {
    await assertSucceeds(db("admin").doc("recipes/validated-private-other/annotations/a1").get());
  });
});

describe("recipe_ratings — confidentialité", () => {
  it("un lecteur lit la note d'un autre sur une recette visible", async () => {
    await assertSucceeds(db("reader").doc("recipe_ratings/r-other").get());
  });

  it("un lecteur ne lit pas la note d'un autre sur une recette privée", async () => {
    await assertFails(db("reader").doc("recipe_ratings/r-other-private").get());
  });

  // La fiche d'une recette liste les notes de la famille par une requête sur
  // `recipe_id` : la règle doit pouvoir la prouver sans lire chaque note.
  it("un lecteur liste les notes d'une recette visible", async () => {
    await assertSucceeds(
      db("reader").collection("recipe_ratings").where("recipe_id", "==", "validated").get(),
    );
  });

  it("un lecteur ne liste pas les notes d'une recette privée d'autrui", async () => {
    await assertFails(
      db("reader")
        .collection("recipe_ratings")
        .where("recipe_id", "==", "validated-private-other")
        .get(),
    );
  });

  it("note : une valeur non entière est refusée", async () => {
    await assertFails(
      db("reader")
        .doc(`recipe_ratings/${READER}_validated`)
        .set({ user_id: READER, recipe_id: "validated", rating: "x", updated_at: new Date() }),
    );
  });

  it("note : une valeur au-delà de 10 est refusée", async () => {
    await assertFails(
      db("reader")
        .doc(`recipe_ratings/${READER}_validated`)
        .set({ user_id: READER, recipe_id: "validated", rating: 11, updated_at: new Date() }),
    );
  });

  it("note : une mise à jour sous 0 est refusée", async () => {
    await assertFails(
      db("reader").doc("recipe_ratings/r1").update({ rating: -1, updated_at: new Date() }),
    );
  });

  it("note : une note sans date est refusée", async () => {
    await assertFails(
      db("reader")
        .doc(`recipe_ratings/${READER}_validated`)
        .set({ user_id: READER, recipe_id: "validated", rating: 2 }),
    );
  });

  it("note : un champ inconnu est refusé", async () => {
    await assertFails(
      db("reader")
        .doc(`recipe_ratings/${READER}_validated`)
        .set({
        user_id: READER,
        recipe_id: "validated",
        rating: 2,
        updated_at: new Date(),
        extra: true,
      }),
    );
  });

  it("note : un identifiant autre que {uid}_{recipeId} est refusé", async () => {
    await assertFails(
      db("reader")
        .doc("recipe_ratings/autre-id")
        .set({ user_id: READER, recipe_id: "validated", rating: 10, updated_at: new Date() }),
    );
  });

  it("note : une ancienne note sans date se remplace par une note complète", async () => {
    await seedDocs(env, {
      [`recipe_ratings/${READER}_validated`]: { user_id: READER, recipe_id: "validated", rating: 4 },
    });
    await assertSucceeds(
      db("reader")
        .doc(`recipe_ratings/${READER}_validated`)
        .set({ user_id: READER, recipe_id: "validated", rating: 6, updated_at: new Date() }),
    );
  });

  it("note : une ancienne note sans date se supprime", async () => {
    await seedDocs(env, {
      [`recipe_ratings/${READER}_validated`]: { user_id: READER, recipe_id: "validated", rating: 4 },
    });
    await assertSucceeds(db("reader").doc(`recipe_ratings/${READER}_validated`).delete());
  });

  it("un compte révoqué ne modifie ni ne supprime sa note", async () => {
    await seedDocs(env, {
      "recipe_ratings/r-revoked": {
        user_id: PERSONAS.revokedStaleToken.uid,
        recipe_id: "validated",
        rating: 4,
        updated_at: new Date(),
      },
    });
    await assertFails(
      db("revokedStaleToken")
        .doc("recipe_ratings/r-revoked")
        .update({ rating: 5, updated_at: new Date() }),
    );
    await assertFails(db("revokedStaleToken").doc("recipe_ratings/r-revoked").delete());
  });

  it("un lecteur ne note pas la recette privée d'autrui", async () => {
    await assertFails(
      db("reader")
        .doc(`recipe_ratings/${READER}_validated-private-other`)
        .set({
          user_id: READER,
          recipe_id: "validated-private-other",
          rating: 2,
          updated_at: new Date(),
        }),
    );
  });

  it("un lecteur note une recette visible", async () => {
    await assertSucceeds(
      db("reader")
        .doc(`recipe_ratings/${READER}_validated`)
        .set({ user_id: READER, recipe_id: "validated", rating: 2, updated_at: new Date() }),
    );
  });

  it("un lecteur met à jour sa note", async () => {
    await assertSucceeds(db("reader").doc("recipe_ratings/r1").update({ rating: 5 }));
  });

  it("note : recipe_id figé en mise à jour", async () => {
    await assertFails(
      db("reader").doc("recipe_ratings/r1").update({ recipe_id: "validated-private-reader" }),
    );
  });
});

// ── champs propriétaire ──────────────────────────────────────────────────

describe("champs propriétaire", () => {
  it("un lecteur ne note pas au nom d'un autre", async () => {
    await assertFails(
      db("reader")
        .doc(`recipe_ratings/${OTHER}_validated`)
        .set({ user_id: OTHER, recipe_id: "validated", rating: 2, updated_at: new Date() }),
    );
  });

  it("un groupe se crée à son nom, soi seul membre", async () => {
    await assertSucceeds(
      db("reader")
        .doc("groups/new")
        .set({ name: "Famille", owner_id: READER, member_ids: [READER] }),
    );
  });

  it("un groupe ne se crée pas au nom d'un autre", async () => {
    await assertFails(
      db("reader")
        .doc("groups/new")
        .set({ name: "Famille", owner_id: OTHER, member_ids: [OTHER] }),
    );
  });

  it("un repas planifié ne se crée pas au nom d'un autre", async () => {
    await assertFails(db("editor").doc("planned_meals/new").set({ uid: OTHER }));
  });

  it("un lecteur ne lit pas le repas d'un autre", async () => {
    await assertFails(db("otherReader").doc("planned_meals/m1").get());
  });

  it("note : user_id figé en mise à jour", async () => {
    await assertFails(db("reader").doc("recipe_ratings/r1").update({ user_id: OTHER }));
  });

  it("groupe : owner_id figé en mise à jour", async () => {
    await assertFails(db("reader").doc("groups/g1").update({ owner_id: OTHER }));
  });

  // Depuis les invitations, le propriétaire n'ajoute plus personne : il
  // invite, et l'invité accepte (voir « groupes — invitations »).
  it("groupe : son propriétaire n'ajoute pas un membre directement", async () => {
    await assertFails(
      db("reader")
        .doc("groups/g1")
        .update({ member_ids: [READER, OTHER] }),
    );
  });

  it("groupe : un administrateur ne change pas non plus owner_id", async () => {
    await assertFails(db("admin").doc("groups/g1").update({ owner_id: OTHER }));
  });

  it("repas planifié : son titulaire éditeur le modifie", async () => {
    await assertSucceeds(
      db("editor").doc("planned_meals/m-editor").update({ date: "2026-10-13" }),
    );
  });

  it("repas planifié : uid figé en mise à jour", async () => {
    await assertFails(db("editor").doc("planned_meals/m-editor").update({ uid: OTHER }));
  });
});

// ── comptes en attente et révoqués sur les données personnelles ──────────

/// Un rapport d'erreur tel que l'écrit `ErrorReport.toFirestore`.
function errorReport(uid) {
  return {
    user_id: uid,
    job_id: null,
    timestamp: new Date("2026-10-12T00:00:00Z"),
    app_version: "0.23.48+395",
    feature: "recipe_save",
    error_type: "FirebaseException",
    error_message: "permission-denied",
    stack_trace: "#0 main (package:kass_dalle/main.dart:1)",
    context: JSON.stringify({ recipeId: "r1" }),
  };
}

describe("données personnelles — pending et révoqué", () => {
  it("un anonyme n'écrit pas de rapport d'erreur", async () => {
    await assertFails(db("anonymous").doc("error_reports/new").set({ user_id: "x" }));
  });

  it("un lecteur écrit son rapport d'erreur", async () => {
    await assertSucceeds(db("reader").doc("error_reports/new").set(errorReport(READER)));
  });

  // Audit sécurité : champs et tailles libres, ouverts même à un compte en attente.
  it("un rapport d'erreur au champ de 500 Ko est refusé", async () => {
    const huge = "x".repeat(500 * 1024);
    for (const field of ["error_message", "stack_trace", "context", "feature"]) {
      await assertFails(
        db("pending")
          .doc("error_reports/new")
          .set({ ...errorReport(PERSONAS.pending.uid), [field]: huge }),
      );
    }
  });

  it("un rapport d'erreur au champ inconnu est refusé", async () => {
    await assertFails(
      db("reader")
        .doc("error_reports/new")
        .set({ ...errorReport(READER), payload: "n'importe quoi" }),
    );
  });

  it("un rapport d'erreur au contexte en carte (sans borne mesurable) est refusé", async () => {
    await assertFails(
      db("reader")
        .doc("error_reports/new")
        .set({ ...errorReport(READER), context: { a: "b" } }),
    );
  });

  it("un rapport d'erreur au nom d'un autre compte est refusé", async () => {
    await assertFails(db("reader").doc("error_reports/new").set(errorReport(OTHER)));
  });

  it("un rapport aux longueurs maximales du client passe", async () => {
    await assertSucceeds(
      db("reader")
        .doc("error_reports/new")
        .set({
          ...errorReport(READER),
          error_message: "m".repeat(4000),
          stack_trace: "s".repeat(2000),
          context: JSON.stringify({ k: "v".repeat(3900) }),
        }),
    );
  });

  it("un éditeur planifie un repas et écrit planning_config", async () => {
    await assertSucceeds(db("editor").doc("planned_meals/new").set({ uid: EDITOR }));
    await assertSucceeds(db("editor").doc(`planning_config/${EDITOR}`).set({ days: 7 }));
  });

  it("un compte en attente écrit son rapport d'erreur", async () => {
    await assertSucceeds(
      db("pending").doc("error_reports/new").set(errorReport(PERSONAS.pending.uid)),
    );
  });

  it("un compte neuf, sans document, écrit son rapport d'erreur", async () => {
    await assertSucceeds(
      env
        .authenticatedContext("newcomer", { email: "new@example.com" })
        .firestore()
        .doc("error_reports/new")
        .set(errorReport("newcomer")),
    );
  });

  it("un compte révoqué à l'instant n'écrit pas de rapport d'erreur", async () => {
    await assertFails(
      db("revokedStaleToken")
        .doc("error_reports/new")
        .set(errorReport(PERSONAS.revokedStaleToken.uid)),
    );
  });

  it("un compte révoqué ne modifie pas son repas planifié", async () => {
    await seedDocs(env, {
      "planned_meals/m-revoked": { uid: PERSONAS.revoked.uid, date: "2026-10-09" },
    });
    await assertFails(
      db("revoked").doc("planned_meals/m-revoked").update({ date: "2026-10-10" }),
    );
  });

  it("un compte en attente relit sa configuration de planning", async () => {
    await seedDocs(env, { [`planning_config/${PERSONAS.pending.uid}`]: { days: 7 } });
    await assertSucceeds(db("pending").doc(`planning_config/${PERSONAS.pending.uid}`).get());
  });

  it("un compte en attente ne planifie pas de repas", async () => {
    await assertFails(db("pending").doc("planned_meals/new").set({ uid: PERSONAS.pending.uid }));
  });

  it("un compte révoqué ne planifie pas de repas", async () => {
    await assertFails(db("revoked").doc("planned_meals/new").set({ uid: PERSONAS.revoked.uid }));
  });

  it("un compte en attente n'écrit pas planning_config", async () => {
    await assertFails(
      db("pending").doc(`planning_config/${PERSONAS.pending.uid}`).set({ days: 7 }),
    );
  });

  it("un compte révoqué n'écrit pas planning_config", async () => {
    await assertFails(
      db("revoked").doc(`planning_config/${PERSONAS.revoked.uid}`).set({ days: 7 }),
    );
  });

  it("un compte révoqué n'écrit pas de rapport d'erreur", async () => {
    await assertFails(
      db("revoked").doc("error_reports/new").set(errorReport(PERSONAS.revoked.uid)),
    );
  });
});

// ── plannings partagés ───────────────────────────────────────────────────
//
// Depuis la v0.23.47, le lecteur ne planifie plus : il lit les plannings que
// des éditeurs de ses groupes partagent avec lui. `planning_reach/{uid}` porte
// la liste des propriétaires lisibles, écrite par le serveur seul.

describe("plannings partagés — le lecteur ne planifie plus", () => {
  it("un lecteur ne crée pas de repas", async () => {
    await assertFails(db("reader").doc("planned_meals/new").set({ uid: READER }));
  });

  it("un lecteur ne modifie pas son ancien repas", async () => {
    await assertFails(db("reader").doc("planned_meals/m1").update({ date: "2026-10-10" }));
  });

  it("un lecteur relit et supprime son ancien repas", async () => {
    await assertSucceeds(db("reader").doc("planned_meals/m1").get());
    await assertSucceeds(db("reader").doc("planned_meals/m1").delete());
  });

  it("un lecteur n'écrit pas planning_config", async () => {
    await assertFails(db("reader").doc(`planning_config/${READER}`).set({ days: 7 }));
    await assertFails(
      db("reader")
        .doc(`planning_config/${READER}`)
        .set({ shared_group_ids: ["famille"] }),
    );
  });
});

describe("plannings partagés — lecture", () => {
  beforeEach(async () => {
    await seedDocs(env, {
      "planning_reach/reader": { uids: [EDITOR] },
      "planning_reach/revoked-stale": { uids: [EDITOR] },
      "planning_reach/pending": { uids: [EDITOR] },
      "planned_meals/m-stranger": { uid: PERSONAS.stranger.uid, date: "2026-10-12" },
    });
  });

  it("un lecteur lit un repas d'un planning partagé avec lui", async () => {
    await assertSucceeds(db("reader").doc("planned_meals/m-editor").get());
  });

  it("un lecteur ne lit pas un repas d'un planning non partagé", async () => {
    await assertFails(db("reader").doc("planned_meals/m-stranger").get());
  });

  it("un lecteur ne modifie ni ne supprime un repas partagé", async () => {
    await assertFails(
      db("reader").doc("planned_meals/m-editor").update({ date: "2026-10-13" }),
    );
    await assertFails(db("reader").doc("planned_meals/m-editor").delete());
  });

  it("sans planning_reach (invité, non membre) : rien", async () => {
    await assertFails(db("otherReader").doc("planned_meals/m-editor").get());
  });

  it("révoqué ou en attente, même avec planning_reach : rien", async () => {
    await assertFails(db("revokedStaleToken").doc("planned_meals/m-editor").get());
    await assertFails(db("pending").doc("planned_meals/m-editor").get());
  });

  it("requête uid == propriétaire partagé : acceptée", async () => {
    await assertSucceeds(
      db("reader").collection("planned_meals").where("uid", "==", EDITOR).get(),
    );
  });

  it("requête uid == propriétaire non partagé : refusée", async () => {
    await assertFails(
      db("reader")
        .collection("planned_meals")
        .where("uid", "==", PERSONAS.stranger.uid)
        .get(),
    );
  });

  it("requête sans filtre sur le propriétaire : refusée", async () => {
    await assertFails(db("reader").collection("planned_meals").get());
  });
});

describe("plannings partagés — planning_reach et shared_group_ids", () => {
  it("planning_reach : lu par son titulaire et un administrateur", async () => {
    await seedDocs(env, { "planning_reach/reader": { uids: [EDITOR] } });
    await assertSucceeds(db("reader").doc("planning_reach/reader").get());
    await assertSucceeds(db("admin").doc("planning_reach/reader").get());
    await assertFails(db("otherReader").doc("planning_reach/reader").get());
  });

  it("planning_reach : aucune écriture du client, administrateur compris", async () => {
    await assertFails(db("reader").doc("planning_reach/reader").set({ uids: [EDITOR] }));
    await assertFails(db("stranger").doc("planning_reach/stranger").set({ uids: [READER] }));
    await assertFails(db("admin").doc("planning_reach/reader").set({ uids: [EDITOR] }));
  });

  it("un éditeur coche les groupes qui voient son planning", async () => {
    await assertSucceeds(
      db("editor")
        .doc(`planning_config/${EDITOR}`)
        .set({ shared_group_ids: ["famille"] }),
    );
  });

  it("shared_group_ids : liste de 50 groupes au plus", async () => {
    const many = Array.from({ length: 51 }, (_, i) => `g${i}`);
    await assertFails(
      db("editor").doc(`planning_config/${EDITOR}`).set({ shared_group_ids: many }),
    );
    await assertFails(
      db("editor").doc(`planning_config/${EDITOR}`).set({ shared_group_ids: "famille" }),
    );
  });

  it("un éditeur n'écrit pas les préférences d'un autre", async () => {
    await assertFails(
      db("editor")
        .doc(`planning_config/${READER}`)
        .set({ shared_group_ids: ["famille"] }),
    );
  });
});

// ── app_config ───────────────────────────────────────────────────────────

describe("app_config", () => {
  it("un lecteur lit usage et ai_pricing", async () => {
    await assertSucceeds(db("reader").doc("app_config/usage").get());
    await assertSucceeds(db("reader").doc("app_config/ai_pricing").get());
  });

  it("un lecteur ne lit pas la politique nutrition", async () => {
    await assertFails(db("reader").doc("app_config/nutrition_policy").get());
  });

  it("un compte en attente ne lit pas ai_pricing", async () => {
    await assertFails(db("pending").doc("app_config/ai_pricing").get());
  });

  it("un lecteur n'écrit pas la grille tarifaire", async () => {
    await assertFails(db("reader").doc("app_config/ai_pricing").set({ models: {} }));
  });

  it("un éditeur n'écrit pas la politique nutrition", async () => {
    await assertFails(db("editor").doc("app_config/nutrition_policy").set({ mode: "open" }));
  });

  it("un lecteur met à jour les compteurs de usage", async () => {
    await assertSucceeds(
      db("reader")
        .doc("app_config/usage")
        .update({ storage_bytes: 20, updated_at: 2, [currentScansKey()]: 3 }),
    );
  });

  it("un lecteur n'ajoute pas d'autre champ à usage", async () => {
    await assertFails(db("reader").doc("app_config/usage").update({ plafond: 1e9 }));
  });

  it("un administrateur écrit la configuration", async () => {
    await assertSucceeds(db("admin").doc("app_config/nutrition_policy").set({ mode: "open" }));
  });

  // Programmation et état des backfills : écrits par le serveur seul
  // (setBackfillScheduleFn, setBackfillDoneFn, runBackfillPass).
  it("un administrateur n'écrit pas la programmation des backfills", async () => {
    await assertFails(
      db("admin")
        .doc("app_config/backfill_schedules")
        .set({ recipe_roles: { enabled: true, days: [7], hour: 3, programme_par_uid: OTHER } }),
    );
  });

  it("un administrateur n'écrit pas l'état d'un backfill", async () => {
    await assertFails(
      db("admin").doc("app_config/backfill_run_nutrition").update({ dernier_passage_statut: null }),
    );
    await assertFails(
      db("admin").doc("app_config/backfill_run_estimated_times").set({ termine_par: "manuel" }),
    );
  });

  it("un administrateur lit la programmation et l'état des backfills", async () => {
    await assertSucceeds(db("admin").doc("app_config/backfill_schedules").get());
    await assertSucceeds(db("admin").doc("app_config/backfill_run_nutrition").get());
    await assertSucceeds(
      db("admin").collection("app_config").where("doc_type", "==", "backfill_run").get(),
    );
  });

  it("un lecteur ne lit pas l'état des backfills", async () => {
    await assertFails(db("reader").doc("app_config/backfill_run_nutrition").get());
    await assertFails(db("reader").doc("app_config/backfill_schedules").get());
  });

  it("usage : storage_bytes reste un entier positif", async () => {
    await assertFails(db("reader").doc("app_config/usage").update({ storage_bytes: -1 }));
  });

  it("usage : le compteur de scans du mois reste positif", async () => {
    await assertFails(
      db("reader")
        .doc("app_config/usage")
        .update({ [currentScansKey()]: -1 }),
    );
  });

  it("usage : storage_bytes ne recule pas", async () => {
    await assertFails(db("reader").doc("app_config/usage").update({ storage_bytes: 0 }));
  });

  it("usage : storage_bytes reste un entier", async () => {
    await assertFails(db("reader").doc("app_config/usage").update({ storage_bytes: "20" }));
    await assertFails(db("reader").doc("app_config/usage").update({ storage_bytes: 20.5 }));
  });

  it("usage : un incrément du client passe", async () => {
    await assertSucceeds(
      db("reader")
        .doc("app_config/usage")
        .set(
          {
            [currentScansKey()]: increment(1),
            storage_bytes: increment(2048),
            updated_at: serverTimestamp(),
          },
          { merge: true },
        ),
    );
  });

  it("usage : un administrateur remet un compteur à zéro", async () => {
    await assertSucceeds(db("admin").doc("app_config/usage").update({ storage_bytes: 0 }));
  });
});

// ── collections de coût et écritures serveur ─────────────────────────────

describe("collections de coût — écriture serveur seule", () => {
  const serverOnly = [
    "ai_usage/new",
    "ai_daily_spend/new",
    "scan_spend/new",
    "ai_reconciliation_monthly/2026-10",
    "dead_letters/new",
    "image_moderation/new",
    "ai_routing_presets/new",
  ];

  for (const path of serverOnly) {
    it(`${path.split("/")[0]} : même un administrateur n'écrit pas`, async () => {
      await assertFails(db("admin").doc(path).set({ uid: PERSONAS.admin.uid, cost_usd: 0 }));
    });

    it(`${path.split("/")[0]} : un lecteur n'écrit pas à son nom`, async () => {
      await assertFails(db("reader").doc(path).set({ uid: READER, cost_usd: 0 }));
    });
  }

  it("un lecteur lit sa propre ligne ai_usage", async () => {
    await assertSucceeds(db("reader").doc("ai_usage/u1").get());
  });

  it("un lecteur ne lit pas la ligne ai_usage d'un autre", async () => {
    await assertFails(db("reader").doc("ai_usage/u2").get());
  });

  it("un lecteur ne remet pas son compteur journalier à zéro", async () => {
    await assertFails(db("reader").doc("ai_daily_spend/d1").update({ total: 0 }));
  });

  it("un administrateur lit la ligne ai_usage d'un autre", async () => {
    await assertSucceeds(db("admin").doc("ai_usage/u2").get());
  });
});

// ── url_import_daily ─────────────────────────────────────────────────────

describe("url_import_daily", () => {
  it("le titulaire lit son compteur", async () => {
    await assertSucceeds(db("editor").doc("url_import_daily/editor_2026-10-11").get());
  });

  it("un autre compte ne le lit pas", async () => {
    await assertFails(db("reader").doc("url_import_daily/editor_2026-10-11").get());
  });

  it("le titulaire ne remet pas son compteur à zéro", async () => {
    await assertFails(
      db("editor").doc("url_import_daily/editor_2026-10-11").update({ count: 0 }),
    );
  });

  it("personne ne crée de compteur depuis le client", async () => {
    await assertFails(
      db("admin").doc("url_import_daily/admin_2026-10-11").set({ uid: "admin", count: 0 }),
    );
  });
});

// ── web_search_daily ─────────────────────────────────────────────────────

describe("web_search_daily", () => {
  it("le titulaire lit son compteur", async () => {
    await assertSucceeds(db("reader").doc("web_search_daily/reader_2026-10-12").get());
  });

  it("un autre compte ne le lit pas", async () => {
    await assertFails(db("editor").doc("web_search_daily/reader_2026-10-12").get());
  });

  it("le titulaire ne remet pas son compteur à zéro", async () => {
    await assertFails(
      db("reader").doc("web_search_daily/reader_2026-10-12").update({ count: 0 }),
    );
  });

  it("personne ne crée de compteur depuis le client", async () => {
    await assertFails(
      db("admin").doc("web_search_daily/admin_2026-10-12").set({ uid: "admin", count: 0 }),
    );
  });
});

// ── web_search_cache ─────────────────────────────────────────────────────

describe("web_search_cache", () => {
  it("aucun rôle ne lit le cache", async () => {
    await assertFails(db("reader").doc("web_search_cache/abc").get());
    await assertFails(db("admin").doc("web_search_cache/abc").get());
  });

  it("aucun rôle n'y écrit", async () => {
    await assertFails(db("editor").doc("web_search_cache/abc").set({ results: [] }));
    await assertFails(db("admin").doc("web_search_cache/new").set({ results: [] }));
  });
});

// ── invitations ──────────────────────────────────────────────────────────

describe("invitations — lecture administrateur, écriture serveur seule", () => {
  const INVITATION = {
    email: "marie@example.com",
    email_key: "marie@example.com",
    role: "reader",
    group_id: "g1",
    status: "sent",
  };

  beforeEach(async () => {
    await seedDocs(env, {
      "invitations/inv1": INVITATION,
      "invitation_sends_daily/admin_2026-10-12": { uid: "admin", count: 1 },
    });
  });

  it("un administrateur lit une invitation et la liste", async () => {
    await assertSucceeds(db("admin").doc("invitations/inv1").get());
    await assertSucceeds(db("admin").collection("invitations").orderBy("created_at", "desc").get());
  });

  for (const persona of ["editor", "reader", "pending", "revoked", "anonymous"]) {
    it(`${persona} ne lit pas les invitations`, async () => {
      await assertFails(db(persona).doc("invitations/inv1").get());
      await assertFails(db(persona).collection("invitations").get());
    });
  }

  it("aucun rôle n'écrit une invitation depuis le client", async () => {
    await assertFails(db("admin").doc("invitations/new").set(INVITATION));
    await assertFails(db("admin").doc("invitations/inv1").update({ status: "accepted" }));
    await assertFails(db("admin").doc("invitations/inv1").delete());
    await assertFails(db("pending").doc("invitations/self").set(INVITATION));
    await assertFails(db("editor").doc("invitations/inv1").update({ role: "editor" }));
  });

  it("le compteur d'envois : lu par l'administrateur, écrit par personne", async () => {
    await assertSucceeds(db("admin").doc("invitation_sends_daily/admin_2026-10-12").get());
    await assertFails(db("editor").doc("invitation_sends_daily/admin_2026-10-12").get());
    await assertFails(
      db("admin").doc("invitation_sends_daily/admin_2026-10-12").update({ count: 0 }),
    );
  });
});

// ── member_email_search_daily ────────────────────────────────────────────

describe("member_email_search_daily — compteur serveur seul", () => {
  const DOC = "member_email_search_daily/reader_2026-10-12";

  beforeEach(async () => {
    await seedDocs(env, { [DOC]: { uid: READER, day: "2026-10-12", count: 3 } });
  });

  for (const persona of ["admin", "editor", "reader", "pending", "revoked", "anonymous"]) {
    it(`${persona} ne lit ni n'écrit le compteur`, async () => {
      await assertFails(db(persona).doc(DOC).get());
      await assertFails(db(persona).collection("member_email_search_daily").get());
      await assertFails(db(persona).doc(DOC).update({ count: 0 }));
      await assertFails(db(persona).doc(DOC).delete());
      await assertFails(
        db(persona).doc("member_email_search_daily/new").set({ uid: READER, count: 0 }),
      );
    });
  }
});

// ── processing_jobs ──────────────────────────────────────────────────────

describe("processing_jobs", () => {
  it("un lecteur ne crée pas de job d'import", async () => {
    await assertFails(
      db("reader").doc("processing_jobs/new").set({ created_by: READER, status: "queued" }),
    );
  });

  it("un éditeur crée un job à son nom", async () => {
    await assertSucceeds(
      db("editor").doc("processing_jobs/new").set({ created_by: EDITOR, status: "queued" }),
    );
  });

  it("un éditeur ne crée pas de job au nom d'un autre", async () => {
    await assertFails(
      db("editor").doc("processing_jobs/new").set({ created_by: READER, status: "queued" }),
    );
  });

  it("un éditeur ne crée pas lui-même un import par lien", async () => {
    await assertFails(
      db("editor").doc("processing_jobs/new").set({
        created_by: EDITOR,
        status: "queued",
        type: "recipeUrlImport",
        source_url: "http://169.254.169.254/",
      }),
    );
  });

  it("un éditeur ne relance pas un job en changeant sa source", async () => {
    await assertFails(
      db("editor")
        .doc("processing_jobs/job-editor")
        .update({ status: "queued", source_url: "http://10.0.0.1/" }),
    );
  });

  it("un import par lien terminé ne se remet pas en file", async () => {
    await assertFails(db("editor").doc("processing_jobs/url-done").update({ status: "queued" }));
    await assertFails(
      db("editor")
        .doc("processing_jobs/url-done")
        .update({ status: "queued", url_retry_count: 1 }),
    );
  });

  it("un import par lien terminé ne s'annule pas (annuler le rendrait relançable)", async () => {
    await assertFails(
      db("editor")
        .doc("processing_jobs/url-done")
        .update({ status: "error", cancel_requested: true }),
    );
  });

  it("un import par lien en délai dépassé se relance en comptant la relance", async () => {
    await assertSucceeds(
      db("editor")
        .doc("processing_jobs/url-timeout")
        .update({ status: "queued", error_message: null, url_retry_count: 1 }),
    );
  });

  it("une relance d'import par lien sans compteur est refusée", async () => {
    await assertFails(db("editor").doc("processing_jobs/url-timeout").update({ status: "queued" }));
  });

  it("au-delà de deux relances, l'import par lien ne se relance plus", async () => {
    await assertFails(
      db("editor")
        .doc("processing_jobs/url-timeout-2")
        .update({ status: "queued", url_retry_count: 3 }),
    );
  });

  it("une annulation ne remet pas le compteur de relances à zéro", async () => {
    await assertFails(
      db("editor")
        .doc("processing_jobs/url-processing")
        .update({ status: "error", cancel_requested: true, url_retry_count: 0 }),
    );
    await assertSucceeds(
      db("editor")
        .doc("processing_jobs/url-processing")
        .update({ status: "error", cancel_requested: true }),
    );
  });

  it("un import refusé par le site ne se relance pas", async () => {
    await assertFails(
      db("editor")
        .doc("processing_jobs/url-blocked")
        .update({ status: "queued", url_retry_count: 1 }),
    );
  });

  it("un éditeur révoqué ne crée pas de job", async () => {
    await assertFails(
      db("revokedStaleToken")
        .doc("processing_jobs/new")
        .set({ created_by: PERSONAS.revokedStaleToken.uid, status: "queued" }),
    );
  });

  it("un lecteur propriétaire annule son job sous la forme exacte", async () => {
    await assertSucceeds(
      db("reader")
        .doc("processing_jobs/job-reader")
        .update({ status: "error", cancel_requested: true }),
    );
  });

  it("un lecteur propriétaire ne remet pas son job en file (queued)", async () => {
    await assertFails(db("reader").doc("processing_jobs/job-reader").update({ status: "queued" }));
  });

  it("un lecteur propriétaire ne vide pas le statut (relance déguisée)", async () => {
    await assertFails(db("reader").doc("processing_jobs/job-reader").update({ status: "" }));
  });

  it("une annulation ne touche pas d'autre champ", async () => {
    await assertFails(
      db("reader").doc("processing_jobs/job-reader").update({
        status: "error",
        cancel_requested: true,
        file_url: "rejected/x.jpg",
      }),
    );
  });

  it("un éditeur propriétaire relance son job", async () => {
    await assertSucceeds(
      db("editor").doc("processing_jobs/job-editor").update({ status: "queued" }),
    );
  });

  it("un lecteur ne touche pas au job d'un autre", async () => {
    await assertFails(
      db("reader")
        .doc("processing_jobs/job-editor")
        .update({ status: "error", cancel_requested: true }),
    );
  });

  it("un lecteur lit son job, pas celui d'un autre", async () => {
    await assertSucceeds(db("reader").doc("processing_jobs/job-reader").get());
    await assertFails(db("reader").doc("processing_jobs/job-editor").get());
  });

  it("un éditeur ne lit pas le job d'un autre", async () => {
    await assertFails(db("editor").doc("processing_jobs/job-reader").get());
  });

  it("un éditeur liste ses jobs, comme la file de travail", async () => {
    await assertSucceeds(
      db("editor").collection("processing_jobs").where("created_by", "==", EDITOR).get(),
    );
  });

  it("un éditeur ne liste pas tous les jobs", async () => {
    await assertFails(db("editor").collection("processing_jobs").get());
  });

  it("un administrateur lit tous les jobs", async () => {
    await assertSucceeds(db("admin").collection("processing_jobs").get());
  });

  it("seul un administrateur supprime un job", async () => {
    await assertFails(db("editor").doc("processing_jobs/job-editor").delete());
    await assertSucceeds(db("admin").doc("processing_jobs/job-editor").delete());
  });
});

// ── référentiels ─────────────────────────────────────────────────────────

describe("référentiels", () => {
  it("un lecteur lit les ingrédients, un compte en attente non", async () => {
    await assertSucceeds(db("reader").doc("nutrition_ingredients/farine").get());
    await assertFails(db("pending").doc("nutrition_ingredients/farine").get());
  });

  it("un administrateur corrige le produit acheté d'un ingrédient", async () => {
    await assertSucceeds(
      db("admin")
        .doc("nutrition_ingredients/farine")
        .update({ shopping_product: "farine de blé", updated_at: 1 }),
    );
  });

  it("un administrateur corrige les allergènes d'un ingrédient", async () => {
    await assertSucceeds(
      db("admin").doc("nutrition_ingredients/farine").update({
        allergens: ["gluten"],
        allergens_source: "admin",
        allergens_at: 1,
        updated_at: 1,
      }),
    );
  });

  it("un administrateur n'écrit pas des allergènes qui ne sont pas une liste", async () => {
    await assertFails(
      db("admin")
        .doc("nutrition_ingredients/farine")
        .update({ allergens: "gluten", allergens_source: "admin", allergens_at: 1 }),
    );
  });

  it("une correction de l'administrateur est signée « admin »", async () => {
    await assertFails(
      db("admin")
        .doc("nutrition_ingredients/farine")
        .update({ allergens: ["gluten"], allergens_source: "ai_estimated", allergens_at: 1 }),
    );
  });

  it("un éditeur ne corrige pas les allergènes d'un ingrédient", async () => {
    await assertFails(
      db("editor")
        .doc("nutrition_ingredients/farine")
        .update({ allergens: [], allergens_source: "admin", allergens_at: 1 }),
    );
  });

  it("un administrateur ne réécrit pas les valeurs nutritionnelles", async () => {
    await assertFails(db("admin").doc("nutrition_ingredients/farine").update({ kcal: 0 }));
  });

  it("personne ne crée d'ingrédient côté client", async () => {
    await assertFails(db("admin").doc("nutrition_ingredients/new").set({ name: "x" }));
  });

  for (const col of ["nutrition_units", "meal_staples"]) {
    it(`${col} : un éditeur n'écrit pas, un administrateur oui`, async () => {
      await assertFails(db("editor").doc(`${col}/x`).set({ name: "x" }));
      await assertSucceeds(db("admin").doc(`${col}/x`).set({ name: "x" }));
    });
  }
});

// ── requêtes du client ───────────────────────────────────────────────────
//
// Firestore refuse une requête entière dès que les règles ne peuvent pas
// prouver que CHAQUE résultat possible est lisible : une règle n'est pas un
// filtre. Ces tests rejouent la forme des requêtes du client
// (recipe_repository.dart, book_repository.dart, planning_providers.dart,
// annotation_repository.dart, recipe_rating_repository.dart) : une requête
// qui perd son filtre `is_private` ou `created_by` échoue ici avant de
// vider un écran en production.

describe("requêtes du client", () => {
  const recipes = (who) => db(who).collection("recipes");

  it("livre partagé : pages validées non privées de mes groupes (lecteur)", async () => {
    await assertSucceeds(
      recipes("reader")
        .where("book_id", "==", "public-other")
        .where("review_status", "==", "validated")
        .where("is_private", "==", false)
        .where("created_by", "in", [EDITOR, OTHER])
        .get(),
    );
  });

  // Avant le cloisonnement par groupe, `is_private == false` suffisait.
  it("livre partagé sans filtre sur les comptes de mes groupes : refusé", async () => {
    await assertFails(
      recipes("reader")
        .where("book_id", "==", "public-other")
        .where("review_status", "==", "validated")
        .where("is_private", "==", false)
        .get(),
    );
  });

  it("livre partagé : un compte hors de mes groupes dans le filtre fait tout refuser", async () => {
    await assertFails(
      recipes("reader")
        .where("book_id", "==", "public-other")
        .where("review_status", "==", "validated")
        .where("is_private", "==", false)
        .where("created_by", "in", [OTHER, PERSONAS.stranger.uid])
        .get(),
    );
  });

  it("livre : mes pages validées (lecteur)", async () => {
    await assertSucceeds(
      recipes("reader")
        .where("book_id", "==", "private-reader")
        .where("review_status", "==", "validated")
        .where("created_by", "==", READER)
        .get(),
    );
  });

  it("livre : sans filtre de confidentialité, refusé au lecteur et à l'éditeur", async () => {
    for (const who of ["reader", "editor"]) {
      await assertFails(
        recipes(who)
          .where("book_id", "==", "public-other")
          .where("review_status", "==", "validated")
          .get(),
      );
    }
  });

  it("livre vide sans filtre : refusé quand même (preuve par les filtres)", async () => {
    await assertFails(
      recipes("reader")
        .where("book_id", "==", "aucun")
        .where("review_status", "==", "validated")
        .get(),
    );
  });

  it("livre : sans filtre, permis à l'administrateur", async () => {
    await assertSucceeds(
      recipes("admin")
        .where("book_id", "==", "private-other")
        .where("review_status", "==", "validated")
        .get(),
    );
  });

  it("brouillons partagés d'un livre : éditeur, comptes de ses groupes", async () => {
    await assertSucceeds(
      recipes("editor")
        .where("book_id", "==", "public-other")
        .where("review_status", "in", ["draft", "inReview"])
        .where("is_private", "==", false)
        .where("created_by", "in", [OTHER, READER])
        .get(),
    );
  });

  it("brouillons partagés d'un livre : refusés au lecteur", async () => {
    await assertFails(
      recipes("reader")
        .where("book_id", "==", "public-other")
        .where("review_status", "in", ["draft", "inReview"])
        .where("is_private", "==", false)
        .get(),
    );
  });

  it("mes brouillons d'un livre (lecteur)", async () => {
    await assertSucceeds(
      recipes("reader")
        .where("book_id", "==", "public-other")
        .where("review_status", "in", ["draft", "inReview"])
        .where("created_by", "==", READER)
        .get(),
    );
  });

  // Le client compte par `count()` ; l'émulateur rejoue la même preuve sur
  // un `get()` aux mêmes filtres.
  it("comptage d'un livre : les miennes + partagées de mes groupes (éditeur)", async () => {
    await assertSucceeds(
      recipes("editor").where("book_id", "==", "public").where("created_by", "==", EDITOR).get(),
    );
    await assertSucceeds(
      recipes("editor")
        .where("book_id", "==", "public")
        .where("is_private", "==", false)
        .where("created_by", "in", [OTHER, READER])
        .get(),
    );
  });

  it("recherche : mes recettes (created_by in [moi])", async () => {
    await assertSucceeds(recipes("reader").where("created_by", "in", [READER]).get());
  });

  it("recherche et planning : recettes validées partagées de la famille", async () => {
    await assertSucceeds(
      recipes("reader")
        .where("created_by", "in", [OTHER, EDITOR])
        .where("review_status", "==", "validated")
        .where("is_private", "==", false)
        .get(),
    );
  });

  it("recettes de la famille sans filtre de confidentialité : refusé", async () => {
    await assertFails(
      recipes("reader")
        .where("created_by", "in", [OTHER])
        .where("review_status", "==", "validated")
        .get(),
    );
  });

  it("livres de la famille : is_private == false", async () => {
    await assertSucceeds(
      db("reader")
        .collection("books")
        .where("created_by", "in", [OTHER, EDITOR])
        .where("is_private", "==", false)
        .get(),
    );
  });

  it("tous les livres sans filtre : refusé au lecteur", async () => {
    await assertFails(db("reader").collection("books").get());
  });

  it("livres de la famille sans filtre de confidentialité : refusé", async () => {
    await assertFails(db("reader").collection("books").where("created_by", "in", [OTHER]).get());
  });

  it("annotations d'une recette visible, triées", async () => {
    await assertSucceeds(
      db("reader").collection("recipes/validated/annotations").orderBy("created_at", "desc").get(),
    );
  });

  it("annotations d'une recette privée d'autrui : refusé", async () => {
    await assertFails(db("reader").collection("recipes/validated-private-other/annotations").get());
  });

  it("mes notes (user_id == moi)", async () => {
    await assertSucceeds(
      db("reader").collection("recipe_ratings").where("user_id", "==", READER).get(),
    );
  });
});

// ── Cloisonnement par groupe familial ────────────────────────────────────
//
// Décision de l'utilisateur (2026-10-10) : je ne vois les livres et recettes
// non privés d'un autre compte que s'il partage au moins un groupe avec moi.
// `stranger` est un éditeur nommé qui ne partage aucun groupe avec les autres
// personas ; un membre sorti d'un groupe est rejoué en réécrivant les portées
// comme le ferait `syncGroupReach`.

describe("groupes — cloisonnement des lectures", () => {
  const STRANGER = PERSONAS.stranger.uid;

  it("un membre du groupe lit le livre partagé d'un autre membre", async () => {
    await assertSucceeds(db("reader").doc("books/public-other").get());
  });

  it("un membre du groupe lit la recette validée d'un autre membre", async () => {
    await assertSucceeds(db("reader").doc("recipes/validated").get());
  });

  it("un membre du groupe lit la note et l'annotation d'un autre membre", async () => {
    await assertSucceeds(db("reader").doc("recipe_ratings/r-other").get());
    await assertSucceeds(db("reader").doc("recipes/validated/annotations/other").get());
  });

  it("un compte hors groupe ne lit pas le livre partagé", async () => {
    await assertFails(db("stranger").doc("books/public-other").get());
  });

  it("un compte hors groupe ne lit pas la recette validée partagée", async () => {
    await assertFails(db("stranger").doc("recipes/validated").get());
  });

  it("un compte hors groupe ne lit ni la note ni l'annotation", async () => {
    await assertFails(db("stranger").doc("recipe_ratings/r-other").get());
    await assertFails(db("stranger").doc("recipes/validated/annotations/other").get());
    await assertFails(db("stranger").collection("recipes/validated/annotations").get());
  });

  it("un compte hors groupe n'annote ni ne note la recette", async () => {
    await assertFails(
      db("stranger").doc("recipes/validated/annotations/new").set({ uid: STRANGER, text: "x" }),
    );
    await assertFails(
      db("stranger")
        .doc("recipe_ratings/new")
        .set({ user_id: STRANGER, recipe_id: "validated", rating: 1 }),
    );
  });

  it("un éditeur hors groupe ne relit pas le brouillon partagé", async () => {
    await assertFails(db("stranger").doc("recipes/draft-other").get());
  });

  it("un éditeur du groupe relit le brouillon partagé", async () => {
    await assertSucceeds(db("editor").doc("recipes/draft-other").get());
  });

  it("un compte hors groupe : ses requêtes sur un autre compte sont refusées", async () => {
    await assertFails(
      db("stranger")
        .collection("recipes")
        .where("created_by", "in", [OTHER])
        .where("review_status", "==", "validated")
        .where("is_private", "==", false)
        .get(),
    );
    await assertFails(
      db("stranger")
        .collection("books")
        .where("created_by", "in", [OTHER])
        .where("is_private", "==", false)
        .get(),
    );
  });

  it("un membre ne lit pas ce que partage un compte hors de ses groupes", async () => {
    await seedDocs(env, {
      "books/stranger-book": { title: "x", created_by: STRANGER, is_private: false, tags: [] },
      "recipes/stranger-recipe": {
        title: "x",
        created_by: STRANGER,
        review_status: "validated",
        is_private: false,
      },
    });
    await assertFails(db("reader").doc("books/stranger-book").get());
    await assertFails(db("reader").doc("recipes/stranger-recipe").get());
    await assertSucceeds(db("stranger").doc("recipes/stranger-recipe").get());
  });

  it("un membre sorti du groupe ne lit plus", async () => {
    // Le lecteur quitte la famille : `syncGroupReach` vide sa portée et
    // retire son uid de celle des autres.
    await seedDocs(env, {
      "groups/famille": { name: "Famille", owner_id: OTHER, member_ids: [OTHER, EDITOR] },
      "group_reach/reader": { uids: [] },
      "group_reach/other-reader": { uids: [EDITOR] },
      "group_reach/editor": { uids: [OTHER] },
    });
    await assertFails(db("reader").doc("books/public-other").get());
    await assertFails(db("reader").doc("recipes/validated").get());
    await assertFails(db("reader").doc("recipe_ratings/r-other").get());
    await assertFails(
      db("reader")
        .collection("recipes")
        .where("created_by", "in", [OTHER])
        .where("review_status", "==", "validated")
        .where("is_private", "==", false)
        .get(),
    );
    // Et les membres restants ne lisent plus ce qu'il partage.
    await assertFails(db("otherReader").doc("books/public-reader").get());
    await assertFails(db("otherReader").doc("recipes/reader-in-other-book").get());
  });

  it("le membre sorti garde ses propres livres et recettes", async () => {
    await seedDocs(env, { "group_reach/reader": { uids: [] } });
    await assertSucceeds(db("reader").doc("books/public-reader").get());
    await assertSucceeds(db("reader").doc("recipes/reader-in-other-book").get());
  });

  it("sans document de portée, on ne lit rien des autres", async () => {
    await assertFails(db("stranger").doc("books/public").get());
  });

  it("un administrateur hors groupe lit tout", async () => {
    await assertSucceeds(db("admin").doc("books/public-other").get());
    await assertSucceeds(db("admin").doc("recipes/validated").get());
    await assertSucceeds(db("admin").doc("recipe_ratings/r-other").get());
  });
});

describe("group_reach — portée des groupes", () => {
  it("son titulaire la lit", async () => {
    await assertSucceeds(db("reader").doc("group_reach/reader").get());
  });

  it("un autre compte ne la lit pas", async () => {
    await assertFails(db("otherReader").doc("group_reach/reader").get());
  });

  it("un administrateur la lit", async () => {
    await assertSucceeds(db("admin").doc("group_reach/reader").get());
  });

  it("personne ne l'écrit depuis le client, administrateur compris", async () => {
    await assertFails(db("stranger").doc("group_reach/stranger").set({ uids: [READER] }));
    await assertFails(
      db("reader")
        .doc("group_reach/reader")
        .update({ uids: [EDITOR, OTHER, "stranger"] }),
    );
    await assertFails(db("admin").doc("group_reach/reader").delete());
  });
});

// ── Invitations ──────────────────────────────────────────────────────────
//
// Entrer dans un groupe ouvre la lecture des livres des autres membres, dans
// les deux sens : on n'y entre que de son propre chef. `g1` appartient au
// lecteur, seul membre.

describe("groupes — invitations", () => {
  const STRANGER = PERSONAS.stranger.uid;
  const invite = () =>
    seedDocs(env, {
      "groups/g1": { name: "Famille", owner_id: READER, member_ids: [READER], invited_ids: [STRANGER] },
    });

  it("le propriétaire invite un compte", async () => {
    await assertSucceeds(db("reader").doc("groups/g1").update({ invited_ids: [STRANGER] }));
  });

  it("le propriétaire n'invite pas un compte déjà membre", async () => {
    await assertFails(db("reader").doc("groups/g1").update({ invited_ids: [READER] }));
  });

  it("un membre qui n'est pas propriétaire n'invite pas", async () => {
    await assertFails(
      db("editor")
        .doc("groups/famille")
        .update({ invited_ids: [STRANGER] }),
    );
  });

  it("un compte ne crée pas un groupe avec des invités", async () => {
    await assertFails(
      db("reader")
        .doc("groups/new")
        .set({ name: "Famille", owner_id: READER, member_ids: [READER], invited_ids: [OTHER] }),
    );
  });

  it("le propriétaire n'ajoute pas un membre en même temps qu'il invite", async () => {
    await assertFails(
      db("reader")
        .doc("groups/g1")
        .update({ member_ids: [READER, OTHER], invited_ids: [STRANGER] }),
    );
  });

  it("un administrateur n'ajoute pas un membre directement", async () => {
    await assertFails(
      db("admin")
        .doc("groups/g1")
        .update({ member_ids: [READER, OTHER] }),
    );
  });

  it("l'invité lit le groupe", async () => {
    await invite();
    await assertSucceeds(db("stranger").doc("groups/g1").get());
    await assertSucceeds(
      db("stranger").collection("groups").where("invited_ids", "array-contains", STRANGER).get(),
    );
  });

  it("un compte non invité ne lit pas le groupe", async () => {
    await invite();
    await assertFails(db("otherReader").doc("groups/g1").get());
  });

  it("l'invité accepte : il passe des invités aux membres", async () => {
    await invite();
    await assertSucceeds(
      db("stranger")
        .doc("groups/g1")
        .update({ member_ids: [READER, STRANGER], invited_ids: [] }),
    );
  });

  it("l'invité n'accepte pas en restant invité", async () => {
    await invite();
    await assertFails(
      db("stranger")
        .doc("groups/g1")
        .update({ member_ids: [READER, STRANGER] }),
    );
  });

  it("l'invité n'entre pas avec un autre compte", async () => {
    await invite();
    await assertFails(
      db("stranger")
        .doc("groups/g1")
        .update({ member_ids: [READER, STRANGER, OTHER], invited_ids: [] }),
    );
  });

  it("l'invité ne renomme pas le groupe en acceptant", async () => {
    await invite();
    await assertFails(
      db("stranger")
        .doc("groups/g1")
        .update({ member_ids: [READER, STRANGER], invited_ids: [], name: "x" }),
    );
  });

  it("un compte non invité ne s'ajoute pas", async () => {
    await invite();
    await assertFails(
      db("otherReader")
        .doc("groups/g1")
        .update({ member_ids: [READER, OTHER] }),
    );
  });

  it("l'invité refuse", async () => {
    await invite();
    await assertSucceeds(db("stranger").doc("groups/g1").update({ invited_ids: [] }));
  });

  it("le propriétaire annule l'invitation", async () => {
    await invite();
    await assertSucceeds(db("reader").doc("groups/g1").update({ invited_ids: [] }));
  });

  it("un membre quitte le groupe", async () => {
    await assertSucceeds(
      db("editor")
        .doc("groups/famille")
        .update({ member_ids: [OTHER, READER] }),
    );
  });

  it("un membre ne retire pas un autre membre en partant", async () => {
    await assertFails(
      db("editor")
        .doc("groups/famille")
        .update({ member_ids: [OTHER] }),
    );
  });

  it("le propriétaire ne quitte pas son propre groupe", async () => {
    await assertFails(
      db("otherReader")
        .doc("groups/famille")
        .update({ member_ids: [READER, EDITOR] }),
    );
  });

  it("le nom d'un groupe compte 60 caractères au plus", async () => {
    await assertSucceeds(db("reader").doc("groups/g1").update({ name: "a".repeat(60) }));
    await assertFails(db("reader").doc("groups/g1").update({ name: "a".repeat(61) }));
    await assertFails(
      db("reader")
        .doc("groups/new")
        .set({ name: "a".repeat(61), owner_id: READER, member_ids: [READER] }),
    );
  });

  it("un groupe compte 50 invitations en attente au plus", async () => {
    const many = (n) => Array.from({ length: n }, (_, i) => `invite-${i}`);
    await assertSucceeds(db("reader").doc("groups/g1").update({ invited_ids: many(50) }));
    await assertFails(db("reader").doc("groups/g1").update({ invited_ids: many(51) }));
  });

  it("le propriétaire retire un membre", async () => {
    await assertSucceeds(
      db("otherReader")
        .doc("groups/famille")
        .update({ member_ids: [OTHER, READER] }),
    );
  });
});

// ── users/{uid}/planning_runs ────────────────────────────────────────────

describe("planning_runs — écrites par le serveur seul", () => {
  const own = `users/${READER}/planning_runs/pr_run`;
  const others = `users/${OTHER}/planning_runs/pr_run`;

  beforeEach(async () => {
    await seedDocs(env, {
      [own]: { concepts_max: 2, concepts_used: 0, cost_usd: 0 },
      [others]: { concepts_max: 2, concepts_used: 0, cost_usd: 0 },
    });
  });

  it("le titulaire ne lit pas sa génération", async () => {
    await assertFails(db("reader").doc(own).get());
  });

  it("le titulaire ne remet pas son compteur de conceptions à zéro", async () => {
    await assertFails(db("reader").doc(own).update({ concepts_used: 0, concepts_max: 99 }));
  });

  it("le titulaire ne crée pas de génération", async () => {
    await assertFails(
      db("reader")
        .doc(`users/${READER}/planning_runs/pr_new`)
        .set({ concepts_max: 99, concepts_used: 0 }),
    );
  });

  it("un autre compte ne lit ni n'écrit la génération d'un autre", async () => {
    await assertFails(db("reader").doc(others).get());
    await assertFails(db("reader").doc(others).update({ concepts_used: 0 }));
  });

  it("un administrateur lit une génération, sans l'écrire", async () => {
    await assertSucceeds(db("admin").doc(own).get());
    await assertFails(db("admin").doc(own).update({ concepts_used: 0 }));
    await assertFails(db("admin").doc(own).delete());
  });
});

// ── users/{uid}/preferences/planning_refusals ────────────────────────────

describe("planning_refusals — mémoire des refus, au titulaire seul", () => {
  const own = `users/${READER}/preferences/planning_refusals`;
  const others = `users/${OTHER}/preferences/planning_refusals`;
  const entry = () => ({ refused_at: new Date("2026-10-09T12:00:00Z"), count: 1 });

  beforeEach(async () => {
    await seedDocs(env, {
      [others]: { entries: { r1: entry() } },
    });
  });

  it("le titulaire écrit, lit et efface ses refus", async () => {
    await assertSucceeds(
      db("reader")
        .doc(own)
        .set({ entries: { r1: entry() }, updated_at: serverTimestamp() }),
    );
    await assertSucceeds(db("reader").doc(own).get());
    await assertSucceeds(db("reader").doc(own).delete());
  });

  it("un autre compte ne lit, n'écrit ni n'efface les refus d'un autre", async () => {
    await assertFails(db("reader").doc(others).get());
    await assertFails(db("reader").doc(others).set({ entries: {} }));
    await assertFails(db("reader").doc(others).delete());
  });

  it("un champ hors forme est refusé", async () => {
    await assertFails(db("reader").doc(own).set({ entries: {}, role: "admin" }));
    await assertFails(db("reader").doc(own).set({ entries: "x" }));
    await assertFails(db("reader").doc(own).set({ entries: {}, updated_at: "hier" }));
  });

  it("plus de 300 entrées sont refusées", async () => {
    const entries = {};
    for (let i = 0; i < 301; i++) entries[`r${i}`] = entry();
    await assertFails(db("reader").doc(own).set({ entries }));
  });

  it("un administrateur lit les refus d'un autre, sans y écrire une forme invalide", async () => {
    await assertSucceeds(db("admin").doc(others).get());
    await assertFails(db("admin").doc(others).set({ entries: "x" }));
  });

  it("les autres préférences du titulaire gardent leur règle", async () => {
    await assertSucceeds(
      db("reader").doc(`users/${READER}/preferences/book_order`).set({ order: ["b1"] }),
    );
  });
});

// ── recipes — durées estimées (estimated_times) ─────────────────────────
//
// Écrites par le serveur seul (`onRecipeWritten`, backfill « Durées
// estimées »). Le client ne les pose pas, ne les change pas et ne les efface
// pas — administrateur compris. Une durée saisie à la main les retire par le
// serveur.
describe("recipes — durées estimées (estimated_times)", () => {
  const estimate = { status: "done", fingerprint: "f", prep: 20, cook: 30 };

  beforeEach(async () => {
    await seedDocs(env, {
      "recipes/estimated-reader": {
        title: "Gratin",
        created_by: READER,
        review_status: "draft",
        estimated_times: estimate,
      },
    });
  });

  it("un éditeur ne crée pas de recette avec une estimation", async () => {
    await assertFails(
      db("editor").doc("recipes/new").set({
        title: "x",
        created_by: EDITOR,
        review_status: "draft",
        estimated_times: estimate,
      }),
    );
  });

  it("le propriétaire ne pose pas d'estimation", async () => {
    await assertFails(
      db("reader").doc("recipes/draft-reader").update({ estimated_times: estimate }),
    );
  });

  it("le propriétaire ne change pas l'estimation", async () => {
    await assertFails(
      db("reader")
        .doc("recipes/estimated-reader")
        .update({ estimated_times: { ...estimate, prep: 5 } }),
    );
  });

  it("le propriétaire n'efface pas l'estimation", async () => {
    await assertFails(
      db("reader").doc("recipes/estimated-reader").update({ estimated_times: deleteField() }),
    );
  });

  it("l'administrateur non plus", async () => {
    await assertFails(
      db("admin").doc("recipes/estimated-reader").update({ estimated_times: deleteField() }),
    );
  });

  it("une édition qui ne touche pas l'estimation passe", async () => {
    await assertSucceeds(
      db("reader").doc("recipes/estimated-reader").update({ title: "Gratin dauphinois" }),
    );
  });
});

// ── recipes — compteurs des reprises automatiques ───────────────────────
//
// `nutrition_catch_up_attempts`, `meal_role_failure_count` et
// `meal_role_attempt_at` bornent les appels de modèle des reprises
// programmées. Écrits par le serveur seul : un créateur qui les remettrait à
// zéro relancerait des appels facturés.
describe("recipes — compteurs des reprises automatiques", () => {
  const counters = {
    nutrition_catch_up_attempts: 5,
    meal_role_failure_count: 3,
    meal_role_attempt_at: new Date("2026-10-12T05:00:00Z"),
  };

  beforeEach(async () => {
    await seedDocs(env, {
      "recipes/retry-editor": {
        title: "Quiche",
        created_by: EDITOR,
        review_status: "validated",
        ...counters,
      },
    });
  });

  for (const field of Object.keys(counters)) {
    it(`l'éditeur créateur ne change pas ${field}`, async () => {
      await assertFails(db("editor").doc("recipes/retry-editor").update({ [field]: 0 }));
    });

    it(`l'éditeur créateur n'efface pas ${field}`, async () => {
      await assertFails(
        db("editor").doc("recipes/retry-editor").update({ [field]: deleteField() }),
      );
    });

    it(`l'éditeur ne crée pas de recette avec ${field}`, async () => {
      await assertFails(
        db("editor")
          .doc("recipes/new-retry")
          .set({ title: "x", created_by: EDITOR, review_status: "draft", [field]: 0 }),
      );
    });
  }

  it("l'éditeur créateur change le titre seul", async () => {
    await assertSucceeds(
      db("editor").doc("recipes/retry-editor").update({ title: "Quiche lorraine" }),
    );
  });
});

// ── users/{uid}/preferences/explore_filters ──────────────────────────────
//
// Filtres, sources et tri de l'écran Explorer : une préférence de lecteur,
// écrite et relue par son seul titulaire. Le lecteur, qui ne crée pas de
// recette, garde la liste et ses filtres.
describe("users/{uid}/preferences/explore_filters", () => {
  const prefs = {
    sources: ["mine", "family"],
    sort: "best_rated",
    filters: { dish_types: ["plat"], max_total_minutes: 30 },
  };

  it("un lecteur enregistre et relit ses filtres", async () => {
    const path = `users/${READER}/preferences/explore_filters`;
    await assertSucceeds(db("reader").doc(path).set(prefs));
    await assertSucceeds(db("reader").doc(path).get());
  });

  it("personne d'autre ne lit ni n'écrit les filtres d'un compte", async () => {
    const path = `users/${OTHER}/preferences/explore_filters`;
    await assertFails(db("reader").doc(path).set(prefs));
    await assertFails(db("reader").doc(path).get());
  });
});

describe("users/{uid}/preferences/explore_filters — forme", () => {
  const path = `users/${READER}/preferences/explore_filters`;

  it("une clé inconnue est refusée", async () => {
    await assertFails(db("reader").doc(path).set({ sort: "title", notes: "texte libre" }));
  });

  it("des sources hors bornes sont refusées", async () => {
    await assertFails(
      db("reader")
        .doc(path)
        .set({ sources: Array.from({ length: 11 }, (_, i) => `s${i}`) }),
    );
  });

  it("l'interrupteur « Compter les durées estimées » s'enregistre dans les filtres", async () => {
    await assertSucceeds(
      db("reader")
        .doc(path)
        .set({
          sources: ["mine"],
          sort: "fastest",
          filters: { max_total_minutes: 30, count_estimated_times: false },
          updated_at: serverTimestamp(),
        }),
    );
  });

  it("des filtres qui ne sont pas une carte sont refusés", async () => {
    await assertFails(db("reader").doc(path).set({ filters: ["plat"] }));
  });

  it("l'aller-retour normal est accepté", async () => {
    await assertSucceeds(
      db("reader")
        .doc(path)
        .set({
          sources: ["mine", "family"],
          sort: "best_rated",
          filters: { dish_types: ["plat"], max_total_minutes: 30 },
          updated_at: serverTimestamp(),
        }),
    );
    await assertSucceeds(db("reader").doc(path).get());
  });

  it("un administrateur lit les filtres d'un autre", async () => {
    await assertSucceeds(db("admin").doc(`users/${OTHER}/preferences/explore_filters`).get());
  });
});

describe("users/{uid}/preferences/explore_filters — bornes", () => {
  const path = `users/${READER}/preferences/explore_filters`;

  it("un tri de 33 caractères est refusé", async () => {
    await assertFails(db("reader").doc(path).set({ sort: "a".repeat(33) }));
  });

  it("des filtres à 21 clés sont refusés", async () => {
    const filters = Object.fromEntries(Array.from({ length: 21 }, (_, i) => [`f${i}`, []]));
    await assertFails(db("reader").doc(path).set({ filters }));
  });
});
