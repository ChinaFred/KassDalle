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
import {
  FOUNDER_EMAIL,
  OPEN_FLAW,
  PERSONAS,
  as,
  createEnv,
  currentScansKey,
  seedDocs,
  seedUsers,
} from "./helpers.mjs";

let env;

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
    "recipe_ratings/r1": { user_id: READER, recipe_id: "validated", rating: 4 },
    "recipe_ratings/r-other": { user_id: OTHER, recipe_id: "validated", rating: 3 },
    "recipe_ratings/r-other-private": {
      user_id: OTHER,
      recipe_id: "validated-private-other",
      rating: 5,
    },
    "recipes/validated/annotations/other": { uid: OTHER, text: "note d'un autre" },
    "groups/g1": { owner_id: READER, member_ids: [READER] },
    "app_config/usage": { storage_bytes: 10, updated_at: 1 },
    "app_config/ai_pricing": { models: {} },
    "app_config/nutrition_policy": { mode: "strict" },
    "processing_jobs/job-reader": { created_by: READER, status: "processing" },
    "processing_jobs/job-editor": { created_by: EDITOR, status: "error" },
    "planned_meals/m1": { uid: READER, date: "2026-10-09" },
    "ai_usage/u1": { uid: READER, cost_usd: 0.01 },
    "ai_usage/u2": { uid: OTHER, cost_usd: 0.02 },
    "ai_daily_spend/d1": { uid: READER, total: 0.01 },
    "nutrition_ingredients/farine": { name: "farine", kcal: 364, shopping_product: "farine" },
    "users/founder": PERSONAS.founder.doc,
  });
});

// ── users ────────────────────────────────────────────────────────────────

describe("users — création de compte", () => {
  const fresh = (claims = { email: "new@example.com" }) =>
    env.authenticatedContext("newcomer", claims).firestore();

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

  it("changer l'adresse puis le rôle du fondateur échoue dès la première écriture", async () => {
    await assertFails(
      db("admin").doc("users/founder").update({ email: "x@example.com", role: "reader" }),
    );
    await assertFails(db("admin").doc("users/founder").update({ role: "reader" }));
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

  it("un éditeur ne lit pas le document d'un autre", OPEN_FLAW, async () => {
    await assertFails(db("editor").doc(`users/${OTHER}`).get());
  });

  it("un anonyme ne lit aucun document de compte", async () => {
    await assertFails(db("anonymous").doc(`users/${READER}`).get());
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
  it("le propriétaire ne retire pas le tag d'un livre système", OPEN_FLAW, async () => {
    await assertFails(db("editor").doc("books/system").update({ tags: [] }));
  });

  it("un administrateur ne retire pas le tag d'un livre système", OPEN_FLAW, async () => {
    await assertFails(db("admin").doc("books/system").update({ tags: [] }));
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
  it("un lecteur crée son brouillon à son nom", async () => {
    await assertSucceeds(
      db("reader")
        .doc("recipes/new")
        .set({ title: "x", created_by: READER, review_status: "draft" }),
    );
  });

  it("un lecteur ne crée pas de recette au nom d'un autre", async () => {
    await assertFails(
      db("reader")
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

  it("un éditeur ne crée pas de recette au nom d'un autre", async () => {
    await assertFails(
      db("editor")
        .doc("recipes/new")
        .set({ title: "x", created_by: OTHER, review_status: "draft" }),
    );
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
describe("recipes — confidentialité suivant le livre", () => {
  const draft = (extra) => ({ title: "x", created_by: READER, review_status: "draft", ...extra });

  it("création dans son livre privé avec is_private:false : refusée", async () => {
    await assertFails(
      db("reader")
        .doc("recipes/new")
        .set(draft({ book_id: "private-reader", is_private: false })),
    );
  });

  it("création dans son livre privé sans is_private : refusée", async () => {
    await assertFails(
      db("reader")
        .doc("recipes/new")
        .set(draft({ book_id: "private-reader" })),
    );
  });

  it("création dans son livre privé avec is_private:true : acceptée", async () => {
    await assertSucceeds(
      db("reader")
        .doc("recipes/new")
        .set(draft({ book_id: "private-reader", is_private: true })),
    );
  });

  it("création dans son livre partagé avec is_private:false : acceptée", async () => {
    await assertSucceeds(
      db("reader")
        .doc("recipes/new")
        .set(draft({ book_id: "public-reader", is_private: false })),
    );
  });

  it("création dans un livre partagé avec is_private:true : refusée", async () => {
    await assertFails(
      db("reader")
        .doc("recipes/new")
        .set(draft({ book_id: "public-reader", is_private: true })),
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
      db("reader")
        .doc("recipes/new")
        .set(draft({ book_id: "private-reader/x", is_private: false })),
    );
  });

  // Le livre doit exister (option A, v0.23.8).
  it("création avec un book_id inexistant : refusée", async () => {
    await assertFails(
      db("reader")
        .doc("recipes/new")
        .set(draft({ book_id: "aucun-livre", is_private: false })),
    );
  });

  it("création sans livre avec is_private:true : acceptée", async () => {
    await assertSucceeds(
      db("reader")
        .doc("recipes/new")
        .set(draft({ is_private: true })),
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
  const draft = (extra) => ({ title: "x", created_by: READER, review_status: "draft", ...extra });

  it("book_id qui n'est ni nul ni une chaîne : refusé", async () => {
    await assertFails(
      db("reader")
        .doc("recipes/new")
        .set(draft({ book_id: 42 })),
    );
  });

  it("un lecteur ne crée pas de recette dans le livre d'un autre", async () => {
    await assertFails(
      db("reader")
        .doc("recipes/new")
        .set(draft({ book_id: "public-other", is_private: false })),
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

  it("un lecteur ne note pas la recette privée d'autrui", async () => {
    await assertFails(
      db("reader")
        .doc("recipe_ratings/new")
        .set({ user_id: READER, recipe_id: "validated-private-other", rating: 2 }),
    );
  });

  it("un lecteur note une recette visible", async () => {
    await assertSucceeds(
      db("reader")
        .doc("recipe_ratings/new")
        .set({ user_id: READER, recipe_id: "validated", rating: 2 }),
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
      db("reader").doc("recipe_ratings/new").set({ user_id: OTHER, recipe_id: "validated" }),
    );
  });

  it("un groupe se crée à son nom, soi seul membre", async () => {
    await assertSucceeds(
      db("reader")
        .doc("groups/new")
        .set({ owner_id: READER, member_ids: [READER] }),
    );
  });

  it("un groupe ne se crée pas au nom d'un autre", async () => {
    await assertFails(
      db("reader")
        .doc("groups/new")
        .set({ owner_id: OTHER, member_ids: [OTHER] }),
    );
  });

  it("un repas planifié ne se crée pas au nom d'un autre", async () => {
    await assertFails(db("reader").doc("planned_meals/new").set({ uid: OTHER }));
  });

  it("un lecteur ne lit pas le repas d'un autre", async () => {
    await assertFails(db("otherReader").doc("planned_meals/m1").get());
  });

  it("note : user_id figé en mise à jour", async () => {
    await assertFails(db("reader").doc("recipe_ratings/r1").update({ user_id: OTHER }));
  });

  it("groupe : owner_id figé en mise à jour", OPEN_FLAW, async () => {
    await assertFails(db("reader").doc("groups/g1").update({ owner_id: OTHER }));
  });

  it("repas planifié : uid figé en mise à jour", OPEN_FLAW, async () => {
    await assertFails(db("reader").doc("planned_meals/m1").update({ uid: OTHER }));
  });
});

// ── comptes en attente et révoqués sur les données personnelles ──────────

describe("données personnelles — pending et révoqué", () => {
  it("un anonyme n'écrit pas de rapport d'erreur", async () => {
    await assertFails(db("anonymous").doc("error_reports/new").set({ user_id: "x" }));
  });

  it("un lecteur écrit son rapport d'erreur", async () => {
    await assertSucceeds(db("reader").doc("error_reports/new").set({ user_id: READER }));
  });

  it("un compte en attente ne planifie pas de repas", OPEN_FLAW, async () => {
    await assertFails(db("pending").doc("planned_meals/new").set({ uid: PERSONAS.pending.uid }));
  });

  it("un compte révoqué ne planifie pas de repas", OPEN_FLAW, async () => {
    await assertFails(db("revoked").doc("planned_meals/new").set({ uid: PERSONAS.revoked.uid }));
  });

  it("un compte en attente n'écrit pas planning_config", OPEN_FLAW, async () => {
    await assertFails(
      db("pending").doc(`planning_config/${PERSONAS.pending.uid}`).set({ days: 7 }),
    );
  });

  it("un compte révoqué n'écrit pas planning_config", OPEN_FLAW, async () => {
    await assertFails(
      db("revoked").doc(`planning_config/${PERSONAS.revoked.uid}`).set({ days: 7 }),
    );
  });

  it("un compte révoqué n'écrit pas de rapport d'erreur", OPEN_FLAW, async () => {
    await assertFails(
      db("revoked").doc("error_reports/new").set({ user_id: PERSONAS.revoked.uid }),
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

  it("usage : storage_bytes reste un entier positif", OPEN_FLAW, async () => {
    await assertFails(db("reader").doc("app_config/usage").update({ storage_bytes: -1 }));
  });

  it("usage : le compteur de scans du mois reste positif", OPEN_FLAW, async () => {
    await assertFails(
      db("reader")
        .doc("app_config/usage")
        .update({ [currentScansKey()]: -1 }),
    );
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

  it("un éditeur ne lit pas le job d'un autre", OPEN_FLAW, async () => {
    await assertFails(db("editor").doc("processing_jobs/job-reader").get());
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

  it("livre partagé : pages validées non privées (lecteur)", async () => {
    await assertSucceeds(
      recipes("reader")
        .where("book_id", "==", "public-other")
        .where("review_status", "==", "validated")
        .where("is_private", "==", false)
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

  it("brouillons partagés d'un livre : éditeur avec is_private == false", async () => {
    await assertSucceeds(
      recipes("editor")
        .where("book_id", "==", "public-other")
        .where("review_status", "in", ["draft", "inReview"])
        .where("is_private", "==", false)
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
  it("comptage d'un livre : partagées + mes privées (éditeur)", async () => {
    await assertSucceeds(
      recipes("editor").where("book_id", "==", "public").where("is_private", "==", false).get(),
    );
    await assertSucceeds(
      recipes("editor")
        .where("book_id", "==", "public")
        .where("created_by", "==", EDITOR)
        .where("is_private", "==", true)
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
