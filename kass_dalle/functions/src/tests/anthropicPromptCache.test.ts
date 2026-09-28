/**
 * Marquage `cache_control` d'un fragment vers Claude.
 *
 * Logique pure : `toAnthropicContent` ne fait aucun appel réseau. Elle décide
 * seulement quel bloc porte `cache_control`, d'après `part.cache` — voir
 * `textPart` et son option, posée sur `TRANSCRIPTION_PROMPT` et
 * `TAGGING_PROMPT` depuis le 28 septembre 2026.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { toAnthropicContent } from "../ai/anthropic";
import { textPart, imagePart } from "../ai/types";

describe("toAnthropicContent — marquage du cache", () => {
  test("un fragment marqué porte cache_control ephemeral", () => {
    const [block] = toAnthropicContent([textPart("prompt fixe", { cache: true })]);
    assert.deepEqual((block as { cache_control?: unknown }).cache_control, { type: "ephemeral" });
  });

  test("un fragment non marqué ne porte pas cache_control", () => {
    const [block] = toAnthropicContent([textPart("texte variable")]);
    assert.equal((block as { cache_control?: unknown }).cache_control, undefined);
  });

  test("seul le fragment marqué porte cache_control, pas ses voisins", () => {
    const [prompt, variable] = toAnthropicContent([
      textPart("prompt fixe", { cache: true }),
      textPart("texte variable"),
    ]);
    assert.deepEqual((prompt as { cache_control?: unknown }).cache_control, { type: "ephemeral" });
    assert.equal((variable as { cache_control?: unknown }).cache_control, undefined);
  });

  test("une image sans marque ne porte pas cache_control", () => {
    const [block] = toAnthropicContent([imagePart("image/jpeg", "AAA")]);
    assert.equal((block as { cache_control?: unknown }).cache_control, undefined);
  });

  test("le marquage n'est pas propre au texte : une image marquée le porte aussi", () => {
    // `imagePart` n'expose pas encore l'option — aucun appelant n'en a besoin
    // aujourd'hui — mais `toAnthropicContent` lit `part.cache` pour les trois
    // natures de fragment, pas seulement le texte.
    const [block] = toAnthropicContent([
      { kind: "image", mimeType: "image/jpeg", dataBase64: "AAA", cache: true },
    ]);
    assert.deepEqual((block as { cache_control?: unknown }).cache_control, { type: "ephemeral" });
  });
});
