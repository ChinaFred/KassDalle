/**
 * Lecture des coordonnées rendues par un modèle de vision.
 *
 * Ce que ces tests verrouillent : la chaîne d'illustrations ne dépend plus d'un
 * seul moteur. Le repère « 0 à 1000 » est la convention native de Google, et le
 * prompt se contentait de l'énoncer — « entiers 0-1000 ». Cela suffit à un
 * modèle qui l'a apprise, pas à un autre : Claude répond volontiers en pixels,
 * et le résultat, lu comme des millièmes, désigne un rectangle minuscule dans
 * le coin supérieur gauche. Aucune erreur n'était levée ; la découpe tombait
 * sur du vide et se faisait écarter comme page blanche.
 *
 * Le prompt décrit désormais le repère explicitement, et la lecture accepte
 * les trois unités qu'un modèle peut spontanément employer.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { normalizeBox } from "../gemini/detector";

describe("coordonnées d'une boîte", () => {
  test("un repère déjà en millièmes passe inchangé", () => {
    assert.deepEqual(normalizeBox([0, 500, 1000, 1000], 2000, 3000), [0, 500, 1000, 1000]);
  });

  test("un repère 0-1 est multiplié par mille", () => {
    assert.deepEqual(normalizeBox([0, 0.5, 1, 1]), [0, 500, 1000, 1000]);
  });

  test("des pixels sont ramenés avec les dimensions de l'image", () => {
    // La moitié droite d'une page de 2000 × 3000, du haut au bas.
    // [y_min, x_min, y_max, x_max] : la verticale se rapporte à la HAUTEUR —
    // intervertir les deux axes est l'erreur qui rend un rectangle plausible
    // et faux, donc invisible.
    assert.deepEqual(normalizeBox([0, 1000, 3000, 2000], 2000, 3000), [0, 500, 1000, 1000]);
  });

  test("une page en portrait ne confond pas ses deux axes", () => {
    // 1000 de large, 4000 de haut : une bande du haut de 2000 px sur toute la
    // largeur vaut la moitié de la hauteur et la totalité de la largeur.
    assert.deepEqual(normalizeBox([0, 0, 2000, 1000], 1000, 4000), [0, 0, 500, 1000]);
  });

  test("sous mille, pixels et millièmes sont INDISCERNABLES", () => {
    // Et c'est une limite, pas un oubli : « 500 » sur une image de 1000 px de
    // large peut vouloir dire la moitié (millièmes) ou la moitié (pixels) —
    // ici les deux coïncident, mais sur une image de 4000 px de haut, non.
    // Aucune heuristique ne peut trancher : c'est précisément pourquoi le
    // prompt décrit le repère au lieu de l'énoncer, et pourquoi les dimensions
    // de l'image y figurent. Le code fait ce qu'il peut ; le prompt fait le
    // reste.
    assert.deepEqual(normalizeBox([0, 0, 500, 500], 1000, 4000), [0, 0, 500, 500]);
  });

  test("des pixels sans dimensions connues sont bornés, pas inventés", () => {
    // Faute de facteur, on ne devine pas : on borne. Le contrôle de qualité
    // écartera ensuite une découpe absurde — mieux vaut une découpe refusée
    // qu'un rectangle calculé sur un facteur imaginaire.
    const out = normalizeBox([0, 1200, 2400, 1800]);
    assert.ok(out.every((v) => v >= 0 && v <= 1000));
  });

  test("une pleine page reste une pleine page", () => {
    assert.deepEqual(normalizeBox([0, 0, 1000, 1000], 1500, 2000), [0, 0, 1000, 1000]);
    assert.deepEqual(normalizeBox([0, 0, 2000, 1500], 1500, 2000), [0, 0, 1000, 1000]);
  });
});
