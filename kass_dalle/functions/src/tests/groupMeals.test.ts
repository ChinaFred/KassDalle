/**
 * Ce qui part avec un groupe ou avec un membre : la liste des membres sortis
 * (`departedMembers`) et la suppression page par page (`deleteInPages`),
 * que `syncGroupReach` applique aux repas et aux suggestions de repas.
 * Logique pure, sans Firestore.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import {
  DELETE_BATCH_SIZE,
  MAX_BATCHES,
  deleteInPages,
  departedMembers,
} from "../triggers/groupMeals";

describe("departedMembers", () => {
  test("départ d'un membre : lui seul", () => {
    assert.deepEqual(
      departedMembers(
        { owner_id: "o", member_ids: ["o", "a", "b"] },
        { owner_id: "o", member_ids: ["o", "b"] },
      ),
      ["a"],
    );
  });

  test("retrait de plusieurs membres par le propriétaire : triés", () => {
    assert.deepEqual(
      departedMembers(
        { owner_id: "o", member_ids: ["o", "c", "a", "b"] },
        { owner_id: "o", member_ids: ["o"] },
      ),
      ["a", "b", "c"],
    );
  });

  test("arrivée d'un membre, invitation refusée, renommage : personne", () => {
    assert.deepEqual(
      departedMembers(
        { owner_id: "o", member_ids: ["o"] },
        { owner_id: "o", member_ids: ["o", "a"] },
      ),
      [],
    );
    assert.deepEqual(
      departedMembers(
        { owner_id: "o", member_ids: ["o"], invited_ids: ["x"] },
        { owner_id: "o", member_ids: ["o"], invited_ids: [] },
      ),
      [],
    );
    assert.deepEqual(
      departedMembers(
        { name: "A", owner_id: "o", member_ids: ["o", "a"] },
        { name: "B", owner_id: "o", member_ids: ["a", "o"] },
      ),
      [],
    );
  });

  test("création ou suppression du groupe : personne", () => {
    assert.deepEqual(departedMembers(undefined, { owner_id: "o", member_ids: ["o"] }), []);
    assert.deepEqual(departedMembers({ owner_id: "o", member_ids: ["o", "a"] }, undefined), []);
  });

  test("champs mal formés : ignorés, jamais d'exception", () => {
    assert.deepEqual(
      departedMembers({ owner_id: "o", member_ids: ["a", 3, "x/y"] }, { owner_id: "o" }),
      ["a"],
    );
  });
});

describe("deleteInPages", () => {
  /** Une collection en mémoire, lue par pages de DELETE_BATCH_SIZE. */
  function store(count: number) {
    const docs = Array.from({ length: count }, (_, i) => `d${i}`);
    const pages: number[] = [];
    return {
      docs,
      pages,
      fetch: async () => docs.slice(0, DELETE_BATCH_SIZE),
      remove: async (page: string[]) => {
        pages.push(page.length);
        docs.splice(0, page.length);
      },
    };
  }

  test("rien à supprimer : zéro, aucun lot", async () => {
    const s = store(0);
    assert.equal(await deleteInPages(s.fetch, s.remove, "test"), 0);
    assert.deepEqual(s.pages, []);
  });

  test("une page incomplète : un lot, puis arrêt", async () => {
    const s = store(3);
    assert.equal(await deleteInPages(s.fetch, s.remove, "test"), 3);
    assert.deepEqual(s.pages, [3]);
    assert.equal(s.docs.length, 0);
  });

  test("plusieurs pages : supprime tout", async () => {
    const s = store(DELETE_BATCH_SIZE * 2 + 5);
    assert.equal(await deleteInPages(s.fetch, s.remove, "test"), DELETE_BATCH_SIZE * 2 + 5);
    assert.deepEqual(s.pages, [DELETE_BATCH_SIZE, DELETE_BATCH_SIZE, 5]);
  });

  test("au-delà du plafond de lots : lève, avec le libellé", async () => {
    const full = Array.from({ length: DELETE_BATCH_SIZE }, (_, i) => i);
    let calls = 0;
    await assert.rejects(
      deleteInPages(
        async () => full,
        async () => {
          calls += 1;
        },
        "deleteGroupSuggestions(g1)",
      ),
      /deleteGroupSuggestions\(g1\).*suppression incomplète/,
    );
    assert.equal(calls, MAX_BATCHES);
  });

  test("une erreur d'écriture remonte à l'appelant", async () => {
    const s = store(2);
    await assert.rejects(
      deleteInPages(
        s.fetch,
        async () => {
          throw new Error("refus");
        },
        "test",
      ),
      /refus/,
    );
  });
});
