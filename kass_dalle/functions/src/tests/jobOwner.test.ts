/**
 * Propriétaire d'un job d'import : relu à chaque tentative du pipeline, avec la
 * même décision que `requireEditor` (audit #151, ticket #163, point 3).
 * Logique pure.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import { OWNER_NOT_EDITOR_MESSAGE, jobOwnerDenial } from "../pipeline/jobOwner";

describe("jobOwnerDenial", () => {
  test("éditeur : accepté", () => {
    assert.equal(jobOwnerDenial({ role: "editor", revoked: false }), null);
  });

  test("administrateur, fondateur compris : accepté", () => {
    // Le fondateur porte `role: "admin"` sur son document (`founderRole.ts`).
    assert.equal(jobOwnerDenial({ role: "admin", revoked: false }), null);
  });

  test("éditeur révoqué : refusé", () => {
    assert.notEqual(jobOwnerDenial({ role: "editor", revoked: true }), null);
  });

  test("administrateur révoqué : refusé", () => {
    assert.notEqual(jobOwnerDenial({ role: "admin", revoked: true }), null);
  });

  test("lecteur : refusé", () => {
    assert.notEqual(jobOwnerDenial({ role: "reader", revoked: false }), null);
  });

  test("compte en attente : refusé", () => {
    assert.notEqual(jobOwnerDenial({ role: "pending", revoked: false }), null);
  });

  test("document absent : refusé", () => {
    assert.notEqual(jobOwnerDenial(null), null);
  });

  test("rôle absent ou inconnu : refusé", () => {
    assert.notEqual(jobOwnerDenial({ role: null, revoked: false }), null);
    assert.notEqual(jobOwnerDenial({ role: "superuser", revoked: false }), null);
  });
});

describe("OWNER_NOT_EDITOR_MESSAGE", () => {
  test("tient le libellé validé, repris en repli par la tuile du client", () => {
    assert.equal(
      OWNER_NOT_EDITOR_MESSAGE,
      "Import arrêté : votre compte n'a plus le droit d'importer des recettes. " +
        "Demandez à un administrateur de vous le rendre, puis importez de nouveau.",
    );
  });
});
