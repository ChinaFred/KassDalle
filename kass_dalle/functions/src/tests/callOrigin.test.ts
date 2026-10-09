/**
 * Origine d'un appel d'IA : le marqueur posé par la garde d'une callable suit
 * la requête jusqu'à l'appel de modèle, et n'existe pas ailleurs.
 */

import { describe, test } from "node:test";
import assert from "node:assert/strict";

import { isInteractiveCall, markInteractiveCall, runAsInteractive } from "../ai/callOrigin";

const tick = () => new Promise<void>((resolve) => setTimeout(resolve, 1));

/** Forme d'une garde : marque de façon synchrone, puis attend (App Check, Firestore). */
async function guard(): Promise<{ userId: string }> {
  markInteractiveCall();
  await tick();
  return { userId: "u1" };
}

/** Forme d'un appel de modèle profond, qui reconstruit son contexte. */
async function deepModelCall(): Promise<boolean> {
  await tick();
  return Promise.resolve().then(() => isInteractiveCall());
}

describe("callOrigin", () => {
  test("hors requête d'utilisateur : appel du serveur", async () => {
    assert.equal(await deepModelCall(), false);
  });

  test("le marqueur de la garde vaut pour la suite du traitement", async () => {
    // Un contexte neuf par requête, comme le serveur HTTP en donne un.
    const seen = await runInIsolatedContext(async () => {
      await guard();
      return deepModelCall();
    });
    assert.equal(seen, true);
  });

  test("il ne fuit pas vers un traitement voisin (déclencheur)", async () => {
    const [callable, trigger] = await Promise.all([
      runInIsolatedContext(async () => {
        await guard();
        await tick();
        return deepModelCall();
      }),
      runInIsolatedContext(async () => {
        await tick();
        return deepModelCall();
      }),
    ]);
    assert.equal(callable, true);
    assert.equal(trigger, false);
  });

  test("runAsInteractive", async () => {
    assert.equal(await runAsInteractive(() => deepModelCall()), true);
  });
});

/** Lance `fn` dans un contexte asynchrone séparé, sans marqueur hérité. */
function runInIsolatedContext<T>(fn: () => Promise<T>): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    setImmediate(() => {
      fn().then(resolve, reject);
    });
  });
}
