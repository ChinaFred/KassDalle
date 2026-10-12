/**
 * Portée des plannings : les propriétaires dont un compte peut lire le
 * planning, que les règles Firestore lisent dans `planning_reach/{uid}`.
 * Logique pure.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import {
  canSharePlanning,
  changedSharedGroups,
  MAX_SHARED_GROUPS,
  planningReachFrom,
  planningShareChanged,
  sharedGroupIdsOf,
  type GroupEntry,
  type OwnerState,
} from "../triggers/planningReach";

const editor = { role: "editor", is_revoked: false };
const admin = { role: "admin" };
const reader = { role: "reader", is_revoked: false };

const famille: GroupEntry = {
  id: "famille",
  data: { owner_id: "marie", member_ids: ["marie", "paul", "zoe"], invited_ids: ["invite"] },
};
const cousins: GroupEntry = {
  id: "cousins",
  data: { owner_id: "paul", member_ids: ["paul", "lea"] },
};

function owners(entries: Record<string, OwnerState>): Map<string, OwnerState> {
  return new Map(Object.entries(entries));
}

describe("canSharePlanning", () => {
  test("éditeur et administrateur non révoqués partagent", () => {
    assert.equal(canSharePlanning(editor), true);
    assert.equal(canSharePlanning(admin), true);
  });

  test("lecteur, en attente, révoqué, absent : rien", () => {
    assert.equal(canSharePlanning(reader), false);
    assert.equal(canSharePlanning({ role: "pending" }), false);
    assert.equal(canSharePlanning({ role: "editor", is_revoked: true }), false);
    assert.equal(canSharePlanning(undefined), false);
    assert.equal(canSharePlanning(null), false);
    assert.equal(canSharePlanning({ role: 42 }), false);
  });
});

describe("sharedGroupIdsOf", () => {
  test("chaînes utilisables, sans doublon, dans l'ordre", () => {
    assert.deepEqual(
      sharedGroupIdsOf({ shared_group_ids: ["g1", 3, "", " g2 ", "g1", "a/b", null] }),
      ["g1", "g2"],
    );
  });

  test("absent ou mal formé : rien", () => {
    assert.deepEqual(sharedGroupIdsOf(undefined), []);
    assert.deepEqual(sharedGroupIdsOf({}), []);
    assert.deepEqual(sharedGroupIdsOf({ shared_group_ids: "g1" }), []);
  });

  test("plafonné", () => {
    const many = Array.from({ length: MAX_SHARED_GROUPS + 10 }, (_, i) => `g${i}`);
    assert.equal(sharedGroupIdsOf({ shared_group_ids: many }).length, MAX_SHARED_GROUPS);
  });
});

describe("planningReachFrom", () => {
  test("un éditeur qui coche le groupe est lu par les autres membres", () => {
    const state = owners({
      marie: { config: { shared_group_ids: ["famille"] }, user: editor },
      zoe: { config: {}, user: editor },
    });
    assert.deepEqual(planningReachFrom("paul", [famille, cousins], state), ["marie"]);
    assert.deepEqual(planningReachFrom("zoe", [famille], state), ["marie"]);
  });

  test("pas de réciprocité, et jamais soi-même", () => {
    const state = owners({
      marie: { config: { shared_group_ids: ["famille"] }, user: editor },
      paul: { config: {}, user: editor },
    });
    assert.deepEqual(planningReachFrom("marie", [famille], state), []);
  });

  test("un propriétaire lecteur ou révoqué ne partage rien (suspendu)", () => {
    for (const user of [reader, { role: "editor", is_revoked: true }, { role: "pending" }]) {
      const state = owners({ marie: { config: { shared_group_ids: ["famille"] }, user } });
      assert.deepEqual(planningReachFrom("paul", [famille], state), []);
    }
  });

  test("un groupe non coché ne partage rien", () => {
    const state = owners({
      paul: { config: { shared_group_ids: ["cousins"] }, user: editor },
    });
    assert.deepEqual(planningReachFrom("zoe", [famille], state), []);
    assert.deepEqual(planningReachFrom("lea", [cousins], state), ["paul"]);
  });

  test("un invité n'est pas membre : il ne lit rien", () => {
    const state = owners({
      marie: { config: { shared_group_ids: ["famille"] }, user: editor },
    });
    assert.deepEqual(planningReachFrom("invite", [famille], state), []);
  });

  test("un groupe disparu dans shared_group_ids est ignoré", () => {
    const state = owners({
      marie: { config: { shared_group_ids: ["disparu"] }, user: editor },
    });
    assert.deepEqual(planningReachFrom("paul", [famille], state), []);
  });

  test("un propriétaire sorti du groupe ne partage plus par lui", () => {
    const sansMarie: GroupEntry = {
      id: "famille",
      data: { owner_id: "paul", member_ids: ["paul", "zoe"] },
    };
    const state = owners({
      marie: { config: { shared_group_ids: ["famille"] }, user: editor },
    });
    assert.deepEqual(planningReachFrom("zoe", [sansMarie], state), []);
  });

  test("trié, sans doublon quand deux groupes relient les mêmes comptes", () => {
    const deux: GroupEntry = {
      id: "deux",
      data: { owner_id: "zoe", member_ids: ["zoe", "marie", "paul"] },
    };
    const state = owners({
      zoe: { config: { shared_group_ids: ["famille", "deux"] }, user: admin },
      marie: { config: { shared_group_ids: ["deux"] }, user: editor },
    });
    assert.deepEqual(planningReachFrom("paul", [famille, deux], state), ["marie", "zoe"]);
  });

  test("données mal formées : ignorées, jamais d'exception", () => {
    const state = owners({ marie: { config: null, user: null } });
    assert.deepEqual(planningReachFrom("paul", [{ id: "x", data: undefined }, famille], state), []);
  });
});

describe("changedSharedGroups", () => {
  test("ajoutés et retirés, triés", () => {
    assert.deepEqual(
      changedSharedGroups({ shared_group_ids: ["a", "b"] }, { shared_group_ids: ["b", "c"] }),
      ["a", "c"],
    );
  });

  test("même liste, autre ordre, ou autre champ : rien", () => {
    assert.deepEqual(
      changedSharedGroups(
        { shared_group_ids: ["a", "b"], days: 7 },
        { shared_group_ids: ["b", "a"], days: 5 },
      ),
      [],
    );
  });

  test("document créé ou supprimé", () => {
    assert.deepEqual(changedSharedGroups(undefined, { shared_group_ids: ["a"] }), ["a"]);
    assert.deepEqual(changedSharedGroups({ shared_group_ids: ["a"] }, undefined), ["a"]);
  });
});

describe("planningShareChanged", () => {
  test("promu éditeur, rétrogradé, révoqué, supprimé : oui", () => {
    assert.equal(planningShareChanged(reader, editor), true);
    assert.equal(planningShareChanged(editor, reader), true);
    assert.equal(planningShareChanged(editor, { role: "editor", is_revoked: true }), true);
    assert.equal(planningShareChanged(admin, undefined), true);
  });

  test("autre champ, ou éditeur devenu administrateur : non", () => {
    assert.equal(planningShareChanged(editor, { ...editor, display_name: "Marie" }), false);
    assert.equal(planningShareChanged(editor, admin), false);
    assert.equal(planningShareChanged(reader, { role: "pending" }), false);
  });
});
