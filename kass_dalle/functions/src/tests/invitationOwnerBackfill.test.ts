/**
 * Backfill « Propriétaire du groupe des invitations » (ticket #152) : ce que
 * le passage décide pour chaque invitation, sans Firestore.
 *
 * Ce que ces tests verrouillent : une invitation qui porte déjà
 * `group_owner_id` n'est pas réécrite ; le champ ne se recopie que depuis un
 * groupe existant dont l'auteur de l'invitation est le propriétaire ; un groupe
 * supprimé, recréé par un autre compte ou illisible laisse l'invitation
 * intacte, listée à revoir.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  invitationOwnerDecision,
  summarizeInvitationOwner,
  type BackfillInvitationOwnerResponse,
} from "../callable/invitationOwnerBackfillCallable";

const INVITATION = {
  email: "marie@example.com",
  group_id: "g1",
  group_name: "Famille",
  invited_by: "admin1",
};

describe("invitationOwnerDecision", () => {
  test("champ déjà posé : rien à écrire, même sans groupe", () => {
    assert.deepEqual(invitationOwnerDecision({ ...INVITATION, group_owner_id: "o1" }, null), {
      kind: "up_to_date",
    });
  });

  test("auteur propriétaire du groupe : le propriétaire est recopié", () => {
    assert.deepEqual(
      invitationOwnerDecision(INVITATION, { owner_id: "admin1", member_ids: ["admin1"] }),
      { kind: "write", ownerId: "admin1" },
    );
  });

  test("auteur simple membre : à revoir, rien d'écrit", () => {
    const d = invitationOwnerDecision(INVITATION, { owner_id: "o1", member_ids: ["o1", "admin1"] });
    assert.equal(d.kind, "review");
  });

  test("champ vide ou d'un autre type : repris comme absent", () => {
    const group = { owner_id: "admin1", member_ids: ["admin1"] };
    for (const value of ["", "  ", 42, null]) {
      assert.equal(
        invitationOwnerDecision({ ...INVITATION, group_owner_id: value }, group).kind,
        "write",
        String(value),
      );
    }
  });

  test("groupe supprimé : à revoir, rien d'écrit", () => {
    const d = invitationOwnerDecision(INVITATION, null);
    assert.equal(d.kind, "review");
  });

  test("groupe recréé par un autre compte, sans l'auteur : à revoir", () => {
    const d = invitationOwnerDecision(INVITATION, { owner_id: "pirate", member_ids: ["pirate"] });
    assert.equal(d.kind, "review");
  });

  test("auteur absent de l'invitation : à revoir", () => {
    const { invited_by: _omitted, ...withoutInviter } = INVITATION;
    const d = invitationOwnerDecision(withoutInviter, { owner_id: "o1", member_ids: ["o1"] });
    assert.equal(d.kind, "review");
  });

  test("groupe sans propriétaire lisible : à revoir", () => {
    for (const owner_id of [undefined, "", 7]) {
      const d = invitationOwnerDecision(INVITATION, { owner_id, member_ids: ["admin1"] });
      assert.equal(d.kind, "review", String(owner_id));
    }
  });

  test("identifiant de groupe absent ou avec « / » : à revoir", () => {
    for (const group_id of [undefined, "", "a/b", 3]) {
      const d = invitationOwnerDecision({ ...INVITATION, group_id }, { owner_id: "admin1" });
      assert.equal(d.kind, "review", String(group_id));
    }
  });
});

describe("summarizeInvitationOwner", () => {
  const base: BackfillInvitationOwnerResponse = {
    examinees: 3,
    posees: 2,
    dejaAJour: 1,
    sansGroupe: 0,
    echouees: 0,
    stoppedByDeadline: false,
    stoppedByBudget: false,
    stoppedByErrors: false,
    completed: true,
    aRevoir: { items: [], total: 0 },
  };

  test("parcours fini sans reste : terminé", () => {
    assert.deepEqual(summarizeInvitationOwner(base), {
      complete: true,
      remaining: 0,
      toReview: 0,
      spendCapHit: false,
      unresolved: 0,
    });
  });

  test("une invitation sans groupe reste à revoir", () => {
    const s = summarizeInvitationOwner({
      ...base,
      sansGroupe: 1,
      aRevoir: { items: [], total: 1 },
    });
    assert.equal(s.toReview, 1);
  });

  test("parcours interrompu : reste inconnu", () => {
    assert.equal(summarizeInvitationOwner({ ...base, completed: false }).remaining, null);
  });
});
