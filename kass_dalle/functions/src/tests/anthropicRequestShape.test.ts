/**
 * Forme d'une requête Claude : raisonnement, effort et schéma de sortie.
 *
 * Logique pure (`requestShapeFor`, `toStrictJsonSchema`), sans réseau. Le
 * 21 octobre 2026, deux paramètres refusés par l'API faisaient échouer 100 %
 * des appels concernés : `thinking: adaptive` et `effort` sur Haiku 4.5, et un
 * schéma sans `additionalProperties: false` sur `planning_constraints`.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { requestShapeFor, toStrictJsonSchema } from "../ai/anthropic";

describe("requestShapeFor", () => {
  test("Haiku 4.5 part sans raisonnement ni effort", () => {
    assert.deepEqual(requestShapeFor("claude-haiku-4-5"), {
      thinking: null,
      effort: null,
      droppedEffort: null,
    });
  });

  test("Haiku 4.5 : un effort demandé n'est pas transmis, et il est signalé", () => {
    assert.deepEqual(requestShapeFor("claude-haiku-4-5", "high"), {
      thinking: null,
      effort: null,
      droppedEffort: "high",
    });
  });

  test("un identifiant daté de Haiku 4.5 désigne le même modèle", () => {
    assert.equal(requestShapeFor("claude-haiku-4-5-20251001", "low").thinking, null);
    assert.equal(requestShapeFor(" Claude-Haiku-4-5 ", "low").effort, null);
  });

  test("Sonnet 5 et Opus 5 gardent le raisonnement adaptatif et l'effort", () => {
    assert.deepEqual(requestShapeFor("claude-sonnet-5", "high"), {
      thinking: { type: "adaptive" },
      effort: "high",
      droppedEffort: null,
    });
    assert.deepEqual(requestShapeFor("claude-opus-5", "medium"), {
      thinking: { type: "adaptive" },
      effort: "medium",
      droppedEffort: null,
    });
  });

  test("sans effort demandé, l'effort envoyé est low", () => {
    assert.equal(requestShapeFor("claude-sonnet-5").effort, "low");
  });

  test("un préfixe proche n'est pas Haiku 4.5", () => {
    assert.deepEqual(requestShapeFor("claude-haiku-4-50", "low").thinking, { type: "adaptive" });
  });
});

describe("toStrictJsonSchema", () => {
  // Le schéma de `planning_constraints` tel qu'il était le 21 octobre 2026.
  const constraints = {
    type: "object",
    properties: {
      textes: {
        type: "array",
        items: {
          type: "object",
          properties: {
            index: { type: "integer" },
            allergenes_exclus: { type: "array", items: { type: "string" } },
            non_traduit: { type: "string" },
          },
          required: ["index", "non_traduit"],
        },
      },
    },
    required: ["textes"],
  };

  test("chaque objet reçoit additionalProperties: false, à tous les niveaux", () => {
    const strict = toStrictJsonSchema(constraints) as {
      additionalProperties?: unknown;
      properties: { textes: { items: { additionalProperties?: unknown } } };
    };
    assert.equal(strict.additionalProperties, false);
    assert.equal(strict.properties.textes.items.additionalProperties, false);
  });

  test("le schéma d'origine n'est pas modifié", () => {
    const before = JSON.stringify(constraints);
    toStrictJsonSchema(constraints);
    assert.equal(JSON.stringify(constraints), before);
  });

  test("un schéma déjà strict ressort identique, ordre des clés compris", () => {
    const already = {
      type: "object",
      properties: {
        ingredients: {
          type: "array",
          items: {
            type: "object",
            properties: { id: { type: "string" } },
            required: ["id"],
            additionalProperties: false,
          },
        },
      },
      required: ["ingredients"],
      additionalProperties: false,
    };
    assert.equal(JSON.stringify(toStrictJsonSchema(already)), JSON.stringify(already));
  });

  test("les types qui ne sont pas des objets ne reçoivent rien", () => {
    const strict = toStrictJsonSchema({
      type: "object",
      properties: { tags: { type: "array", items: { type: "string", enum: ["a", "b"] } } },
    }) as { properties: { tags: Record<string, unknown> & { items: Record<string, unknown> } } };
    assert.equal("additionalProperties" in strict.properties.tags, false);
    assert.equal("additionalProperties" in strict.properties.tags.items, false);
    assert.deepEqual(strict.properties.tags.items.enum, ["a", "b"]);
  });

  test("un champ nommé « properties » ou « type » n'est pas pris pour un mot-clé", () => {
    const strict = toStrictJsonSchema({
      type: "object",
      properties: {
        properties: { type: "string" },
        type: { type: "string" },
      },
    }) as { properties: Record<string, Record<string, unknown>> };
    assert.equal("additionalProperties" in strict.properties.properties, false);
    assert.equal("additionalProperties" in strict.properties.type, false);
  });

  test("anyOf, type nullable et $defs sont parcourus", () => {
    const strict = toStrictJsonSchema({
      type: "object",
      properties: {
        choix: { anyOf: [{ type: "object", properties: { a: { type: "string" } } }] },
        detail: { type: ["object", "null"], properties: { b: { type: "number" } } },
      },
      $defs: { item: { type: "object", properties: { c: { type: "string" } } } },
    }) as {
      properties: {
        choix: { anyOf: Array<Record<string, unknown>> };
        detail: Record<string, unknown>;
      };
      $defs: { item: Record<string, unknown> };
    };
    assert.equal(strict.properties.choix.anyOf[0].additionalProperties, false);
    assert.equal(strict.properties.detail.additionalProperties, false);
    assert.equal(strict.$defs.item.additionalProperties, false);
  });

  test("une valeur explicite est gardée", () => {
    const strict = toStrictJsonSchema({
      type: "object",
      properties: {},
      additionalProperties: { type: "number" },
    });
    assert.deepEqual(strict.additionalProperties, { type: "number" });
  });
});
