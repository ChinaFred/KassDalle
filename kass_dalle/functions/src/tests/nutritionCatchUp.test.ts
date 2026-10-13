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
  catchUpDecision,
  nutritionIsIncomplete,
  nothingLeftToAsk,
  type CatchUpCandidate,
} from "../scheduled/nutritionCatchUpSchedule";
import { ENRICHMENT_RETRY_AFTER_MS, enrichmentAttemptIsRecent } from "../nutrition/aiEnrichment";
import { missingWeightCause } from "../nutrition/recipeNutrition";

/** La recette part-elle dans la chaîne nutrition ? */
function needsNutritionCatchUp(c: CatchUpCandidate, nowMs: number, forced = false): boolean {
  return catchUpDecision(c, nowMs, forced) === "reprendre";
}

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

describe("reprise demandée : ce qui saute et ce qui reste", () => {
  const nutritionFraiche = {
    coverage_state: "failed",
    missing_ingredients: [],
    computed_at: MAINTENANT - 60_000,
  };

  test("l'âge de l'instantané ne bloque plus", () => {
    // Un administrateur qui vient de corriger un référentiel veut le résultat
    // maintenant : attendre vingt heures n'a de sens que pour un passage que
    // personne n'a demandé.
    const c = candidat({ nutrition: nutritionFraiche });
    assert.equal(needsNutritionCatchUp(c, MAINTENANT), false);
    assert.equal(needsNutritionCatchUp(c, MAINTENANT, true), true);
  });

  test("le plafond de tentatives ne bloque plus", () => {
    const nutrition = { coverage_state: "failed", missing_ingredients: [], computed_at: VIEUX };
    const c = candidat({ nutrition, catchUpAttempts: MAX_CATCH_UP_ATTEMPTS + 3 });
    assert.equal(needsNutritionCatchUp(c, MAINTENANT), false);
    assert.equal(needsNutritionCatchUp(c, MAINTENANT, true), true);
  });

  test("le délai de grâce, lui, ne saute JAMAIS", () => {
    // C'est la seule borne qui ne protège pas d'une impatience : elle protège
    // de la salve. Reprendre une recette que le déclencheur calcule encore,
    // c'est lancer une seconde chaîne en parallèle — le défaut d'août, réouvert
    // par l'autre bout.
    const c = candidat({
      nutrition: undefined,
      updatedAtMs: MAINTENANT - RECENT_WRITE_GRACE_MS + 1_000,
    });
    assert.equal(needsNutritionCatchUp(c, MAINTENANT), false);
    assert.equal(needsNutritionCatchUp(c, MAINTENANT, true), false);
  });

  test("une page qui n'est pas une recette reste hors de portée", () => {
    const c = candidat({ pageType: "technique", nutrition: undefined });
    assert.equal(needsNutritionCatchUp(c, MAINTENANT, true), false);
  });

  test("une recette déjà complète n'est pas reprise, même de force", () => {
    // Forcer lève la patience, pas le discernement : il n'y a rien à refaire.
    assert.equal(needsNutritionCatchUp(candidat(), MAINTENANT, true), false);
  });
});

describe("ce qui n'est pas repris, et pourquoi", () => {
  function avec(nutrition: Record<string, unknown>, patch: Partial<CatchUpCandidate> = {}) {
    return candidat({ nutrition: { computed_at: VIEUX, ...nutrition }, ...patch });
  }

  test("tentatives consommées : abandonnée, pas ignorée", () => {
    // Elle disparaissait du compte rendu ; elle y est maintenant nommée.
    const c = avec(
      { coverage_state: "partial", missing_ingredients: ["sumac"] },
      { catchUpAttempts: MAX_CATCH_UP_ATTEMPTS },
    );
    assert.equal(catchUpDecision(c, MAINTENANT), "abandonnee");
    assert.equal(catchUpDecision(c, MAINTENANT, true), "reprendre");
  });

  test("seules des lignes impossibles à peser manquent : non reprenable", () => {
    for (const cause of ["quantite_illisible", "comptage_sans_poids", "unite_sans_poids"]) {
      const c = avec({
        coverage_state: "partial",
        missing_ingredients: ["œufs"],
        missing_weight: [{ name: "œufs", cause }],
        missing_profile: [],
      });
      assert.equal(catchUpDecision(c, MAINTENANT), "non_reprenable", cause);
      // Un administrateur qui vient de corriger un poids redemande.
      assert.equal(catchUpDecision(c, MAINTENANT, true), "reprendre", cause);
    }
  });

  test("une ligne sans quantité ni unité reste reprenable : sa portion usuelle se demande", () => {
    const c = avec({
      coverage_state: "partial",
      missing_ingredients: ["roquette"],
      missing_weight: [{ name: "roquette", cause: "quantite_absente" }],
      missing_profile: [],
    });
    assert.equal(catchUpDecision(c, MAINTENANT), "reprendre");
  });

  test("un ingrédient sans valeurs pour 100 g suffit à reprendre", () => {
    const c = avec({
      coverage_state: "partial",
      missing_ingredients: ["œufs", "sumac"],
      missing_weight: [{ name: "œufs", cause: "comptage_sans_poids" }],
      missing_profile: ["sumac"],
    });
    assert.equal(catchUpDecision(c, MAINTENANT), "reprendre");
  });

  test("ingrédients sans valeurs plus redemandés à l'IA : non reprenable", () => {
    // L'enrichissement de la reprise ne les soumet plus au modèle : la
    // reprendre consommerait une tentative pour rien.
    const seulsExclus = avec({
      coverage_state: "partial",
      missing_ingredients: ["œufs", "verjus"],
      missing_weight: [{ name: "œufs", cause: "comptage_sans_poids" }],
      missing_profile: ["verjus"],
      missing_profile_excluded: ["verjus"],
    });
    assert.equal(catchUpDecision(seulsExclus, MAINTENANT), "non_reprenable");
    assert.equal(catchUpDecision(seulsExclus, MAINTENANT, true), "reprendre");

    const unSeulExclu = avec({
      coverage_state: "partial",
      missing_ingredients: ["sumac", "verjus"],
      missing_weight: [],
      missing_profile: ["sumac", "verjus"],
      missing_profile_excluded: ["verjus"],
    });
    assert.equal(catchUpDecision(unSeulExclu, MAINTENANT), "reprendre");
  });

  test("un instantané sans les deux listes ne permet pas de conclure : reprenable", () => {
    const c = avec({ coverage_state: "partial", missing_ingredients: ["œufs"] });
    assert.equal(nothingLeftToAsk(c.nutrition), false);
    assert.equal(catchUpDecision(c, MAINTENANT), "reprendre");
  });

  test("un calcul en échec n'est jamais non reprenable", () => {
    const c = avec({
      coverage_state: "failed",
      missing_ingredients: [],
      missing_weight: [{ name: "œufs", cause: "comptage_sans_poids" }],
      missing_profile: [],
    });
    assert.equal(catchUpDecision(c, MAINTENANT), "reprendre");
  });

  test("complète : ignorée, jamais listée", () => {
    assert.equal(catchUpDecision(candidat(), MAINTENANT), "ignorer");
    assert.equal(
      catchUpDecision(candidat({ catchUpAttempts: MAX_CATCH_UP_ATTEMPTS }), MAINTENANT),
      "ignorer",
    );
  });

  test("complétude jugée après la reprise", () => {
    assert.equal(nutritionIsIncomplete(null), true);
    assert.equal(nutritionIsIncomplete({ coverage_state: "failed" }), true);
    assert.equal(nutritionIsIncomplete({ missing_ingredients: ["œufs"] }), true);
    assert.equal(nutritionIsIncomplete({ missing_ingredients: [] }), false);
  });
});

describe("délai du rattrapage aligné sur la relance de l'enrichissement", () => {
  test("les deux délais sont égaux", () => {
    assert.equal(MIN_SNAPSHOT_AGE_MS, ENRICHMENT_RETRY_AFTER_MS);
  });

  test("passage quotidien à heure fixe : la reprise d'hier peut redemander aujourd'hui", () => {
    // Hier 5 h 00 min 40 s : l'essai d'enrichissement, puis l'instantané.
    // Aujourd'hui 5 h 00 min 10 s : un peu moins de vingt-quatre heures.
    const hier = MAINTENANT - 24 * 3_600_000 + 30_000;
    const c = candidat({
      nutrition: {
        coverage_state: "partial",
        missing_ingredients: ["sumac"],
        missing_weight: [],
        missing_profile: ["sumac"],
        computed_at: hier + 5_000,
      },
      updatedAtMs: hier + 5_000,
    });
    assert.equal(catchUpDecision(c, MAINTENANT), "reprendre");
    // Et la marque d'essai de l'ingrédient n'empêche plus de lui redemander.
    assert.equal(enrichmentAttemptIsRecent(hier, MAINTENANT), false);
  });
});

describe("cause d'une ligne sans poids", () => {
  test("quantité illisible devant une unité, quantité absente sur une ligne nue", () => {
    assert.equal(
      missingWeightCause({ name: "farine", qty: "quelques", unit: "g", weighingUnit: null }),
      "quantite_illisible",
    );
    assert.equal(
      missingWeightCause({ name: "roquette", qty: "", unit: "", weighingUnit: null }),
      "quantite_absente",
    );
  });

  test("compté à la pièce sans poids à la pièce", () => {
    assert.equal(
      missingWeightCause({ name: "aubergine", qty: "2", unit: "", weighingUnit: "" }),
      "comptage_sans_poids",
    );
    assert.equal(
      missingWeightCause({ name: "aubergine", qty: "2", unit: "pièce", weighingUnit: "pièce" }),
      "comptage_sans_poids",
    );
  });

  test("une unité que personne ne sait peser", () => {
    assert.equal(
      missingWeightCause({
        name: "safran",
        qty: "1",
        unit: "dosette",
        weighingUnit: "dosette",
      }),
      "unite_sans_poids",
    );
  });
});
