/**
 * Contraintes de variété par défaut : ce que le backfill écrit sur un compte.
 * Il ne doit jamais effacer ce qu'une personne a écrit, ni ajouter deux fois
 * le même bloc.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { mergedConstraints } from "../callable/planningDefaultsBackfillCallable";

const TEXT = "VARIÉTÉ SUR LA SEMAINE :\n- Protéine : jamais deux jours de suite.";

describe("contraintes de variété par défaut", () => {
  test("contraintes absentes : le texte est posé", () => {
    assert.equal(mergedConstraints(undefined, TEXT), TEXT);
  });
  test("contraintes vides ou blanches : le texte est posé", () => {
    assert.equal(mergedConstraints("", TEXT), TEXT);
    assert.equal(mergedConstraints("  \n ", TEXT), TEXT);
  });
  test("contraintes écrites : le texte s'ajoute à la suite, rien n'est effacé", () => {
    assert.equal(mergedConstraints("Pas de champignons.", TEXT), `Pas de champignons.\n\n${TEXT}`);
  });
  test("texte déjà présent : rien à écrire, un second passage ne double pas le bloc", () => {
    const once = mergedConstraints("Pas de champignons.", TEXT) as string;
    assert.equal(mergedConstraints(once, TEXT), null);
    assert.equal(mergedConstraints(TEXT, TEXT), null);
  });
  test("fusion trop longue pour la génération : rien n'est écrit", () => {
    assert.equal(mergedConstraints("x".repeat(40), TEXT, 60), "too_long");
    assert.equal(mergedConstraints("", "y".repeat(61), 60), "too_long");
  });
  test("valeur qui n'est pas un texte : traitée comme vide", () => {
    assert.equal(mergedConstraints(42, TEXT), TEXT);
  });
});
