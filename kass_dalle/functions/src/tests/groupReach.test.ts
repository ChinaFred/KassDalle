/**
 * Portée des groupes : la liste des autres comptes avec qui un compte partage
 * un groupe, que les règles Firestore lisent dans `group_reach/{uid}` pour
 * cloisonner livres et recettes. Logique pure.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import { accountsToResync, membersOf, reachFromGroups, sameReach } from "../triggers/groupReach";
import { groupsByMember } from "../callable/groupReachBackfillCallable";

describe("membersOf", () => {
  test("réunit le propriétaire et les membres, triés, sans doublon", () => {
    assert.deepEqual(membersOf({ owner_id: "c", member_ids: ["b", "c", "a", "b"] }), [
      "a",
      "b",
      "c",
    ]);
  });

  test("le propriétaire absent de member_ids reste membre", () => {
    assert.deepEqual(membersOf({ owner_id: "o", member_ids: ["m"] }), ["m", "o"]);
  });

  test("champs mal formés : ignorés, jamais d'exception", () => {
    assert.deepEqual(membersOf(undefined), []);
    assert.deepEqual(membersOf(null), []);
    assert.deepEqual(membersOf({ owner_id: 42, member_ids: "a" }), []);
    assert.deepEqual(membersOf({ owner_id: "  ", member_ids: [null, "", 3, " x "] }), ["x"]);
  });
});

describe("reachFromGroups", () => {
  const famille = { owner_id: "papa", member_ids: ["papa", "maman", "lea"] };
  const amis = { owner_id: "lea", member_ids: ["zoe"] };
  const voisins = { owner_id: "voisin", member_ids: ["voisine"] };

  test("les autres membres de mes groupes, sans moi, triés", () => {
    assert.deepEqual(reachFromGroups("lea", [famille, amis, voisins]), ["maman", "papa", "zoe"]);
  });

  test("propriétaire seul de member_ids absent : il voit ses membres", () => {
    assert.deepEqual(reachFromGroups("lea", [amis]), ["zoe"]);
    assert.deepEqual(reachFromGroups("zoe", [amis]), ["lea"]);
  });

  test("un compte sans groupe, ou seul dans le sien, a une portée vide", () => {
    assert.deepEqual(reachFromGroups("inconnu", [famille, amis]), []);
    assert.deepEqual(reachFromGroups("solo", [{ owner_id: "solo", member_ids: ["solo"] }]), []);
    assert.deepEqual(reachFromGroups("lea", []), []);
  });

  test("un membre commun à deux groupes n'apparaît qu'une fois", () => {
    const autre = { owner_id: "maman", member_ids: ["lea"] };
    assert.deepEqual(reachFromGroups("lea", [famille, autre]), ["maman", "papa"]);
  });

  test("un groupe mal formé ne casse pas le calcul", () => {
    assert.deepEqual(reachFromGroups("lea", [undefined, null, { member_ids: 7 }, amis]), ["zoe"]);
  });
});

describe("accountsToResync", () => {
  test("création : tous les membres", () => {
    assert.deepEqual(accountsToResync(undefined, { owner_id: "a", member_ids: ["b"] }), ["a", "b"]);
  });

  test("suppression : tous les anciens membres", () => {
    assert.deepEqual(accountsToResync({ owner_id: "a", member_ids: ["b"] }, undefined), ["a", "b"]);
  });

  test("départ d'un membre : l'union avant et après, le partant compris", () => {
    assert.deepEqual(
      accountsToResync(
        { owner_id: "a", member_ids: ["a", "b", "c"] },
        { owner_id: "a", member_ids: ["a", "b"] },
      ),
      ["a", "b", "c"],
    );
  });

  test("changement de propriétaire : l'ancien et le nouveau", () => {
    assert.deepEqual(
      accountsToResync({ owner_id: "a", member_ids: ["b"] }, { owner_id: "c", member_ids: ["b"] }),
      ["a", "b", "c"],
    );
  });

  test("composition inchangée (renommage, ordre) : personne", () => {
    assert.deepEqual(
      accountsToResync(
        { owner_id: "a", member_ids: ["b", "c"], name: "Avant" },
        { owner_id: "a", member_ids: ["c", "b", "a"], name: "Après" },
      ),
      [],
    );
  });
});

describe("sameReach", () => {
  test("même liste : rien à écrire", () => {
    assert.equal(sameReach({ uids: ["a", "b"], updated_at: 1 }, ["a", "b"]), true);
    assert.equal(sameReach({ uids: [] }, []), true);
  });

  test("liste différente, document absent ou mal formé : à écrire", () => {
    assert.equal(sameReach({ uids: ["a"] }, ["a", "b"]), false);
    assert.equal(sameReach({ uids: ["b", "a"] }, ["a", "b"]), false);
    assert.equal(sameReach(undefined, []), false);
    assert.equal(sameReach({ uids: "a" }, ["a"]), false);
    assert.equal(sameReach({}, []), false);
  });
});

describe("groupsByMember", () => {
  test("indexe chaque groupe sous chacun de ses membres", () => {
    const g1 = { owner_id: "a", member_ids: ["b"] };
    const g2 = { owner_id: "b", member_ids: ["c"] };
    const index = groupsByMember([g1, g2, undefined]);
    assert.deepEqual(index.get("a"), [g1]);
    assert.deepEqual(index.get("b"), [g1, g2]);
    assert.deepEqual(index.get("c"), [g2]);
    assert.equal(index.has("d"), false);
  });

  test("l'index donne la même portée que la liste complète", () => {
    const groups = [
      { owner_id: "a", member_ids: ["a", "b"] },
      { owner_id: "b", member_ids: ["c"] },
      { owner_id: "x", member_ids: ["y"] },
    ];
    const index = groupsByMember(groups);
    for (const uid of ["a", "b", "c", "x", "y", "z"]) {
      assert.deepEqual(reachFromGroups(uid, index.get(uid) ?? []), reachFromGroups(uid, groups));
    }
  });
});
