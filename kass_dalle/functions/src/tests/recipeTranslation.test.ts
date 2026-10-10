/**
 * Traduction d'une recette étrangère, entre la transcription et le balisage.
 *
 * Ce que ces tests verrouillent : une recette française n'est jamais traduite,
 * une traduction qui perd une ligne est rejetée, et le texte d'origine garde
 * ce que la page disait.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  needsTranslation,
  normalizeLanguageCode,
  parseTranscription,
  type TranscribedRecipe,
} from "../gemini/transcription";
import {
  parseTranslation,
  TRANSLATION_PROMPT,
  translationInput,
  translationShapeMismatches,
} from "../gemini/translation";
import { originalTextDocument } from "../pipeline/originalText";
import { parseCheckpoint, serializeCheckpoint } from "../pipeline/transcriptionCheckpoint";
import { TRANSCRIPTION_PROMPT } from "../gemini/promptsExtraction";

function bananaBread(): TranscribedRecipe {
  return {
    titre: "Banana bread",
    langue: "en",
    introduction: "A classic loaf.",
    inventaire: { sections: ["For the batter"], lignesIngredients: 3, etapes: 2 },
    lecturesIncertaines: ["mashed (ingredient 1)"],
    page: 42,
    portions: 8,
    tempsPreparation: "15 min",
    tempsCuisson: "1 hour",
    tempsRepos: null,
    difficulte: "easy",
    sectionsIngredients: [
      {
        titre: "For the batter",
        lignes: ["3 ripe bananas, mashed", "2 cups all-purpose flour", "1/2 cup sugar"],
      },
    ],
    sectionsEtapes: [
      { titre: "", etapes: ["Preheat the oven to 350°F.", "Mix and bake for 1 hour."] },
    ],
    notes: [{ genre: "Tip", texte: "Use very ripe bananas." }],
  };
}

function translatedJson(): Record<string, unknown> {
  return {
    titre: "Banana bread",
    introduction: "Un cake classique.",
    portions: 99,
    temps_preparation: "15 min",
    temps_cuisson: "1 h",
    temps_repos: null,
    difficulte: "facile",
    inventaire_sections: ["Pour la pâte"],
    sections_ingredients: [
      {
        titre: "Pour la pâte",
        lignes: ["3 bananes bien mûres, écrasées", "250 g de farine", "100 g de sucre"],
      },
    ],
    sections_etapes: [
      { titre: "", etapes: ["Préchauffez le four à 175 °C.", "Mélangez et enfournez 1 h."] },
    ],
    notes: [{ genre: "Astuce", texte: "Prenez des bananes très mûres." }],
  };
}

describe("langue lue par la transcription", () => {
  test("un code est ramené à deux lettres minuscules", () => {
    assert.equal(normalizeLanguageCode("EN"), "en");
    assert.equal(normalizeLanguageCode("en-GB"), "en");
    assert.equal(normalizeLanguageCode("pt_BR"), "pt");
  });

  test("une langue absente ou illisible vaut le français", () => {
    assert.equal(normalizeLanguageCode(undefined), "fr");
    assert.equal(normalizeLanguageCode(""), "fr");
    assert.equal(normalizeLanguageCode("english"), "fr");
    assert.equal(normalizeLanguageCode(42), "fr");
  });

  test("seule une recette étrangère demande une traduction", () => {
    assert.equal(needsTranslation({ ...bananaBread(), langue: "en" }), true);
    assert.equal(needsTranslation({ ...bananaBread(), langue: "fr" }), false);
    // Une transcription antérieure à la détection n'a pas de langue.
    assert.equal(needsTranslation({ ...bananaBread(), langue: undefined }), false);
  });

  test("parseTranscription lit la langue de chaque recette", () => {
    const t = parseTranscription({
      raison: "deux recettes",
      page_type: "recipe",
      titre: "Page",
      recettes: [
        { titre: "Crumble", langue: "fr", sections_etapes: [{ titre: "", etapes: ["Mélangez."] }] },
        { titre: "Pie", langue: "EN", sections_etapes: [{ titre: "", etapes: ["Mix."] }] },
        { titre: "Sans langue", sections_etapes: [{ titre: "", etapes: ["Mélangez."] }] },
      ],
    });
    assert.deepEqual(
      t.recettes.map((r) => r.langue),
      ["fr", "en", "fr"],
    );
    assert.deepEqual(t.recettes.map(needsTranslation), [false, true, false]);
  });

  test("le prompt de transcription demande la langue sans traduire", () => {
    assert.match(TRANSCRIPTION_PROMPT, /"langue"/);
    assert.match(TRANSCRIPTION_PROMPT, /Ce sont les étapes qui décident/);
    assert.match(TRANSCRIPTION_PROMPT, /Tu ne\s+traduis rien/);
  });
});

describe("traduction", () => {
  test("le prompt convertit les mesures en métrique", () => {
    assert.match(TRANSLATION_PROMPT, /°F → °C/);
    assert.match(TRANSLATION_PROMPT, /GRAMMES/);
    assert.match(TRANSLATION_PROMPT, /MILLILITRES/);
  });

  test("l'entrée envoyée au modèle ne porte pas les lectures incertaines", () => {
    const input = translationInput(bananaBread());
    assert.equal("lectures_incertaines" in input, false);
    assert.deepEqual(input.inventaire_sections, ["For the batter"]);
  });

  test("la recette traduite garde l'original et ce qui ne se traduit pas", () => {
    const original = bananaBread();
    const t = parseTranslation(translatedJson(), original);
    assert.equal(t.langue, "fr");
    assert.equal(needsTranslation(t), false);
    assert.equal(t.introduction, "Un cake classique.");
    assert.deepEqual(t.sectionsIngredients[0].lignes[1], "250 g de farine");
    // Portions, page et lectures incertaines viennent de la page.
    assert.equal(t.portions, 8);
    assert.equal(t.page, 42);
    assert.deepEqual(t.lecturesIncertaines, ["mashed (ingredient 1)"]);
    // Les titres d'inventaire sont traduits, les compteurs gardés.
    assert.deepEqual(t.inventaire, {
      sections: ["Pour la pâte"],
      lignesIngredients: 3,
      etapes: 2,
    });
    assert.equal(t.traduction?.langue, "en");
    assert.equal(t.traduction?.recette, original);
    assert.deepEqual(translationShapeMismatches(original, t), []);
  });

  test("sans titres d'inventaire traduits, les titres sont retirés", () => {
    const json = { ...translatedJson(), inventaire_sections: [] };
    const t = parseTranslation(json, bananaBread());
    assert.deepEqual(t.inventaire?.sections, []);
    assert.equal(t.inventaire?.lignesIngredients, 3);
  });

  test("une ligne perdue fait rejeter la traduction", () => {
    const json = translatedJson();
    (json.sections_ingredients as Array<{ lignes: string[] }>)[0].lignes.pop();
    const original = bananaBread();
    const ecarts = translationShapeMismatches(original, parseTranslation(json, original));
    assert.deepEqual(ecarts, ["groupe d'ingrédients 1 : 2 ligne(s) pour 3"]);
  });

  test("un titre de groupe ou une introduction vidés sont rejetés", () => {
    const json = translatedJson();
    json.introduction = null;
    (json.sections_ingredients as Array<{ titre: string }>)[0].titre = "";
    const original = bananaBread();
    const ecarts = translationShapeMismatches(original, parseTranslation(json, original));
    assert.deepEqual(ecarts, ["introduction vide", "groupe d'ingrédients 1 : titre vide"]);
  });

  test("une étape vidée, une note perdue, un groupe en trop sont rejetés", () => {
    const json = translatedJson();
    (json.sections_etapes as Array<{ etapes: string[] }>)[0].etapes[1] = "  ";
    json.notes = [];
    (json.sections_ingredients as unknown[]).push({ titre: "", lignes: ["sel"] });
    const original = bananaBread();
    const ecarts = translationShapeMismatches(original, parseTranslation(json, original));
    assert.deepEqual(ecarts, [
      "2 groupe(s) d'ingrédients pour 1",
      "groupe d'étapes 1 : étape vide",
      "0 note(s) pour 1",
    ]);
  });
});

describe("texte d'origine", () => {
  test("le sous-document garde la page telle qu'elle était écrite", () => {
    const original = bananaBread();
    const doc = originalTextDocument({ langue: "en", recette: original }, "now");
    assert.deepEqual(doc, {
      langue: "en",
      titre: "Banana bread",
      introduction: "A classic loaf.",
      portions: 8,
      temps_preparation: "15 min",
      temps_cuisson: "1 hour",
      temps_repos: null,
      sections_ingredients: original.sectionsIngredients,
      sections_etapes: original.sectionsEtapes,
      notes: original.notes,
      created_at: "now",
    });
  });

  test("une recette traduite survit au point de reprise sans être retraduite", () => {
    const original = bananaBread();
    const traduite = parseTranslation(translatedJson(), original);
    const raw = serializeCheckpoint({
      pageType: "recipe",
      titre: "Page",
      page: 42,
      raison: "recette",
      document: "",
      recettes: [traduite],
    });
    const relue = parseCheckpoint(raw)!.recettes[0];
    assert.equal(needsTranslation(relue), false);
    assert.equal(relue.traduction?.langue, "en");
    assert.equal(relue.traduction?.recette.titre, "Banana bread");
    assert.deepEqual(relue.sectionsIngredients, traduite.sectionsIngredients);
  });
});
