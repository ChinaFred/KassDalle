/**
 * Correction de perspective : la géométrie, sans image.
 *
 * Ce que ces tests verrouillent : une page de livre photographiée à main levée
 * est un TRAPÈZE, et un cadre rectangulaire — aussi serré soit-il — garde
 * forcément deux coins de papier et de table. C'est une limite de la forme,
 * qu'aucun prompt ne lève. Seule une projection l'efface.
 *
 * Les fonctions testées ici sont pures : la boucle sur les pixels, elle, se
 * contente de les appliquer.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  computeHomography,
  invertMatrix3,
  isNearlyRectangular,
  outputSize,
  type Quad,
} from "../gemini/perspective";

/** Applique une homographie 3×3 à un point. */
function project(h: number[], x: number, y: number): { x: number; y: number } {
  const denom = h[6] * x + h[7] * y + h[8];
  return {
    x: (h[0] * x + h[1] * y + h[2]) / denom,
    y: (h[3] * x + h[4] * y + h[5]) / denom,
  };
}

const rectangle: Quad = [
  { x: 0, y: 0 },
  { x: 400, y: 0 },
  { x: 400, y: 300 },
  { x: 0, y: 300 },
];

/** Une page vue de biais : le bord du haut plus court que celui du bas. */
const trapeze: Quad = [
  { x: 120, y: 80 },
  { x: 480, y: 110 },
  { x: 520, y: 400 },
  { x: 90, y: 380 },
];

describe("homographie", () => {
  test("elle envoie chaque coin exactement sur sa cible", () => {
    // C'est la seule chose qu'on lui demande, et tout le reste en découle.
    const cible: Quad = [
      { x: 0, y: 0 },
      { x: 400, y: 0 },
      { x: 400, y: 300 },
      { x: 0, y: 300 },
    ];
    const h = computeHomography(trapeze, cible);
    for (let i = 0; i < 4; i++) {
      const out = project(h, trapeze[i].x, trapeze[i].y);
      assert.ok(Math.abs(out.x - cible[i].x) < 0.01, `coin ${i} en x : ${out.x}`);
      assert.ok(Math.abs(out.y - cible[i].y) < 0.01, `coin ${i} en y : ${out.y}`);
    }
  });

  test("son inverse ramène au point de départ", () => {
    // C'est cet inverse que la boucle emploie : pour chaque pixel de SORTIE,
    // elle cherche d'où il vient dans la source. Faire l'inverse — projeter
    // chaque pixel source vers sa destination — laisserait des trous.
    const h = computeHomography(trapeze, rectangle);
    const inverse = invertMatrix3(h);
    const depart = { x: 300, y: 250 };
    const aller = project(h, depart.x, depart.y);
    const retour = project(inverse, aller.x, aller.y);
    assert.ok(Math.abs(retour.x - depart.x) < 0.01);
    assert.ok(Math.abs(retour.y - depart.y) < 0.01);
  });

  test("un rectangle vers lui-même ne déplace rien", () => {
    const h = computeHomography(rectangle, rectangle);
    const out = project(h, 137, 211);
    assert.ok(Math.abs(out.x - 137) < 0.01);
    assert.ok(Math.abs(out.y - 211) < 0.01);
  });
});

describe("dimensions de sortie", () => {
  test("un rectangle garde les siennes", () => {
    assert.deepEqual(outputSize(rectangle), { width: 400, height: 300 });
  });

  test("un trapèze prend la moyenne géométrique de ses bords opposés", () => {
    // En perspective, le bord proche est plus long que le bord lointain.
    // Retenir le plus grand des deux étirerait l'image dans un sens ; la
    // moyenne géométrique estime la vraie dimension du document.
    const large: Quad = [
      { x: 0, y: 0 },
      { x: 100, y: 0 },
      { x: 400, y: 300 },
      { x: -300, y: 300 },
    ];
    const taille = outputSize(large);
    assert.ok(taille.width > 100 && taille.width < 700, `largeur ${taille.width}`);
  });
});

describe("faut-il redresser ?", () => {
  test("un rectangle parfait ne demande rien", () => {
    // Redresser coûte une boucle sur chaque pixel, et ré-échantillonne : sur une
    // page déjà droite, c'est de la netteté perdue pour rien.
    assert.equal(isNearlyRectangular(rectangle), true);
  });

  test("un trapèze en demande", () => {
    assert.equal(isNearlyRectangular(trapeze), false);
  });

  test("une inclinaison d'un pixel ne suffit pas à déclencher", () => {
    const presqueDroit: Quad = [
      { x: 0, y: 0 },
      { x: 400, y: 1 },
      { x: 400, y: 300 },
      { x: 0, y: 299 },
    ];
    assert.equal(isNearlyRectangular(presqueDroit), true);
  });

  test("une zone dégénérée ne fait pas diviser par zéro", () => {
    const plat: Quad = [
      { x: 10, y: 10 },
      { x: 10, y: 10 },
      { x: 10, y: 10 },
      { x: 10, y: 10 },
    ];
    assert.equal(isNearlyRectangular(plat), true);
  });
});
