/**
 * Recherche d'un membre par adresse exacte : garde du propriétaire, lecture
 * de l'identifiant de groupe, correspondance stricte, comptes écartés, et
 * réponse sans adresse. Logique pure.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import {
  MEMBER_EMAIL_SEARCH_DAILY_LIMIT,
  MEMBER_EMAIL_SEARCH_MISS_ALERT,
  MEMBER_EMAIL_SEARCH_RETENTION_DAYS,
  findAccountByEmail,
  readGroupId,
  searchCounterExpiry,
  searcherDenial,
  shouldWarnMisses,
  unverifiedGroupRef,
} from "../invitations/memberSearch";
import { cleanEmail } from "../invitations/rules";
import { accessDenial } from "../callable/_auth";

const MARIE = {
  id: "uidMarie",
  data: {
    email: "marie.dupont@gmail.com",
    role: "reader",
    is_revoked: false,
    display_name: "Marie Dupont",
    preferred_name: "Mamie",
  },
};

describe("searcherDenial", () => {
  test("le propriétaire cherche", () => {
    assert.equal(searcherDenial({ owner_id: "o", member_ids: ["o"] }, "o"), null);
  });

  test("un membre qui n'est pas propriétaire est refusé", () => {
    const d = searcherDenial({ owner_id: "o", member_ids: ["o", "m"] }, "m");
    assert.equal(d?.code, "permission-denied");
  });

  test("un groupe absent est introuvable", () => {
    assert.equal(searcherDenial(null, "o")?.code, "not-found");
  });

  test("un owner_id illisible refuse", () => {
    assert.equal(searcherDenial({ owner_id: 3 }, "3")?.code, "permission-denied");
    assert.equal(searcherDenial({}, "o")?.code, "permission-denied");
  });
});

describe("garde de rôle de la callable (requireAuth, besoin « approved »)", () => {
  test("lecteur, éditeur, administrateur passent", () => {
    for (const role of ["reader", "editor", "admin"]) {
      assert.equal(accessDenial({ role, revoked: false }, "approved"), null);
    }
  });

  test("un compte en attente ou révoqué est refusé", () => {
    assert.notEqual(accessDenial({ role: "pending", revoked: false }, "approved"), null);
    assert.notEqual(accessDenial({ role: null, revoked: false }, "approved"), null);
    assert.notEqual(accessDenial({ role: "admin", revoked: true }, "approved"), null);
  });
});

describe("readGroupId", () => {
  test("un identifiant simple passe, espaces retirés", () => {
    assert.equal(readGroupId(" g1 "), "g1");
  });

  test("vide, chemin ou autre type : refusé", () => {
    assert.equal(readGroupId(""), null);
    assert.equal(readGroupId("a/b"), null);
    assert.equal(readGroupId(42), null);
    assert.equal(readGroupId("x".repeat(129)), null);
  });
});

describe("forme de l'adresse saisie", () => {
  test("espaces retirés et minuscules", () => {
    assert.equal(cleanEmail("  Marie.Dupont@Gmail.com "), "marie.dupont@gmail.com");
  });

  test("une saisie partielle ou piégée est refusée", () => {
    assert.equal(cleanEmail("marie"), null);
    assert.equal(cleanEmail("marie@gmail"), null);
    assert.equal(cleanEmail("a@b.c, d@e.f"), null);
    assert.equal(cleanEmail("ma rie@gmail.com"), null);
  });
});

describe("findAccountByEmail", () => {
  test("adresse exacte : le compte, sans adresse ni rôle dans la réponse", () => {
    const result = findAccountByEmail("marie.dupont@gmail.com", [MARIE]);
    assert.deepEqual(result, {
      found: true,
      uid: "uidMarie",
      displayName: "Marie Dupont",
      preferredName: "Mamie",
    });
    const text = JSON.stringify(result);
    assert.ok(!text.includes("@"), "la réponse ne contient aucune adresse");
    assert.ok(!text.includes("reader"), "la réponse ne contient pas le rôle");
  });

  test("l'adresse stockée avec des majuscules est retrouvée", () => {
    const stored = { ...MARIE, data: { ...MARIE.data, email: "Marie.Dupont@Gmail.com" } };
    assert.equal(findAccountByEmail("marie.dupont@gmail.com", [stored]).found, true);
  });

  test("correspondance stricte : ni points ni suffixe + ignorés", () => {
    assert.equal(findAccountByEmail("mariedupont@gmail.com", [MARIE]).found, false);
    assert.equal(findAccountByEmail("marie.dupont+x@gmail.com", [MARIE]).found, false);
    assert.equal(findAccountByEmail("marie.dupont@googlemail.com", [MARIE]).found, false);
  });

  test("une partie d'adresse ne trouve rien", () => {
    assert.equal(findAccountByEmail("dupont@gmail.com", [MARIE]).found, false);
  });

  test("un compte révoqué ou en attente répond comme une adresse inconnue", () => {
    const revoked = { ...MARIE, data: { ...MARIE.data, is_revoked: true } };
    const pending = { ...MARIE, data: { ...MARIE.data, role: "pending" } };
    const noRole = { ...MARIE, data: { ...MARIE.data, role: undefined } };
    for (const account of [revoked, pending, noRole]) {
      assert.deepEqual(findAccountByEmail("marie.dupont@gmail.com", [account]), { found: false });
    }
  });

  test("un document illisible est ignoré, la recherche continue", () => {
    const broken = { id: "x", data: undefined };
    const noEmail = { id: "y", data: { role: "reader" } };
    assert.equal(
      findAccountByEmail("marie.dupont@gmail.com", [broken, noEmail, MARIE]).found,
      true,
    );
  });

  test("sans nom préféré : null, nom Google tronqué comme le profil public", () => {
    const plain = {
      id: "u2",
      data: { email: "jean@example.com", role: "editor", display_name: "J".repeat(80) },
    };
    const result = findAccountByEmail("jean@example.com", [plain]);
    assert.equal(result.found, true);
    if (result.found) {
      assert.equal(result.preferredName, null);
      assert.equal(result.displayName.length, 60);
    }
  });
});

describe("plafond, alerte et conservation", () => {
  test("dix recherches par jour", () => {
    assert.equal(MEMBER_EMAIL_SEARCH_DAILY_LIMIT, 10);
  });

  test("l'avertissement part une fois, à la cinquième réponse vide", () => {
    assert.equal(MEMBER_EMAIL_SEARCH_MISS_ALERT, 5);
    assert.equal(shouldWarnMisses(4), false);
    assert.equal(shouldWarnMisses(5), true);
    assert.equal(shouldWarnMisses(6), false);
    assert.equal(shouldWarnMisses(10), false);
  });

  test("l'alerte se déclenche avant le plafond", () => {
    assert.ok(MEMBER_EMAIL_SEARCH_MISS_ALERT < MEMBER_EMAIL_SEARCH_DAILY_LIMIT);
  });

  test("le compteur expire trente jours après son écriture", () => {
    const at = new Date("2026-10-12T08:00:00Z");
    assert.equal(MEMBER_EMAIL_SEARCH_RETENTION_DAYS, 30);
    assert.equal(searchCounterExpiry(at).toISOString(), "2026-11-11T08:00:00.000Z");
  });

  test("un groupe non vérifié n'est porté que tronqué", () => {
    assert.equal(unverifiedGroupRef("g1"), "g1");
    assert.equal(unverifiedGroupRef("x".repeat(128)).length, 32);
  });
});
