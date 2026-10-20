/**
 * Claims posés par `syncUserClaims` : seuls les quatre rôles connus passent,
 * écrits à l'identique (audit #151, ticket #163).
 *
 * Un `"admin "` lu avec `trim` devenait administrateur dans le jeton alors que
 * `firestore.rules` le refusait : les deux sources ne disaient pas la même chose.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { claimsFrom } from "../triggers/userClaimsSync";
import { accountDocumentFrom, mergeAccount } from "../callable/_auth";
import { KNOWN_ROLES } from "../security/roles";

describe("claimsFrom — rôle", () => {
  test("les quatre rôles connus sont gardés tels quels", () => {
    for (const role of ["admin", "editor", "reader", "pending"]) {
      assert.deepEqual(claimsFrom({ role, is_revoked: false }), { role, revoked: false });
    }
  });

  test("un rôle inconnu donne role: null", () => {
    for (const role of ["superadmin", "owner", "Admin", "EDITOR", "", "  "]) {
      assert.equal(claimsFrom({ role }).role, null, JSON.stringify(role));
    }
  });

  test("un rôle entouré d'espaces n'est pas retaillé", () => {
    for (const role of ["admin ", " admin", " editor ", "reader\n", "\tpending"]) {
      assert.equal(claimsFrom({ role }).role, null, JSON.stringify(role));
    }
  });

  test("un rôle qui n'est pas une chaîne donne role: null", () => {
    for (const role of [null, 1, true, ["admin"], { role: "admin" }]) {
      assert.equal(claimsFrom({ role }).role, null, JSON.stringify(role));
    }
  });

  test("document absent : aucun rôle, non révoqué", () => {
    assert.deepEqual(claimsFrom(undefined), { role: null, revoked: false });
  });

  test("la révocation ne vaut que true, et ne dépend pas du rôle", () => {
    assert.equal(claimsFrom({ role: "superadmin", is_revoked: true }).revoked, true);
    assert.equal(claimsFrom({ role: "admin", is_revoked: "true" }).revoked, false);
  });
});

describe("readRole — même lecture pour le jeton et le document", () => {
  test("KNOWN_ROLES porte les quatre rôles de UserRole (Dart)", () => {
    assert.deepEqual([...KNOWN_ROLES].sort(), ["admin", "editor", "pending", "reader"]);
  });

  test("un document à rôle mal écrit ne laisse pas passer le claim du jeton", () => {
    // Le champ est présent : pas de repli sur le jeton, même valide.
    const merged = mergeAccount(
      { role: "admin", revoked: false },
      accountDocumentFrom({ role: "admin " }),
    );
    assert.equal(merged.role, null);
  });
});
