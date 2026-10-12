/**
 * Livres système : ce que le backfill crée pour un compte. Il ne doit créer
 * que les livres absents, reconnus à leur tag, et sauter les comptes en
 * attente ou révoqués.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { Timestamp } from "firebase-admin/firestore";

import {
  SYSTEM_BOOK_TAGS,
  isApprovedAccount,
  missingSystemBooks,
  systemBookDocument,
} from "../callable/systemBooksBackfillCallable";

describe("livres système manquants", () => {
  test("aucun livre : les quatre manquent", () => {
    assert.deepEqual(missingSystemBooks([]), [...SYSTEM_BOOK_TAGS]);
  });
  test("un livre renommé est reconnu à son tag", () => {
    const books = [
      { titre: "Mes idées", tags: ["__libres"] },
      { tags: ["__kassdale_ia", "ia", "kassdale"] },
      { tags: ["cuisine"] },
    ];
    assert.deepEqual(missingSystemBooks(books), ["__secretes", "__web"]);
  });
  test("quatre livres présents : rien à créer", () => {
    const books = SYSTEM_BOOK_TAGS.map((tag) => ({ tags: [tag] }));
    assert.deepEqual(missingSystemBooks(books), []);
  });
  test("tags absents ou mal formés : ignorés", () => {
    assert.deepEqual(missingSystemBooks([{}, { tags: "__libres" }, { tags: [42] }]), [
      ...SYSTEM_BOOK_TAGS,
    ]);
  });
});

describe("comptes concernés", () => {
  test("lecteur, éditeur et administrateur reçoivent les livres", () => {
    for (const role of ["reader", "editor", "admin"]) {
      assert.equal(isApprovedAccount({ role }), true, role);
    }
  });
  test("compte en attente, sans rôle ou révoqué : sauté", () => {
    assert.equal(isApprovedAccount({ role: "pending" }), false);
    assert.equal(isApprovedAccount({}), false);
    assert.equal(isApprovedAccount(undefined), false);
    assert.equal(isApprovedAccount({ role: "editor", is_revoked: true }), false);
  });
  test("rôle entouré d'espaces : lu comme par les gardes", () => {
    assert.equal(isApprovedAccount({ role: " editor " }), true);
  });
});

describe("document d'un livre système", () => {
  const now = Timestamp.fromMillis(0);
  test("« Mes Recettes Secrètes » est privé, au nom du compte", () => {
    const doc = systemBookDocument("__secretes", "u1", "Fred", now);
    assert.equal(doc.is_private, true);
    assert.equal(doc.auteur, "Fred");
    assert.equal(doc.created_by, "u1");
    assert.deepEqual(doc.tags, ["__secretes"]);
  });
  test("« Mes recettes libres » et « Mes créations » sont partagés", () => {
    assert.equal(systemBookDocument("__libres", "u1", "Fred", now).is_private, false);
    const ia = systemBookDocument("__kassdale_ia", "u1", "Fred", now);
    assert.equal(ia.is_private, false);
    assert.equal(ia.auteur, "Kass'Dalle");
    assert.deepEqual(ia.tags, ["__kassdale_ia", "ia", "kassdale"]);
  });
});
