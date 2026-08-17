/**
 * Gardes des callables — le sas d'entrée, la révocation et le rôle.
 *
 * Ces vingt-sept entrées HTTPS dépensent de l'argent : chacune part chez Gemini
 * ou Anthropic. Elles n'étaient gardées que par la présence d'un compte Google,
 * si bien qu'un compte en attente d'approbation, ou un compte révoqué, les
 * atteignait aussi bien qu'un membre de la famille.
 *
 * La décision est portée par `accessDenial`, pure et donc testable sans
 * émulateur : c'est elle que ce fichier verrouille, avec la lecture des claims
 * et la règle du compte fondateur.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { accessDenial, accountFromToken, type AccountState } from "../callable/_auth";
import { founderRepair, isFounderEmail } from "../triggers/founderRole";

function account(role: string | null, revoked = false): AccountState {
  return { role, revoked };
}

describe("accessDenial — sas d'entrée", () => {
  test("un compte en attente est refusé partout", () => {
    for (const need of ["approved", "editor", "admin"] as const) {
      assert.notEqual(accessDenial(account("pending"), need), null, `need=${need}`);
    }
  });

  test("un compte sans rôle du tout est refusé — le repli ferme", () => {
    assert.notEqual(accessDenial(account(null), "approved"), null);
  });

  test("un rôle inconnu ne vaut pas lecteur", () => {
    assert.notEqual(accessDenial(account("superadmin"), "approved"), null);
  });

  test("un lecteur passe le sas mais n'écrit pas", () => {
    assert.equal(accessDenial(account("reader"), "approved"), null);
    assert.notEqual(accessDenial(account("reader"), "editor"), null);
    assert.notEqual(accessDenial(account("reader"), "admin"), null);
  });

  test("un éditeur écrit sans être administrateur", () => {
    assert.equal(accessDenial(account("editor"), "approved"), null);
    assert.equal(accessDenial(account("editor"), "editor"), null);
    assert.notEqual(accessDenial(account("editor"), "admin"), null);
  });

  test("un administrateur passe les trois portes", () => {
    for (const need of ["approved", "editor", "admin"] as const) {
      assert.equal(accessDenial(account("admin"), need), null, `need=${need}`);
    }
  });
});

describe("accessDenial — révocation", () => {
  test("la révocation mord sur tous les rôles, administrateur compris", () => {
    for (const role of ["reader", "editor", "admin"]) {
      for (const need of ["approved", "editor", "admin"] as const) {
        assert.notEqual(accessDenial(account(role, true), need), null, `role=${role} need=${need}`);
      }
    }
  });

  test("le message de révocation ne se confond pas avec celui de l'attente", () => {
    const revoked = accessDenial(account("admin", true), "approved");
    const pending = accessDenial(account("pending"), "approved");
    assert.notEqual(revoked, null);
    assert.notEqual(pending, null);
    assert.notEqual(revoked?.message, pending?.message);
  });
});

describe("accountFromToken", () => {
  test("un jeton sans claim de rôle rend null, pas une chaîne vide", () => {
    assert.deepEqual(accountFromToken({ auth: { uid: "u1", token: {} } } as never), {
      role: null,
      revoked: false,
    });
  });

  test("un claim vide ou blanc vaut absent", () => {
    assert.equal(
      accountFromToken({ auth: { uid: "u1", token: { role: "  " } } } as never).role,
      null,
    );
  });

  test("le claim de révocation n'est vrai que s'il vaut exactement true", () => {
    assert.equal(
      accountFromToken({ auth: { uid: "u1", token: { revoked: "true" } } } as never).revoked,
      false,
    );
    assert.equal(
      accountFromToken({ auth: { uid: "u1", token: { revoked: true } } } as never).revoked,
      true,
    );
  });

  test("un rôle porté par le jeton est lu tel quel, espaces retirés", () => {
    assert.equal(
      accountFromToken({ auth: { uid: "u1", token: { role: " editor " } } } as never).role,
      "editor",
    );
  });
});

describe("compte fondateur", () => {
  test("l'adresse se reconnaît quelle que soit la casse", () => {
    assert.equal(isFounderEmail("china.fred.75@gmail.com"), true);
    assert.equal(isFounderEmail("CHINA.FRED.75@Gmail.com"), true);
    assert.equal(isFounderEmail("  china.fred.75@gmail.com  "), true);
  });

  test("une adresse voisine n'est pas le fondateur", () => {
    assert.equal(isFounderEmail("china.fred.75@gmail.com.attaquant.fr"), false);
    assert.equal(isFounderEmail("chinafred75@gmail.com"), false);
    assert.equal(isFounderEmail(null), false);
    assert.equal(isFounderEmail(undefined), false);
  });

  test("un fondateur déjà administrateur et actif n'est pas réécrit", () => {
    assert.equal(founderRepair({ role: "admin", is_revoked: false }), null);
    assert.equal(founderRepair({ role: "admin" }), null);
  });

  test("un fondateur rabaissé ou révoqué est rétabli", () => {
    assert.deepEqual(founderRepair({ role: "pending", is_revoked: false }), {
      role: "admin",
      is_revoked: false,
    });
    assert.deepEqual(founderRepair({ role: "admin", is_revoked: true }), {
      role: "admin",
      is_revoked: false,
    });
  });
});
