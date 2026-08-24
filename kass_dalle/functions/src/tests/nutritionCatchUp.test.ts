/**
 * La décision du rattrapage planifié.
 *
 * Ce que ces tests verrouillent : le balayage reprend ce qui manque, et rien
 * d'autre. Deux erreurs symétriques le rendraient nuisible.
 *
 * Reprendre trop tôt : une recette écrite il y a trente secondes est peut-être
 * en cours de calcul, et la reprendre lancerait une seconde chaîne en parallèle
 * de la première — la salve que la garde du déclencheur vient de supprimer,
 * réintroduite par l'autre bout.
 *
 * Reprendre sans fin : une recette qu'aucun rattrapage ne peut compléter
 * coûterait quelques appels chaque jour, indéfiniment. Le plafond de tentatives
 * est ce qui transforme un échec permanent en dépense finie.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  MAX_CATCH_UP_ATTEMPTS,
  MIN_SNAPSHOT_AGE_MS,
  RECENT_WRITE_GRACE_MS,
  needsNutritionCatchUp,
  type CatchUpCandidate,
} from "../scheduled/nutritionCatchUpSchedule";

const MAINTENANT = 1_800_000_000_000;
const VIEUX = MAINTENANT - MIN_SNAPSHOT_AGE_MS - 1;

function candidat(patch: Partial<CatchUpCandidate> = {}): CatchUpCandidate {
  return {
    pageType: "recipe",
    nutrition: {
      coverage_state: "full",
      missing_ingredients: [],
      computed_at: VIEUX,
    },
    catchUpAttempts: 0,
    updatedAtMs: VIEUX,
    ...patch,
  };
}

describe("faut-il reprendre cette recette", () => {
  test("une recette complète et ancienne est laissée tranquille", () => {
    assert.equal(needsNutritionCatchUp(candidat(), MAINTENANT), false);
  });

  test("jamais calculée : on reprend", () => {
    assert.equal(needsNutritionCatchUp(candidat({ nutrition: undefined }), MAINTENANT), true);
    assert.equal(needsNutritionCatchUp(candidat({ nutrition: null }), MAINTENANT), true);
  });

  test("instantané d'échec : on reprend", () => {
    const nutrition = { coverage_state: "failed", missing_ingredients: [], computed_at: VIEUX };
    assert.equal(needsNutritionCatchUp(candidat({ nutrition }), MAINTENANT), true);
  });

  test("des ingrédients sans valeur : on reprend", () => {
    const nutrition = {
      coverage_state: "partial",
      missing_ingredients: ["safran"],
      computed_at: VIEUX,
    };
    assert.equal(needsNutritionCatchUp(candidat({ nutrition }), MAINTENANT), true);
  });

  test("ce n'est pas une recette : jamais", () => {
    for (const pageType of ["technique", "ingredient_note", "other", "no_recipe"]) {
      assert.equal(
        needsNutritionCatchUp(candidat({ pageType, nutrition: undefined }), MAINTENANT),
        false,
        pageType,
      );
    }
  });

  test("écrite à l'instant : on n'y touche pas", () => {
    // Le déclencheur travaille peut-être encore. Deux chaînes en parallèle sur
    // la même recette, c'est le défaut qu'on vient de corriger.
    const recente = MAINTENANT - RECENT_WRITE_GRACE_MS + 1_000;
    assert.equal(
      needsNutritionCatchUp(candidat({ nutrition: undefined, updatedAtMs: recente }), MAINTENANT),
      false,
    );
    // Passé le délai de grâce, elle redevient éligible.
    const ancienne = MAINTENANT - RECENT_WRITE_GRACE_MS - 1_000;
    assert.equal(
      needsNutritionCatchUp(candidat({ nutrition: undefined, updatedAtMs: ancienne }), MAINTENANT),
      true,
    );
  });

  test("calculée il y a moins de vingt heures : on attend demain", () => {
    // Sinon un balayage quotidien reprendrait deux fois la même recette le
    // jour où le déclencheur vient de la calculer.
    const nutrition = {
      coverage_state: "failed",
      missing_ingredients: [],
      computed_at: MAINTENANT - MIN_SNAPSHOT_AGE_MS + 60_000,
    };
    assert.equal(needsNutritionCatchUp(candidat({ nutrition }), MAINTENANT), false);
  });

  test("les tentatives sont comptées, et bornées", () => {
    const nutrition = { coverage_state: "failed", missing_ingredients: [], computed_at: VIEUX };
    for (let n = 0; n < MAX_CATCH_UP_ATTEMPTS; n++) {
      assert.equal(
        needsNutritionCatchUp(candidat({ nutrition, catchUpAttempts: n }), MAINTENANT),
        true,
        "tentative " + n,
      );
    }
    assert.equal(
      needsNutritionCatchUp(
        candidat({ nutrition, catchUpAttempts: MAX_CATCH_UP_ATTEMPTS }),
        MAINTENANT,
      ),
      false,
    );
  });

  test("un instant illisible ne bloque pas la reprise", () => {
    // Le doute profite au calcul : une recette incomplète qu'on n'ose pas
    // reprendre reste incomplète pour toujours.
    const nutrition = {
      coverage_state: "failed",
      missing_ingredients: [],
      computed_at: "pas une date",
    };
    assert.equal(
      needsNutritionCatchUp(candidat({ nutrition, updatedAtMs: null }), MAINTENANT),
      true,
    );
  });
});
