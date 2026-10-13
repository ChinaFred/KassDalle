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
  groupPlanningsFrom,
  invitationsToResync,
  isActiveGroup,
  maskedInvitationsFrom,
  MAX_SHARED_GROUPS,
  planningReachFrom,
  planningShareChanged,
  samePlanningReach,
  sharedGroupIdsOf,
  type GroupEntry,
  type OwnerState,
} from "../triggers/planningReach";
import { invitedOfOwnedGroups, membersOfOwnedGroups } from "../triggers/plannerRole";
import {
  groupAccounts,
  needsGroupIdField,
  summarizeGroupPlanningReach,
} from "../callable/groupPlanningReachBackfillCallable";
import { readPlanningGroupId } from "../callable/_aiInputReaders";

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

  test("un groupe masqué ne partage plus les plannings personnels de ses membres", () => {
    // Zoé, éditrice, partage avec « famille », dont la propriétaire Marie est
    // rétrogradée : le groupe est masqué, le partage ne passe plus par lui.
    const state = owners({
      marie: { config: {}, user: reader },
      zoe: { config: { shared_group_ids: ["famille"] }, user: editor },
    });
    assert.deepEqual(planningReachFrom("paul", [famille], state), []);
  });
});

describe("isActiveGroup", () => {
  test("le propriétaire planifie : actif", () => {
    const state = owners({ marie: { config: null, user: editor } });
    assert.equal(isActiveGroup(famille.data, state), true);
  });

  test("propriétaire lecteur, révoqué, en attente ou inconnu : masqué", () => {
    for (const user of [reader, { role: "editor", is_revoked: true }, { role: "pending" }, null]) {
      assert.equal(isActiveGroup(famille.data, owners({ marie: { config: null, user } })), false);
    }
    assert.equal(isActiveGroup(famille.data, owners({})), false);
    assert.equal(isActiveGroup({ member_ids: ["a"] }, owners({})), false);
  });
});

describe("groupPlanningsFrom", () => {
  const state = owners({
    marie: { config: null, user: editor },
    paul: { config: null, user: reader },
  });

  test("les groupes actifs dont je suis membre, propriétaire compris", () => {
    assert.deepEqual(groupPlanningsFrom("zoe", [famille, cousins], state), {
      groupIds: ["famille"],
      maskedGroupIds: [],
    });
    assert.deepEqual(groupPlanningsFrom("marie", [famille], state), {
      groupIds: ["famille"],
      maskedGroupIds: [],
    });
  });

  test("le groupe d'un propriétaire rétrogradé est masqué, pour lui aussi", () => {
    assert.deepEqual(groupPlanningsFrom("lea", [cousins], state), {
      groupIds: [],
      maskedGroupIds: ["cousins"],
    });
    assert.deepEqual(groupPlanningsFrom("paul", [famille, cousins], state), {
      groupIds: ["famille"],
      maskedGroupIds: ["cousins"],
    });
  });

  test("un invité ne lit pas le planning du groupe", () => {
    assert.deepEqual(groupPlanningsFrom("invite", [famille], state), {
      groupIds: [],
      maskedGroupIds: [],
    });
  });
});

describe("samePlanningReach", () => {
  const expected = { uids: ["a"], groupIds: ["g"], maskedGroupIds: [], maskedInvitationIds: [] };

  test("mêmes listes : rien à écrire", () => {
    assert.equal(
      samePlanningReach(
        { uids: ["a"], group_ids: ["g"], masked_group_ids: [], masked_invitation_ids: [] },
        expected,
      ),
      true,
    );
  });

  test("document sans masked_invitation_ids : à écrire", () => {
    assert.equal(
      samePlanningReach({ uids: ["a"], group_ids: ["g"], masked_group_ids: [] }, expected),
      false,
    );
  });

  test("document antérieur sans group_ids : à écrire", () => {
    assert.equal(samePlanningReach({ uids: ["a"] }, expected), false);
    assert.equal(samePlanningReach(undefined, expected), false);
  });

  test("une liste différente : à écrire", () => {
    assert.equal(
      samePlanningReach({ uids: ["a"], group_ids: [], masked_group_ids: ["g"] }, expected),
      false,
    );
  });
});

describe("membersOfOwnedGroups", () => {
  test("le propriétaire et les membres de ses groupes, triés", () => {
    assert.deepEqual(membersOfOwnedGroups("marie", [famille.data, { owner_id: "marie" }]), [
      "marie",
      "paul",
      "zoe",
    ]);
  });

  test("aucun groupe : le propriétaire seul", () => {
    assert.deepEqual(membersOfOwnedGroups("marie", []), ["marie"]);
  });
});

describe("groupAccounts (backfill)", () => {
  test("les membres et les invités de tous les groupes, sans doublon", () => {
    assert.deepEqual(groupAccounts([famille.data, cousins.data, undefined]), [
      "invite",
      "lea",
      "marie",
      "paul",
      "zoe",
    ]);
  });
});

describe("maskedInvitationsFrom", () => {
  test("une invitation vers un groupe en pause est masquée", () => {
    const state = owners({ marie: { config: null, user: reader } });
    assert.deepEqual(maskedInvitationsFrom("invite", [famille], state), ["famille"]);
  });

  test("propriétaire éditeur : invitation visible", () => {
    const state = owners({ marie: { config: null, user: editor } });
    assert.deepEqual(maskedInvitationsFrom("invite", [famille], state), []);
  });

  test("un compte non invité n'a rien", () => {
    const state = owners({ marie: { config: null, user: reader } });
    assert.deepEqual(maskedInvitationsFrom("paul", [famille], state), []);
  });
});

describe("invitationsToResync", () => {
  test("invités ajoutés et retirés", () => {
    assert.deepEqual(
      invitationsToResync({ invited_ids: ["a", "b"] }, { invited_ids: ["b", "c"] }),
      ["a", "c"],
    );
  });

  test("groupe supprimé : tous ses invités", () => {
    assert.deepEqual(invitationsToResync({ invited_ids: ["a", "b"] }, undefined), ["a", "b"]);
  });

  test("invitations inchangées : personne", () => {
    assert.deepEqual(
      invitationsToResync({ invited_ids: ["a"], name: "x" }, { invited_ids: ["a"], name: "y" }),
      [],
    );
  });
});

describe("invitedOfOwnedGroups", () => {
  test("les invités, triés, sans valeur mal formée", () => {
    assert.deepEqual(
      invitedOfOwnedGroups([{ invited_ids: ["b", "a", 3, "", "x/y"] }, { invited_ids: ["a"] }]),
      ["a", "b"],
    );
  });
});

describe("needsGroupIdField (backfill, repas)", () => {
  test("repas sans le champ : à marquer", () => {
    assert.equal(needsGroupIdField({}), true);
    assert.equal(needsGroupIdField(undefined), true);
  });

  test("champ présent, nul ou non : gardé", () => {
    assert.equal(needsGroupIdField({ group_id: null }), false);
    assert.equal(needsGroupIdField({ group_id: "gd" }), false);
  });
});

describe("summarizeGroupPlanningReach", () => {
  const base = {
    groupes: 1,
    examines: 2,
    ecrits: 1,
    dejaAJour: 1,
    echoues: 0,
    restants: 0,
    repasExamines: 10,
    repasMarques: 4,
    repasEchoues: 0,
    repasRestants: 0,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: true,
    aRevoir: { items: [], total: 0 },
  };

  test("comptes et repas restants additionnés", () => {
    assert.equal(
      summarizeGroupPlanningReach({ ...base, restants: 2, repasRestants: 5 }).remaining,
      7,
    );
  });

  test("décompte des repas inconnu : reste inconnu", () => {
    assert.equal(summarizeGroupPlanningReach({ ...base, repasRestants: null }).remaining, null);
  });
});

describe("readPlanningGroupId", () => {
  test("absent ou nul : planning personnel", () => {
    assert.equal(readPlanningGroupId({}), null);
    assert.equal(readPlanningGroupId({ groupId: null }), null);
  });

  test("identifiant de document : gardé", () => {
    assert.equal(readPlanningGroupId({ groupId: "Ab3_x-9" }), "Ab3_x-9");
  });

  test("autre forme : refusée", () => {
    for (const groupId of ["", "a/b", 42, "x".repeat(129), ["g"]]) {
      assert.throws(() => readPlanningGroupId({ groupId }), /groupId/);
    }
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
