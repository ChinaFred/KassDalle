/**
 * Lecture d'une réponse JSON de modèle.
 *
 * Cinq extractions différentes cohabitaient dans `nutrition/aiEnrichment.ts` :
 * `\{[\s\S]*?\}` par endroits, `\{[\s\S]*\}` ailleurs. La première s'arrête au
 * premier `}` rencontré — elle tronque donc tout objet imbriqué, ce qui est
 * exactement la forme que renvoient les postes d'enrichissement. L'écart ne
 * casse rien tant que le modèle répond sèchement ; il se voit le jour où il
 * enrobe sa réponse.
 *
 * Ces cas fixent le comportement attendu de l'unique extraction restante.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { extractJsonObject } from "../ai/askJson";

describe("extractJsonObject", () => {
  test("une réponse déjà propre est rendue telle quelle", () => {
    assert.equal(extractJsonObject('{"a":1}'), '{"a":1}');
  });

  test("une phrase d'introduction est écartée", () => {
    assert.equal(extractJsonObject('Voici le résultat :\n{"a":1}'), '{"a":1}');
  });

  test("un bloc de code Markdown est déballé", () => {
    assert.equal(extractJsonObject('```json\n{"a":1}\n```'), '{"a":1}');
  });

  test("un bloc de code sans langue est déballé aussi", () => {
    assert.equal(extractJsonObject('```\n{"a":1}\n```'), '{"a":1}');
  });

  test("un objet imbriqué n'est pas tronqué au premier accolade fermante", () => {
    // Le cas que l'ancienne regex non gourmande cassait : elle rendait
    // `{"weights":[{"id":"0","grams":1}` — du JSON invalide.
    const raw = '{"weights":[{"id":"0","grams":1},{"id":"1","grams":2}]}';
    assert.equal(extractJsonObject(raw), raw);
  });

  test("le commentaire qui suit le JSON est écarté", () => {
    assert.equal(
      extractJsonObject('{"a":{"b":1}}\n\nJ\'espère que cela convient.'),
      '{"a":{"b":1}}',
    );
  });

  test("une réponse sans accolade ne rend rien", () => {
    assert.equal(extractJsonObject("désolé, je ne peux pas répondre"), null);
  });

  test("une réponse vide ne rend rien", () => {
    assert.equal(extractJsonObject("   "), null);
  });

  test("une accolade ouvrante seule ne rend rien", () => {
    assert.equal(extractJsonObject('{"a":1'), null);
  });

  test("le résultat est toujours du JSON analysable quand il n'est pas nul", () => {
    const cas = [
      '{"a":1}',
      'blabla {"a":{"b":[1,2,3]}} blabla',
      '```json\n{"ingredients":[{"id":"0","consomme":true}]}\n```',
    ];
    for (const raw of cas) {
      const extracted = extractJsonObject(raw);
      assert.notEqual(extracted, null, `extraction nulle pour ${raw}`);
      assert.doesNotThrow(() => JSON.parse(extracted as string), `JSON invalide pour ${raw}`);
    }
  });
});
