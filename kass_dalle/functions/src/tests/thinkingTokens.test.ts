/**
 * Jetons de raisonnement.
 *
 * Gemini 2.5 Flash raisonne par défaut. Ces jetons ne figurent ni dans la
 * réponse ni dans `candidatesTokenCount`, mais Google les facture au tarif de
 * sortie — huit fois l'entrée. Les ignorer ne casse aucun écran : cela divise
 * le coût affiché par le rapport entre le raisonnement et le texte produit, et
 * l'écran continue d'afficher un chiffre plausible.
 *
 * Logique pure : ni SDK, ni réseau.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { thinkingTokensOf } from "../gemini/client";
import { estimateAiCostUsd } from "../ai/pricing";

describe("thinkingTokensOf", () => {
  test("le champ dédié fait foi quand il est présent", () => {
    assert.equal(
      thinkingTokensOf({
        promptTokenCount: 1000,
        candidatesTokenCount: 200,
        thoughtsTokenCount: 1800,
        totalTokenCount: 3000,
      }),
      1800,
    );
  });

  test("à défaut, le total trahit le raisonnement", () => {
    // Ce que le total compte en plus de l'entrée et de la sortie ne peut être
    // que du raisonnement. Ce repli couvre une version du SDK qui ne remonte
    // pas encore le champ — sans lui, une montée de version silencieuse
    // ferait réapparaître le sous-comptage.
    assert.equal(
      thinkingTokensOf({
        promptTokenCount: 1000,
        candidatesTokenCount: 200,
        totalTokenCount: 3000,
      }),
      1800,
    );
  });

  test("un appel sans raisonnement n'en invente pas", () => {
    assert.equal(
      thinkingTokensOf({
        promptTokenCount: 1000,
        candidatesTokenCount: 200,
        totalTokenCount: 1200,
      }),
      0,
    );
  });

  test("un total incohérent ne produit jamais de négatif", () => {
    // Un total absent ou tronqué donnerait un raisonnement négatif, qui
    // viendrait en déduction du coût.
    assert.equal(
      thinkingTokensOf({ promptTokenCount: 1000, candidatesTokenCount: 200 }),
      0,
    );
    assert.equal(thinkingTokensOf(undefined), 0);
  });

  test("l'usage absent de métadonnées ne fait pas échouer la lecture", () => {
    assert.equal(thinkingTokensOf({}), 0);
  });
});

describe("le raisonnement est facturé au tarif de sortie", () => {
  test("l'ignorer divise le coût d'un appel qui réfléchit", () => {
    // Un appel typique d'extraction : 1 000 jetons d'entrée, 200 de texte
    // rendu, 1 800 de raisonnement.
    const compte = estimateAiCostUsd({
      model: "gemini-2.5-flash",
      inputTokens: 1000,
      outputTokens: 200 + 1800,
      imageOutputCount: 0,
    });
    const ignore = estimateAiCostUsd({
      model: "gemini-2.5-flash",
      inputTokens: 1000,
      outputTokens: 200,
      imageOutputCount: 0,
    });

    // 0,30 $ / M en entrée, 2,50 $ / M en sortie.
    assert.equal(compte.toFixed(6), (0.0003 + 0.005).toFixed(6));
    assert.equal(ignore.toFixed(6), (0.0003 + 0.0005).toFixed(6));
    // Le coût réel vaut ici plus de six fois le coût affiché sans le
    // raisonnement — l'ordre de grandeur de l'écart constaté sur la facture.
    assert.ok(compte / ignore > 6);
  });
});
