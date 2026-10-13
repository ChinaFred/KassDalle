// Panier de courses personnel : users/{uid}/shopping/current.
//
// Le titulaire nommé le lit et l'écrit ; personne d'autre, administrateur
// compris. La forme est bornée : `items` en carte de 300 articles au plus, et
// rien d'autre que `items` et `updated_at`.

import { after, before, beforeEach, describe, it } from "node:test";
import { assertFails, assertSucceeds } from "@firebase/rules-unit-testing";
import firebase from "firebase/compat/app";
import "firebase/compat/firestore";
import { PERSONAS, as, createEnv, seedDocs, seedUsers } from "./helpers.mjs";

let env;

const { FieldPath, FieldValue } = firebase.firestore;
const db = (name) => as(env, name).firestore();

const READER = PERSONAS.reader.uid;
const OTHER = PERSONAS.otherReader.uid;
const own = `users/${READER}/shopping/current`;
const others = `users/${OTHER}/shopping/current`;

const article = (name, pos = 0) => ({
  name,
  quantities: [{ qty: "200", unit: "g" }],
  category: "Épicerie",
  source: "Poulet basquaise",
  checked: false,
  pos,
});

const cart = (count) => {
  const items = {};
  for (let i = 0; i < count; i++) items[`produit ${i}`] = article(`Produit ${i}`, i);
  return { items, updated_at: FieldValue.serverTimestamp() };
};

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
    [own]: { items: { riz: article("Riz") } },
    [others]: { items: { ail: article("Ail") } },
  });
});

describe("shopping — panier de courses, au titulaire seul", () => {
  it("le titulaire lit son panier", async () => {
    await assertSucceeds(db("reader").doc(own).get());
  });

  it("le titulaire écrit son panier : remplacer, cocher, retirer, vider", async () => {
    const ref = db("reader").doc(own);
    await assertSucceeds(ref.set(cart(3)));
    await assertSucceeds(
      ref.update(new FieldPath("items", "produit 1", "checked"), true),
    );
    await assertSucceeds(
      ref.update(new FieldPath("items", "produit 1"), FieldValue.delete()),
    );
    await assertSucceeds(ref.set({ items: {}, updated_at: FieldValue.serverTimestamp() }));
    await assertSucceeds(ref.delete());
  });

  it("un compte nommé crée son panier quand il n'existe pas", async () => {
    const path = `users/${PERSONAS.editor.uid}/shopping/current`;
    await assertSucceeds(db("editor").doc(path).set(cart(1)));
  });

  it("un autre compte ne lit pas le panier", async () => {
    await assertFails(db("otherReader").doc(own).get());
    await assertFails(db("editor").doc(own).get());
  });

  it("un autre compte n'écrit pas le panier", async () => {
    await assertFails(db("otherReader").doc(own).set(cart(1)));
    await assertFails(
      db("otherReader").doc(own).update(new FieldPath("items", "riz", "checked"), true),
    );
    await assertFails(db("otherReader").doc(own).delete());
  });

  it("l'administrateur ne lit ni n'écrit le panier d'un autre", async () => {
    await assertFails(db("admin").doc(own).get());
    await assertFails(db("admin").doc(own).set(cart(1)));
  });

  it("anonyme, en attente et révoqué n'y ont pas accès", async () => {
    await assertFails(db("anonymous").doc(own).get());
    for (const name of ["pending", "revoked", "revokedStaleToken"]) {
      const path = `users/${PERSONAS[name].uid}/shopping/current`;
      await assertFails(db(name).doc(path).get());
      await assertFails(db(name).doc(path).set(cart(1)));
    }
  });

  it("un seul document : `current`", async () => {
    await assertFails(db("reader").doc(`users/${READER}/shopping/autre`).set(cart(1)));
    await assertFails(db("reader").doc(`users/${READER}/shopping/autre`).get());
  });
});

describe("shopping — forme bornée", () => {
  it("300 articles passent, 301 sont refusés", async () => {
    const ref = db("reader").doc(own);
    await assertSucceeds(ref.set(cart(300)));
    await assertFails(ref.set(cart(301)));
  });

  it("un article de trop par mise à jour est refusé", async () => {
    await seedDocs(env, { [own]: { items: cart(300).items } });
    await assertFails(
      db("reader").doc(own).update(new FieldPath("items", "un de plus"), article("Un de plus")),
    );
  });

  it("un champ inconnu est refusé", async () => {
    await assertFails(db("reader").doc(own).set({ ...cart(1), notes: "texte libre" }));
  });

  it("`items` doit être une carte", async () => {
    await assertFails(db("reader").doc(own).set({ items: [article("Riz")] }));
    await assertFails(db("reader").doc(own).set({ items: "Riz" }));
  });

  it("`updated_at` doit être une date", async () => {
    await assertFails(db("reader").doc(own).set({ items: {}, updated_at: "hier" }));
  });
});
