/**
 * Les deux réglages de l'extraction d'illustrations qui cassent en silence.
 *
 * Aucun des deux ne lève d'erreur quand il est faux. Le premier envoie au
 * modèle une phrase inexacte, le second fait ré-échantillonner une page qui
 * n'en avait pas besoin. Dans les deux cas on obtient une image, et elle a
 * l'air normale.
 *
 * ## L'en-tête de taille
 *
 * Le bac à sable annonce au modèle la taille de ce qu'il regarde, en tête des
 * prompts de cadrage et de zones. Le portage l'avait oublié, et les prompts
 * avaient été mis au point avec — celui des coins demande de placer les
 * sommets « au pixel près ». Le texte est verrouillé au caractère près :
 * `page.ts` et `regions.ts` portent le même côté bac à sable.
 *
 * ## L'ordre des coins
 *
 * `isFullFrame` compare un quadrilatère aux quatre coins de l'image. Les coins
 * arrivent en `[y, x]` — la verticale d'abord, comme le veut le modèle —, et
 * intervertir les deux donne une garde qui ne se déclenche jamais, ou qui se
 * déclenche sur une page de travers. C'est la faute qui a produit les cadres
 * en nœud papillon pendant la mise au point.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { isFullFrame, sizeHeader, type Quad1000 } from "../illustrations/extract";

describe("en-tête de taille envoyé au modèle", () => {
  test("reprend mot pour mot la phrase du bac à sable", () => {
    assert.equal(
      sizeHeader({ bytes: Buffer.alloc(0), width: 2048, height: 1536 }),
      "L'image mesure 2048 pixels de large et 1536 de haut.\n\n",
    );
  });

  test("le gros plan des coins a son propre sujet", () => {
    assert.equal(
      sizeHeader({ bytes: Buffer.alloc(0), width: 1200, height: 900 }, "Ce gros plan"),
      "Ce gros plan mesure 1200 pixels de large et 900 de haut.\n\n",
    );
  });

  test("se termine par une ligne vide, pour ne pas coller au prompt", () => {
    const header = sizeHeader({ bytes: Buffer.alloc(0), width: 10, height: 10 });
    assert.ok(header.endsWith("\n\n"), `en-tête sans ligne vide : ${JSON.stringify(header)}`);
  });
});

describe("isFullFrame — la page occupe-t-elle déjà tout le cadre", () => {
  /** Haut-gauche, haut-droit, bas-droit, bas-gauche, en `[y, x]` sur mille. */
  const cadrePlein: Quad1000 = [
    [0, 0],
    [0, 1000],
    [1000, 1000],
    [1000, 0],
  ];

  test("le cadre entier est reconnu", () => {
    assert.equal(isFullFrame(cadrePlein), true);
  });

  test("un écart de quinze millièmes passe encore", () => {
    assert.equal(
      isFullFrame([
        [15, 0],
        [0, 985],
        [985, 1000],
        [1000, 15],
      ]),
      true,
    );
  });

  test("un écart de seize millièmes ne passe plus", () => {
    assert.equal(
      isFullFrame([
        [16, 0],
        [0, 1000],
        [1000, 1000],
        [1000, 0],
      ]),
      false,
    );
  });

  test("une page photographiée de biais n'est pas un cadre plein", () => {
    assert.equal(
      isFullFrame([
        [120, 180],
        [95, 880],
        [910, 940],
        [880, 140],
      ]),
      false,
    );
  });

  test("les coins inversés en (x, y) ne sont pas pris pour un cadre plein", () => {
    // Le même cadre plein, mais écrit à l'envers : abscisse d'abord. Il n'est
    // plein que dans deux coins sur quatre, et la garde doit le refuser — sinon
    // elle laisserait passer une convention de coordonnées fausse.
    assert.equal(
      isFullFrame([
        [0, 0],
        [1000, 0],
        [1000, 1000],
        [0, 1000],
      ]),
      false,
    );
  });
});
