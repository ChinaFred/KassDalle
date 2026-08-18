/**
 * Correction de la prose : ce que le modèle ne peut pas casser.
 *
 * Toute la sûreté de cette passe tient dans deux fonctions pures — le découpage
 * et le réassemblage. Le modèle ne voit jamais le document, et ne peut donc pas
 * toucher un jeton ; encore faut-il que le découpage ne lui en donne aucun, et
 * que le réassemblage refuse ce qui déborde. C'est ce que vérifient ces tests.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { reassembleProse, splitProse } from "../gemini/prosePolish";

/** Une recette proche de celle qui a révélé le défaut. */
const RECIPE = [
  ">> title: Boeuf-riz express",
  ">> portions: 4",
  "",
  "== Riz ==",
  "Mettre le @riz basmati{300%g} à cuire dans une casserole d'eau salée.",
  "Cuire ~{0:12:00} puis égoutter.",
  "",
  "== Légumes et viande ==",
  "Émincer finement le @poivron{1%pièces}, les @carotte{2%pièces} et l'@ail{2%gousse}.",
  "Chauffer l'#poêle{} ou wok avec l'@huile neutre{2%c.à.s.} à feu vif.",
  "![left](https://exemple.test/image.jpg)",
].join("\n");

describe("découpage", () => {
  test("le document se reconstitue à l'identique sans correction", () => {
    const split = splitProse(RECIPE);
    const result = reassembleProse(split, split.segments);
    assert.equal(result.cooklang, RECIPE);
    assert.equal(result.applied, 0);
    assert.equal(result.abandoned, false);
  });

  test("aucun fragment ne contient de balisage", () => {
    // C'est l'invariant central : ce que le modèle reçoit ne peut pas casser un
    // jeton, parce qu'il n'en a aucun sous la main.
    for (const segment of splitProse(RECIPE).segments) {
      assert.doesNotMatch(segment, /[@#~{}]/, `fragment : « ${segment} »`);
    }
  });

  test("les métadonnées, sections et images ne sont jamais découpées", () => {
    const segments = splitProse(RECIPE).segments.join(" | ");
    assert.doesNotMatch(segments, /title|portions/);
    assert.doesNotMatch(segments, /== /);
    assert.doesNotMatch(segments, /exemple\.test/);
  });

  test("les fragments sans lettre ne sont pas envoyés", () => {
    // « , » ou « 4 » n'ont rien à corriger et coûteraient des jetons.
    const split = splitProse("Ajouter @sel{1%pincée}, @poivre{1%pincée}.");
    assert.equal(
      split.segments.some((s) => !/\p{L}/u.test(s)),
      false,
    );
  });

  test("un document sans prose ne déclenche aucun appel", () => {
    assert.equal(splitProse("@sel{1%pincée}\n@poivre{1%pincée}").segments.length, 0);
  });
});

describe("réassemblage — ce qui est accepté", () => {
  test("une correction d'accord est appliquée", () => {
    const split = splitProse("Émincer les @carotte{2%pièces} finement.");
    const corrected = split.segments.map((s) => s.replace("Émincer les", "Émincer les"));
    corrected[corrected.length - 1] = " finement.";
    const result = reassembleProse(split, corrected);
    assert.equal(result.abandoned, false);
    assert.match(result.cooklang, /@carotte\{2%pièces\}/);
  });

  test("l'espacement de bord est celui du découpage, pas celui du modèle", () => {
    // Un modèle qui rend « finement. » sans son espace initial collerait le mot
    // au jeton : « …{2%pièces}finement. »
    const split = splitProse("Émincer les @carotte{2%pièces} finement.");
    const corrected = split.segments.map((s) => s.trim());
    const result = reassembleProse(split, corrected);
    assert.match(result.cooklang, /\} finement\./);
  });

  test("l'élision fautive se corrige", () => {
    const split = splitProse("Chauffer l'#poêle{} ou wok.");
    const corrected = split.segments.map((s) => s.replace("l'", "la "));
    const result = reassembleProse(split, corrected);
    assert.match(result.cooklang, /Chauffer la #poêle\{\}/);
    assert.equal(result.applied, 1);
  });
});

describe("réassemblage — ce qui est refusé", () => {
  test("une liste de longueur différente abandonne tout", () => {
    const split = splitProse(RECIPE);
    const result = reassembleProse(split, split.segments.slice(1));
    assert.equal(result.abandoned, true);
    assert.equal(result.cooklang, RECIPE);
  });

  test("un fragment qui invente un jeton est ignoré", () => {
    const split = splitProse("Ajouter le @sel{1%pincée} en fin de cuisson.");
    const corrected = split.segments.map(() => "Ajouter le @poivre{1%pincée}");
    const result = reassembleProse(split, corrected);
    assert.doesNotMatch(result.cooklang, /@poivre/);
    assert.ok(result.rejected > 0);
  });

  test("un fragment réécrit du simple au double est ignoré", () => {
    const split = splitProse("Ajouter le @sel{1%pincée} en fin de cuisson.");
    const corrected = split.segments.map(
      () => "Ajouter délicatement une petite pincée de sel de Guérande en toute fin de cuisson",
    );
    const result = reassembleProse(split, corrected);
    assert.ok(result.rejected > 0);
    assert.match(result.cooklang, /Ajouter le /);
  });

  test("un fragment effacé est ignoré", () => {
    const split = splitProse("Ajouter le @sel{1%pincée} en fin de cuisson.");
    const result = reassembleProse(
      split,
      split.segments.map(() => ""),
    );
    assert.ok(result.rejected > 0);
    assert.match(result.cooklang, /en fin de cuisson\./);
  });

  test("un élément non textuel est ignoré", () => {
    const split = splitProse("Ajouter le @sel{1%pincée} en fin de cuisson.");
    const result = reassembleProse(
      split,
      split.segments.map(() => null as unknown as string),
    );
    assert.equal(result.applied, 0);
    assert.equal(result.cooklang, "Ajouter le @sel{1%pincée} en fin de cuisson.");
  });
});

describe("le compte rendu ne ment pas", () => {
  test("une passe sans changement le dit", () => {
    const split = splitProse(RECIPE);
    const result = reassembleProse(split, split.segments);
    assert.equal(result.applied, 0);
    assert.equal(result.rejected, 0);
  });

  test("une passe abandonnée n'applique rien", () => {
    const split = splitProse(RECIPE);
    const result = reassembleProse(split, []);
    assert.equal(result.applied, 0);
    assert.equal(result.abandoned, true);
    assert.equal(result.cooklang, RECIPE);
  });
});
