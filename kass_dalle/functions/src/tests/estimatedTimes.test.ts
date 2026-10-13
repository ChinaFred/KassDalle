/**
 * Durées estimées d'une recette : lecture de la réponse du modèle, bornes,
 * priorité des durées lues, et décision du déclencheur.
 *
 * Le test de la boucle est le plus important : le déclencheur écrit
 * `estimated_times` dans la collection qu'il écoute. Si ce champ changeait
 * l'empreinte des entrées, ou si l'écho de son écriture redemandait une
 * estimation, chaque estimation en appellerait une autre.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { Timestamp } from "firebase-admin/firestore";

import {
  ESTIMATED_MINUTES_MAX,
  boundedEstimatedMinutes,
  buildTimeEstimatePrompt,
  parseTimeEstimateAnswer,
} from "../gemini/timeEstimate";
import {
  PENDING_TTL_MS,
  decideEstimatedTimes,
  doneEstimatedTimes,
  estimateFingerprint,
  parseStoredEstimatedTimes,
  readRecipeDurations,
} from "../triggers/recipeEstimatedTimes";
import { recipeTriggerInputsFingerprint } from "../triggers/recipeIngredients";

const NOW = Date.UTC(2026, 9, 11, 12, 0, 0);

function recette(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    titre: "Gratin dauphinois",
    portions: 4,
    raw_cooklang:
      ">> titre: Gratin dauphinois\nÉplucher les @pommes de terre{1%kg}.\nCuire au four ~{1%h}.",
    tags: {},
    ...overrides,
  };
}

describe("bornes d'une durée estimée", () => {
  test("un entier de 1 à 1440 passe", () => {
    assert.equal(boundedEstimatedMinutes(1), 1);
    assert.equal(boundedEstimatedMinutes(45), 45);
    assert.equal(boundedEstimatedMinutes(ESTIMATED_MINUTES_MAX), 1440);
  });

  test("zéro, négatif, décimal, hors bornes ou non numérique : ignoré", () => {
    for (const value of [0, -5, 12.5, 1441, 99999, "20", null, undefined, NaN, {}]) {
      assert.equal(boundedEstimatedMinutes(value), null, `valeur ${String(value)}`);
    }
  });
});

describe("lecture de la réponse du modèle", () => {
  test("une entrée par recette, indexée par son identifiant", () => {
    const answers = parseTimeEstimateAnswer(
      {
        recipes: [
          { id: "1", prep_minutes: 10, cook_minutes: 0 },
          { id: "0", prep_minutes: 20, cook_minutes: 60 },
        ],
      },
      2,
    );
    assert.ok(answers);
    assert.deepEqual(answers.get(0), { prep: 20, cook: 60 });
    // Zéro veut dire « pas de cuisson » ou « je ne sais pas » : aucune durée.
    assert.deepEqual(answers.get(1), { prep: 10, cook: null });
  });

  test("identifiant inconnu, répété ou hors lot : ignoré", () => {
    const answers = parseTimeEstimateAnswer(
      {
        recipes: [
          { id: "0", prep_minutes: 5, cook_minutes: 5 },
          { id: "0", prep_minutes: 99, cook_minutes: 99 },
          { id: "7", prep_minutes: 5, cook_minutes: 5 },
          { id: "x", prep_minutes: 5, cook_minutes: 5 },
          "texte",
        ],
      },
      2,
    );
    assert.ok(answers);
    assert.equal(answers.size, 1);
    assert.deepEqual(answers.get(0), { prep: 5, cook: 5 });
  });

  test("valeurs hors bornes ramenées à null", () => {
    const answers = parseTimeEstimateAnswer(
      { recipes: [{ id: 0, prep_minutes: 2000, cook_minutes: "30" }] },
      1,
    );
    assert.deepEqual(answers?.get(0), { prep: null, cook: null });
  });

  test("forme générale illisible : null", () => {
    assert.equal(parseTimeEstimateAnswer(null, 1), null);
    assert.equal(parseTimeEstimateAnswer({ recettes: [] }, 1), null);
    assert.equal(parseTimeEstimateAnswer({ recipes: "non" }, 1), null);
  });
});

describe("prompt", () => {
  test("le contenu part en JSON, sans ses caractères de contrôle", () => {
    const prompt = buildTimeEstimatePrompt([
      { titre: "Tarte\u0007 aux pommes", content: "Étaler la pâte.\nCuire 30 min.", portions: 6 },
    ]);
    assert.match(prompt, /"id":"0"/);
    assert.match(prompt, /"portions":6/);
    assert.match(prompt, /Tarte aux pommes/);
    assert.match(prompt, /prep_minutes/);
    assert.match(prompt, /cook_minutes/);
    assert.match(prompt, /DONNÉES/);
  });
});

describe("priorité des durées lues", () => {
  test("le champ `tags` passe en premier", () => {
    const data = recette({
      tags: { prep_time: 15, cook_time: 40 },
      raw_cooklang: ">> temps_preparation: 99\n>> temps_cuisson: 99\nTexte.",
    });
    assert.deepEqual(readRecipeDurations(data), { prep: 15, cook: 40 });
  });

  test("à défaut, les métadonnées CookLang, alias compris", () => {
    const data = recette({
      raw_cooklang: ">> temps_préparation: 20 min\n>> cook_time: 1 h\nTexte.",
    });
    assert.deepEqual(readRecipeDurations(data), { prep: 20, cook: 60 });
  });

  test("un champ par source : préparation dans tags, cuisson dans le brouillon", () => {
    const data = recette({
      tags: { prep_time: 10 },
      draft_cooklang: ">> temps_cuisson: 25\nTexte.",
    });
    assert.deepEqual(readRecipeDurations(data), { prep: 10, cook: 25 });
  });

  test("une durée nulle ou négative ne compte pas comme lue", () => {
    const data = recette({ tags: { prep_time: 0, cook_time: -3 } });
    assert.deepEqual(readRecipeDurations(data), { prep: null, cook: null });
  });
});

describe("décision du déclencheur", () => {
  test("une durée manque, aucune estimation : on estime", () => {
    const decision = decideEstimatedTimes(recette({ tags: { prep_time: 10 } }), NOW);
    assert.equal(decision.kind, "estimate");
  });

  test("les deux durées sont lues : rien, et pas d'appel", () => {
    const decision = decideEstimatedTimes(recette({ tags: { prep_time: 10, cook_time: 20 } }), NOW);
    assert.deepEqual(decision, { kind: "none", reason: "complete" });
  });

  test("durées saisies à la main sur une recette estimée : l'estimation est vidée", () => {
    const data = recette({
      tags: { prep_time: 10, cook_time: 20 },
      estimated_times: { status: "done", fingerprint: "abc", prep: 15, cook: 30 },
    });
    assert.deepEqual(decideEstimatedTimes(data, NOW), {
      kind: "clear",
      fingerprint: estimateFingerprint(data),
    });
    // Le champ vidé garde l'empreinte, sans valeur.
    const field = doneEstimatedTimes(estimateFingerprint(data), { prep: null, cook: null }, data);
    assert.equal(field.status, "done");
    assert.equal(field.prep, null);
    assert.equal(field.cook, null);
    // Son écho ne réécrit rien.
    const echo = { ...data, estimated_times: { ...field, estimated_at: undefined } };
    assert.deepEqual(decideEstimatedTimes(echo, NOW), { kind: "none", reason: "complete" });
  });

  test("ajouter puis retirer une ligne `>> temps_cuisson:` ne relance pas d'appel", () => {
    const base = recette({ tags: { prep_time: 10 } });
    const fingerprint = estimateFingerprint(base);
    // Durée de cuisson ajoutée dans le texte : l'estimation est vidée.
    const withCook = {
      ...base,
      raw_cooklang: `>> temps_cuisson: 30\n${String(base.raw_cooklang)}`,
      estimated_times: { status: "done", fingerprint, prep: null, cook: 45 },
    };
    const cleared = decideEstimatedTimes(withCook, NOW);
    assert.deepEqual(cleared, { kind: "clear", fingerprint });
    // Ligne retirée : même empreinte, estimation vide déjà enregistrée.
    const removed = {
      ...base,
      estimated_times: { status: "done", fingerprint, prep: null, cook: null },
    };
    assert.deepEqual(decideEstimatedTimes(removed, NOW), { kind: "none", reason: "up_to_date" });
  });

  test("l'écho de l'écriture de l'estimation ne rappelle pas le modèle", () => {
    const data = recette();
    const decision = decideEstimatedTimes(data, NOW);
    assert.equal(decision.kind, "estimate");
    const echo = {
      ...data,
      estimated_times: {
        status: "done",
        fingerprint: estimateFingerprint(data),
        prep: 20,
        cook: 60,
        estimated_at: Timestamp.fromMillis(NOW),
      },
    };
    assert.deepEqual(decideEstimatedTimes(echo, NOW), { kind: "none", reason: "up_to_date" });
  });

  test("le modèle n'a rien su estimer : pas de nouvel appel pour le même contenu", () => {
    const data = recette();
    const echo = {
      ...data,
      estimated_times: {
        status: "done",
        fingerprint: estimateFingerprint(data),
        prep: null,
        cook: null,
      },
    };
    assert.equal(decideEstimatedTimes(echo, NOW).kind, "none");
  });

  test("une réservation récente bloque les échos ; expirée, elle se reprend", () => {
    const data = recette();
    const pending = (claimedAtMs: number) => ({
      ...data,
      estimated_times: {
        status: "pending",
        fingerprint: estimateFingerprint(data),
        claim_id: "c1",
        claimed_at: Timestamp.fromMillis(claimedAtMs),
      },
    });
    assert.deepEqual(decideEstimatedTimes(pending(NOW - 1000), NOW), {
      kind: "none",
      reason: "pending",
    });
    assert.equal(decideEstimatedTimes(pending(NOW - PENDING_TTL_MS - 1), NOW).kind, "estimate");
  });

  test("le contenu change : l'estimation est refaite", () => {
    const data = recette();
    const stored = {
      ...data,
      estimated_times: { status: "done", fingerprint: estimateFingerprint(data), prep: 20 },
    };
    const edited = {
      ...stored,
      raw_cooklang: `${String(data.raw_cooklang)}\nLaisser gratiner ~{10%min}.`,
    };
    assert.equal(decideEstimatedTimes(edited, NOW).kind, "estimate");
  });

  test("une recette vide n'est pas estimée", () => {
    const decision = decideEstimatedTimes({ titre: "", raw_cooklang: ">> titre: \n" }, NOW);
    assert.deepEqual(decision, { kind: "none", reason: "no_content" });
  });

  test("un champ mal formé se traite comme absent", () => {
    assert.equal(parseStoredEstimatedTimes("texte"), null);
    assert.equal(parseStoredEstimatedTimes({ status: "done" }), null);
    assert.equal(parseStoredEstimatedTimes({ status: "autre", fingerprint: "x" }), null);
    const data = recette({ estimated_times: ["liste"] });
    assert.equal(decideEstimatedTimes(data, NOW).kind, "estimate");
  });
});

describe("empreinte", () => {
  test("saisir une durée ne change pas l'empreinte du contenu", () => {
    const before = recette();
    const after = recette({
      raw_cooklang: `>> temps_preparation: 20\n${String(before.raw_cooklang)}`,
    });
    assert.equal(estimateFingerprint(before), estimateFingerprint(after));
  });

  test("changer une étape ou le titre la change", () => {
    const base = recette();
    assert.notEqual(estimateFingerprint(base), estimateFingerprint(recette({ titre: "Autre" })));
    assert.notEqual(
      estimateFingerprint(base),
      estimateFingerprint(recette({ raw_cooklang: "Une autre recette." })),
    );
  });

  test("`estimated_times` n'est pas une entrée du déclencheur", () => {
    const data = recette();
    const withEstimate = {
      ...data,
      estimated_times: { status: "done", fingerprint: "f", prep: 20, cook: 60 },
    };
    assert.equal(
      recipeTriggerInputsFingerprint(data),
      recipeTriggerInputsFingerprint(withEstimate),
    );
  });
});

describe("champ écrit", () => {
  test("une durée lue dans le texte n'est pas conservée en estimation", () => {
    const data = recette({ raw_cooklang: ">> temps_preparation: 20\nÉplucher. Cuire." });
    const field = doneEstimatedTimes("f", { prep: 35, cook: 50 }, data);
    assert.equal(field.prep, null);
    assert.equal(field.cook, 50);
    assert.equal(field.status, "done");
  });

  test("une durée lue dans tags non plus", () => {
    const field = doneEstimatedTimes(
      "f",
      { prep: 35, cook: 50 },
      recette({ tags: { cook_time: 10 } }),
    );
    assert.equal(field.prep, 35);
    assert.equal(field.cook, null);
  });
});
