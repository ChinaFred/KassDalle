/**
 * Bornes des entrées envoyées aux modèles par les callables.
 *
 * Verrouille les limites exactes (la borne passe, un caractère de plus est
 * refusé), le refus d'un type invalide, la règle absent / requis, le base64
 * mal formé, et la forme du relevé « Taille des entrées IA ».
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { HttpsError } from "firebase-functions/v2/https";

import {
  AiInputSizes,
  COVER_IMAGE_MAX_BYTES,
  INPUT_SIZES_LOG_MESSAGE,
  InputBoundExceededError,
  LIST_MAX_ITEMS,
  PASTED_TEXT_MAX_CHARS,
  RECIPE_TEXT_MAX_CHARS,
  SHORT_TEXT_MAX_CHARS,
  decodedBase64Length,
  formatCount,
  readAiInputs,
  requireBoundedBase64,
  requireBoundedList,
  requireBoundedObject,
  requireBoundedText,
  type InputSizesLogger,
} from "../callable/_inputBounds";

function assertInvalid(fn: () => unknown, pattern: RegExp, bound = false): void {
  assert.throws(fn, (err: unknown) => {
    assert.ok(err instanceof HttpsError, "HttpsError attendue");
    assert.equal(err.code, "invalid-argument");
    assert.match(err.message, pattern);
    assert.equal(err instanceof InputBoundExceededError, bound);
    return true;
  });
}

describe("bornes — valeurs décidées", () => {
  test("bornes larges de la v0.23.11", () => {
    assert.equal(PASTED_TEXT_MAX_CHARS, 200_000);
    assert.equal(RECIPE_TEXT_MAX_CHARS, 100_000);
    assert.equal(SHORT_TEXT_MAX_CHARS, 5_000);
    assert.equal(LIST_MAX_ITEMS, 500);
    assert.equal(COVER_IMAGE_MAX_BYTES, 8 * 1024 * 1024);
  });

  test("formatCount groupe par milliers", () => {
    assert.equal(formatCount(200_000), "200 000");
    assert.equal(formatCount(5_000), "5 000");
    assert.equal(formatCount(42), "42");
  });
});

describe("requireBoundedText", () => {
  test("la limite exacte passe, un caractère de plus est refusé", () => {
    const opts = { field: "text", max: 10 };
    assert.equal(requireBoundedText("x".repeat(10), opts), "x".repeat(10));
    assertInvalid(
      () => requireBoundedText("x".repeat(11), opts),
      /« text » dépasse la limite de 10 caractères \(11 reçus\)/,
      true,
    );
  });

  test("le refus porte le champ, la taille et la borne", () => {
    try {
      requireBoundedText("x".repeat(PASTED_TEXT_MAX_CHARS + 1), {
        field: "text",
        max: PASTED_TEXT_MAX_CHARS,
      });
      assert.fail("refus attendu");
    } catch (err) {
      assert.ok(err instanceof InputBoundExceededError);
      assert.equal(err.field, "text");
      assert.equal(err.size, PASTED_TEXT_MAX_CHARS + 1);
      assert.equal(err.max, PASTED_TEXT_MAX_CHARS);
      assert.equal(err.unit, "chars");
      assert.match(err.message, /200 000 caractères/);
    }
  });

  test("un type invalide est refusé", () => {
    assertInvalid(() => requireBoundedText(42, { field: "query", max: 10 }), /doit être un texte/);
    assertInvalid(
      () => requireBoundedText({ a: 1 }, { field: "query", max: 10, required: true }),
      /« query » doit être un texte/,
    );
  });

  test("requis : absent, null ou vide est refusé", () => {
    for (const value of [undefined, null, ""]) {
      assertInvalid(
        () => requireBoundedText(value, { field: "query", max: 10, required: true }),
        /« query » est requis/,
      );
    }
  });

  test("facultatif : absent rend undefined, vide est rendu tel quel", () => {
    assert.equal(requireBoundedText(undefined, { field: "x", max: 10 }), undefined);
    assert.equal(requireBoundedText(null, { field: "x", max: 10 }), undefined);
    assert.equal(requireBoundedText("", { field: "x", max: 10 }), "");
  });

  test("aucune troncature : le texte accepté est rendu intact", () => {
    const text = "é".repeat(500);
    assert.equal(requireBoundedText(text, { field: "x", max: 500 }), text);
  });
});

describe("requireBoundedList", () => {
  test("la limite exacte passe, un élément de plus est refusé", () => {
    const opts = { field: "ingredients", maxItems: 3 };
    assert.deepEqual(requireBoundedList([1, 2, 3], opts), [1, 2, 3]);
    assertInvalid(
      () => requireBoundedList([1, 2, 3, 4], opts),
      /« ingredients » dépasse la limite de 3 éléments \(4 reçus\)/,
      true,
    );
  });

  test("un élément trop long est refusé, avec son index", () => {
    const opts = { field: "titles", maxItems: 10, maxItemChars: 5 };
    assert.deepEqual(requireBoundedList(["abcde"], opts), ["abcde"]);
    assertInvalid(
      () => requireBoundedList(["ok", "abcdef"], opts),
      /« titles\[1\] » dépasse la limite de 5 caractères \(6 reçus\)/,
      true,
    );
  });

  test("un objet est mesuré par son JSON", () => {
    const item = { name: "farine" }; // {"name":"farine"} = 17 caractères
    const opts = { field: "ingredients", maxItems: 10, maxItemChars: 17 };
    assert.equal(requireBoundedList([item], opts)?.length, 1);
    assertInvalid(
      () => requireBoundedList([item], { ...opts, maxItemChars: 16 }),
      /ingredients\[0\]/,
      true,
    );
  });

  test("un type invalide est refusé", () => {
    assertInvalid(
      () => requireBoundedList("pas une liste", { field: "recipes", maxItems: 10 }),
      /« recipes » doit être une liste/,
    );
  });

  test("requis : absent est refusé, vide est accepté", () => {
    assertInvalid(
      () => requireBoundedList(undefined, { field: "slotDates", maxItems: 10, required: true }),
      /« slotDates » est requis/,
    );
    assert.deepEqual(
      requireBoundedList([], { field: "slotDates", maxItems: 10, required: true }),
      [],
    );
    assert.equal(requireBoundedList(null, { field: "x", maxItems: 10 }), undefined);
  });
});

describe("requireBoundedObject", () => {
  test("mesuré en JSON, limite exacte", () => {
    const value = { a: "b" }; // {"a":"b"} = 9 caractères
    assert.deepEqual(requireBoundedObject(value, { field: "tags", maxChars: 9 }), value);
    assertInvalid(
      () => requireBoundedObject(value, { field: "tags", maxChars: 8 }),
      /« tags » dépasse la limite de 8 caractères \(9 reçus\)/,
      true,
    );
  });

  test("une liste ou un texte n'est pas un objet", () => {
    assertInvalid(() => requireBoundedObject([], { field: "tags", maxChars: 9 }), /un objet/);
    assertInvalid(() => requireBoundedObject("x", { field: "tags", maxChars: 9 }), /un objet/);
  });

  test("requis : absent est refusé", () => {
    assertInvalid(
      () => requireBoundedObject(undefined, { field: "tags", maxChars: 9, required: true }),
      /est requis/,
    );
  });
});

describe("requireBoundedBase64", () => {
  test("taille décodée calculée sans décoder", () => {
    for (const bytes of [0, 1, 2, 3, 4, 5, 100]) {
      const b64 = Buffer.alloc(bytes, 7).toString("base64");
      assert.equal(decodedBase64Length(b64), bytes, `bytes=${bytes}`);
      // Sans remplissage, la taille reste juste.
      assert.equal(decodedBase64Length(b64.replace(/=+$/, "")), bytes, `bytes=${bytes} brut`);
    }
  });

  test("la limite exacte passe, un octet de plus est refusé", () => {
    const opts = { field: "bytesBase64", maxBytes: 6 };
    const ok = Buffer.from("abcdef").toString("base64");
    assert.equal(requireBoundedBase64(ok, opts)?.toString(), "abcdef");
    const tooBig = Buffer.from("abcdefg").toString("base64");
    assertInvalid(() => requireBoundedBase64(tooBig, opts), /« bytesBase64 » dépasse/, true);
  });

  test("la borne de couverture s'exprime en Mo", () => {
    const b64 = "A".repeat(Math.ceil(((COVER_IMAGE_MAX_BYTES + 3) * 4) / 3 / 4) * 4);
    assertInvalid(
      () => requireBoundedBase64(b64, { field: "bytesBase64", maxBytes: COVER_IMAGE_MAX_BYTES }),
      /limite de 8 Mo \(8 Mo reçus\)|limite de 8 Mo \(8,0 Mo reçus\)/,
      true,
    );
  });

  test("un base64 invalide est refusé", () => {
    for (const bad of ["@@@@", "abc def=", "A===", "abcde", "QQ=A"]) {
      assertInvalid(
        () => requireBoundedBase64(bad, { field: "bytesBase64", maxBytes: 100 }),
        /n'est pas un encodage base64 valide/,
      );
    }
  });

  test("type invalide, absent et requis", () => {
    assertInvalid(
      () => requireBoundedBase64(12, { field: "bytesBase64", maxBytes: 100 }),
      /doit être un texte base64/,
    );
    for (const value of [undefined, null, ""]) {
      assertInvalid(
        () => requireBoundedBase64(value, { field: "bytesBase64", maxBytes: 100, required: true }),
        /est requis/,
      );
    }
    assert.equal(requireBoundedBase64(undefined, { field: "b", maxBytes: 100 }), undefined);
  });
});

describe("AiInputSizes et readAiInputs — relevé des tailles", () => {
  type Logged = { level: "info" | "warn"; entry: Record<string, unknown> };

  function recorder(): { logger: InputSizesLogger; logged: Logged[] } {
    const logged: Logged[] = [];
    const logger = {
      info: async (entry: unknown) => {
        logged.push({ level: "info", entry: entry as Record<string, unknown> });
      },
      warn: async (entry: unknown) => {
        logged.push({ level: "warn", entry: entry as Record<string, unknown> });
      },
    } as unknown as InputSizesLogger;
    return { logger, logged };
  }

  const scope = { feature: "refine", userId: "u1", correlationId: "c1" };

  test("accepté : un logInfo avec les tailles, jamais le contenu", async () => {
    const { logger, logged } = recorder();
    const out = await readAiInputs(
      scope,
      (inputs) => ({
        text: inputs.text("secret", { field: "instruction", max: 100, required: true }),
        list: inputs.list(["ab", "c"], { field: "titles", maxItems: 10 }),
        image: inputs.base64(Buffer.from("abc").toString("base64"), {
          field: "bytesBase64",
          maxBytes: 10,
        }),
        absent: inputs.text(undefined, { field: "style", max: 10 }),
      }),
      logger,
    );
    assert.equal(out.text, "secret");
    assert.equal(logged.length, 1);
    assert.equal(logged[0].level, "info");
    assert.equal(logged[0].entry.message, INPUT_SIZES_LOG_MESSAGE);
    assert.equal(logged[0].entry.feature, "refine");
    assert.deepEqual(logged[0].entry.extra, {
      feature: "refine",
      sizes: { instruction: 6, titles: 2, titles_chars: 3, bytesBase64: 3 },
    });
    assert.ok(!JSON.stringify(logged).includes("secret"), "le contenu ne part pas au journal");
  });

  test("dépassement : un logWarn de même forme, puis l'erreur repart", async () => {
    const { logger, logged } = recorder();
    await assert.rejects(
      readAiInputs(
        scope,
        (inputs) => {
          inputs.text("abc", { field: "instruction", max: 10 });
          inputs.text("x".repeat(12), { field: "currentCooklang", max: 10 });
        },
        logger,
      ),
      InputBoundExceededError,
    );
    assert.equal(logged.length, 1);
    assert.equal(logged[0].level, "warn");
    assert.equal(logged[0].entry.message, INPUT_SIZES_LOG_MESSAGE);
    assert.deepEqual(logged[0].entry.extra, {
      feature: "refine",
      sizes: { instruction: 3, currentCooklang: 12 },
      refused: { field: "currentCooklang", size: 12, max: 10, unit: "chars" },
    });
  });

  test("champ absent ou mal typé : refusé sans journal", async () => {
    const { logger, logged } = recorder();
    await assert.rejects(
      readAiInputs(
        scope,
        (inputs) => inputs.text(undefined, { field: "instruction", max: 10, required: true }),
        logger,
      ),
      HttpsError,
    );
    assert.equal(logged.length, 0);
  });

  test("measure relève une taille sans borne", () => {
    const inputs = new AiInputSizes();
    inputs.measure("prompt", 1234);
    assert.deepEqual(inputs.sizes, { prompt: 1234 });
  });
});
