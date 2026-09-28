/**
 * Écriture de la politique de routage : la carte par poste s'efface vraiment.
 *
 * `set(..., {merge: true})` ne fusionne pas les clés d'une carte imbriquée
 * fournie dans l'écriture : redonner la carte ENTIÈRE sans une clé ne
 * l'efface pas, elle survit. Constaté le 28 septembre 2026 sur
 * `anthropic_models.transcription_page`, journal de diagnostic à l'appui —
 * voir le commentaire d'`applyMapDiff`. Cette suite verrouille le
 * comportement corrigé : chaque clé s'écrit par son propre chemin, et une
 * clé retirée du brouillon porte un `FieldValue.delete()` explicite.
 *
 * Logique pure : `applyMapDiff` ne connaît pas Firestore, seulement les objets
 * qu'on lui donne. Le test se contente donc de vérifier la présence du
 * marqueur de suppression, pas son effet réel — celui-ci est du ressort de
 * Firestore, hors de portée d'un test unitaire.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { FieldValue } from "firebase-admin/firestore";

import { applyMapDiff } from "../callable/aiRoutingCallable";

describe("applyMapDiff", () => {
  test("une clé retirée du brouillon porte un FieldValue.delete()", () => {
    const target: Record<string, unknown> = {};
    applyMapDiff(
      target,
      "anthropic_models",
      { sandbox_detect_page: "claude-opus-5" },
      { sandbox_detect_page: "claude-opus-5", transcription_page: "claude-opus-5" },
    );
    assert.equal(target["anthropic_models.sandbox_detect_page"], "claude-opus-5");
    assert.ok(target["anthropic_models.transcription_page"] instanceof FieldValue);
  });

  test("une clé qui reste ne porte pas de suppression", () => {
    const target: Record<string, unknown> = {};
    applyMapDiff(target, "anthropic_efforts", { recipe_tagging: "low" }, { recipe_tagging: "low" });
    assert.equal(target["anthropic_efforts.recipe_tagging"], "low");
    assert.equal(Object.keys(target).length, 1);
  });

  test("une carte vide au départ n'écrit que les clés ajoutées", () => {
    const target: Record<string, unknown> = {};
    applyMapDiff(target, "anthropic_efforts", { transcription_page: "high" }, undefined);
    assert.deepEqual(target, { "anthropic_efforts.transcription_page": "high" });
  });

  test("toutes les clés retirées ne laissent que des suppressions", () => {
    const target: Record<string, unknown> = {};
    applyMapDiff(target, "anthropic_models", {}, { transcription_page: "claude-opus-5" });
    assert.equal(Object.keys(target).length, 1);
    assert.ok(target["anthropic_models.transcription_page"] instanceof FieldValue);
  });

  test("jamais le champ entier : seulement des chemins à points", () => {
    // Écrire à la fois `champ` et `champ.clé` dans le même appel serait
    // refusé par Firestore — un chemin ne peut pas être le préfixe d'un
    // autre dans la même écriture. Ce test verrouille l'absence du champ nu.
    const target: Record<string, unknown> = {};
    applyMapDiff(target, "anthropic_models", { transcription_page: "claude-sonnet-5" }, {});
    assert.equal(target["anthropic_models"], undefined);
    assert.equal(target["anthropic_models.transcription_page"], "claude-sonnet-5");
  });
});
