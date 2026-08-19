/**
 * Ce qu'on garde d'une découpe d'illustration, et ce qu'on jette.
 *
 * Logique **serveur seule**, et purement locale : aucun modèle, aucun réseau.
 * Elle existe parce que les boîtes viennent d'un modèle et non d'un détecteur
 * géométrique — une boîte fantaisiste produisait une bande de texte publiée
 * comme photographie du plat.
 *
 * Le tri est conservateur, et ces tests le verrouillent dans ce sens : jeter
 * une vraie photo est irrattrapable, garder une découpe douteuse ne coûte qu'un
 * rejet de plus à la modération.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { assessCrop, rejectionLabel, type CropMeasures } from "../gemini/illustrationQuality";

/** Une découpe plausible : grande, carrée, colorée. */
function photo(overrides: Partial<CropMeasures> = {}): CropMeasures {
  return {
    widthPx: 600,
    heightPx: 400,
    pageWidthPx: 2000,
    pageHeightPx: 3000,
    meanLuminance: 130,
    chroma: 40,
    ...overrides,
  };
}

describe("assessCrop", () => {
  test("une photographie ordinaire est gardée", () => {
    assert.deepEqual(assessCrop(photo()), { keep: true, reason: null });
  });

  test("une vignette de moins de 120 px de côté est écartée", () => {
    assert.equal(assessCrop(photo({ widthPx: 90 })).reason, "too_small");
    assert.equal(assessCrop(photo({ heightPx: 100 })).reason, "too_small");
  });

  test("une découpe qui pèse moins de 1,5 % de la page est écartée", () => {
    // 300×200 sur une page de 2000×3000 : 60 000 pixels sur six millions.
    const verdict = assessCrop(photo({ widthPx: 300, heightPx: 200 }));
    assert.equal(verdict.reason, "too_small");
  });

  test("une bande est écartée, dans les deux orientations", () => {
    assert.equal(assessCrop(photo({ widthPx: 2000, heightPx: 300 })).reason, "extreme_aspect");
    assert.equal(assessCrop(photo({ widthPx: 300, heightPx: 2000 })).reason, "extreme_aspect");
  });

  test("un rapport de 4:1 exactement passe encore", () => {
    assert.equal(assessCrop(photo({ widthPx: 1200, heightPx: 300 })).keep, true);
  });

  test("presque blanche ET sans couleur : du papier ou du texte", () => {
    const verdict = assessCrop(photo({ meanLuminance: 240, chroma: 4 }));
    assert.equal(verdict.reason, "blank_or_text");
  });

  test("une photo claire mais colorée est gardée", () => {
    // Une assiette blanche sur nappe claire : lumineuse, mais pas neutre.
    assert.equal(assessCrop(photo({ meanLuminance: 240, chroma: 30 })).keep, true);
  });

  test("une photographie en noir et blanc est gardée", () => {
    // Chroma nulle, mais une photo n'atteint jamais 225 de luminance moyenne.
    // C'est précisément pour elle que les deux conditions sont exigées ensemble.
    assert.equal(assessCrop(photo({ meanLuminance: 140, chroma: 0 })).keep, true);
  });

  test("une page sans dimensions connues ne fait pas échouer le ratio", () => {
    const verdict = assessCrop(photo({ pageWidthPx: 0, pageHeightPx: 0 }));
    assert.equal(verdict.keep, true);
  });

  test("chaque motif de rejet porte un libellé français", () => {
    for (const reason of ["too_small", "extreme_aspect", "blank_or_text"] as const) {
      assert.ok(rejectionLabel(reason).length > 0);
    }
  });
});
