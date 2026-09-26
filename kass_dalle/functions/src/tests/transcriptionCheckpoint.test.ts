/**
 * Le point de reprise de la transcription.
 *
 * Sur l'import du livre de Jamie Oliver (26 septembre 2026), 35 transcriptions
 * sur 112 refaisaient une lecture déjà obtenue : le job échouait au balisage,
 * Cloud Tasks le rejouait, et l'appel le plus cher repartait de zéro.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import type { PageTranscription } from "../gemini/transcription";
import {
  CHECKPOINT_MAX_CHARS,
  parseCheckpoint,
  serializeCheckpoint,
} from "../pipeline/transcriptionCheckpoint";

const transcription: PageTranscription = {
  pageType: "recipe",
  titre: "Saumon croustillant",
  page: 121,
  raison: "Une liste d'ingrédients et des étapes numérotées",
  document: "",
  recettes: [
    {
      titre: "Saumon croustillant",
      introduction: "Un dîner prêt en trente minutes.",
      inventaire: { sections: ["Le saumon", "Le riz"], lignesIngredients: 4, etapes: 3 },
      lecturesIncertaines: ["1 c. à c. de piment (étape 2)"],
      page: 121,
      portions: 4,
      tempsPreparation: "10 min",
      tempsCuisson: "20 min",
      tempsRepos: null,
      difficulte: "facile",
      sectionsIngredients: [
        { titre: "Le saumon", lignes: ["4 filets de saumon", "1 citron"] },
        { titre: "", lignes: ["250 g de riz", "sel"] },
      ],
      sectionsEtapes: [{ titre: "", etapes: ["Faites cuire le riz.", "Saisissez le saumon."] }],
      notes: [{ genre: "Astuce", texte: "Le riz se réchauffe très bien." }],
    },
  ],
};

describe("point de reprise", () => {
  test("une transcription écrite se relit à l'identique", () => {
    const json = serializeCheckpoint(transcription);
    assert.ok(json);
    assert.deepEqual(parseCheckpoint(json), transcription);
  });

  test("une page sans recette se relit aussi", () => {
    const vide: PageTranscription = {
      pageType: "no_recipe",
      titre: "Page sans titre",
      page: null,
      raison: "Une photographie pleine page",
      document: "",
      recettes: [],
    };
    const json = serializeCheckpoint(vide);
    assert.ok(json);
    assert.deepEqual(parseCheckpoint(json), vide);
  });

  test("une transcription trop grosse n'est pas écrite", () => {
    const grosse: PageTranscription = {
      ...transcription,
      pageType: "technique",
      document: "x".repeat(CHECKPOINT_MAX_CHARS + 1),
      recettes: [],
    };
    assert.equal(serializeCheckpoint(grosse), null);
  });

  test("un job sans point de reprise rend null : c'est la première tentative", () => {
    assert.equal(parseCheckpoint(undefined), null);
    assert.equal(parseCheckpoint(null), null);
    assert.equal(parseCheckpoint(""), null);
  });

  test("un point de reprise qui n'est pas du JSON lève, pour que le job le journalise", () => {
    assert.throws(() => parseCheckpoint("{pas du json"), /JSON|Unexpected|Expected/);
  });

  test("un point de reprise qui n'est pas une chaîne lève", () => {
    assert.throws(() => parseCheckpoint({ pageType: "recipe" }), /illisible/);
  });

  test("un type de page inconnu lève : la page est transcrite de nouveau", () => {
    const json = JSON.stringify({ ...transcription, pageType: "poème" });
    assert.throws(() => parseCheckpoint(json), /illisible/);
  });

  test("une recette dont une liste manque lève", () => {
    const abimee = {
      ...transcription,
      recettes: [{ ...transcription.recettes[0], sectionsEtapes: undefined }],
    };
    assert.throws(() => parseCheckpoint(JSON.stringify(abimee)), /illisible/);
  });

  test("une ligne d'ingrédient qui n'est pas du texte lève", () => {
    const abimee = {
      ...transcription,
      recettes: [
        {
          ...transcription.recettes[0],
          sectionsIngredients: [{ titre: "", lignes: [42] }],
        },
      ],
    };
    assert.throws(() => parseCheckpoint(JSON.stringify(abimee)), /illisible/);
  });
});
