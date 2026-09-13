/**
 * Idées de repas sur une consigne : lecture de la réponse et composition du
 * prompt.
 *
 * Logique pure : ni Firestore, ni réseau, ni appel de modèle. Ce que ces tests
 * gardent : une réponse mal formée ne passe pas pour « trois idées », un titre
 * en double ne compte pas deux fois, et la consigne comme les titres déjà rendus
 * sont bien dans le prompt — sans exemple rempli qui orienterait le modèle.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import { MEAL_IDEAS_COUNT, buildMealIdeasPrompt, parseMealIdeas } from "../gemini/mealIdeas";

describe("parseMealIdeas", () => {
  test("trois idées complètes sont lues telles quelles", () => {
    const ideas = parseMealIdeas({
      idees: [
        {
          titre: "Dahl de lentilles corail",
          description: "Lentilles, lait de coco, riz.",
          preparation_min: 10,
          cuisson_min: 25,
        },
        {
          titre: "Omelette aux herbes",
          description: "Œufs, ciboulette, salade verte.",
          preparation_min: 5,
          cuisson_min: 8,
        },
        {
          titre: "Soupe de courge rôtie",
          description: "Courge, oignon, crème.",
          preparation_min: 15,
          cuisson_min: 40,
        },
      ],
    });
    assert.ok(ideas);
    assert.equal(ideas.length, MEAL_IDEAS_COUNT);
    assert.deepEqual(ideas[0], {
      titre: "Dahl de lentilles corail",
      description: "Lentilles, lait de coco, riz.",
      prepMinutes: 10,
      cookMinutes: 25,
    });
  });

  test("une durée absente, négative ou non numérique devient null", () => {
    const ideas = parseMealIdeas({
      idees: [
        { titre: "Salade composée", description: "", cuisson_min: -3 },
        { titre: "Tartines", description: "", preparation_min: "cinq" },
      ],
    });
    assert.ok(ideas);
    assert.equal(ideas[0].prepMinutes, null);
    assert.equal(ideas[0].cookMinutes, null);
    assert.equal(ideas[1].prepMinutes, null);
  });

  test("une durée décimale est arrondie", () => {
    const ideas = parseMealIdeas({
      idees: [{ titre: "Riz sauté", description: "", preparation_min: 12.6 }],
    });
    assert.ok(ideas);
    assert.equal(ideas[0].prepMinutes, 13);
  });

  test("un titre vide est ignoré, un titre en double ne compte qu'une fois", () => {
    const ideas = parseMealIdeas({
      idees: [
        { titre: "  ", description: "rien" },
        { titre: "Gratin dauphinois", description: "a" },
        { titre: "gratin dauphinois", description: "b" },
        { titre: "Poulet rôti", description: "c" },
      ],
    });
    assert.ok(ideas);
    assert.deepEqual(
      ideas.map((i) => i.titre),
      ["Gratin dauphinois", "Poulet rôti"],
    );
  });

  test("au-delà de trois, le surplus est coupé", () => {
    const ideas = parseMealIdeas({
      idees: [1, 2, 3, 4, 5].map((n) => ({ titre: `Plat ${n}`, description: "" })),
    });
    assert.ok(ideas);
    assert.equal(ideas.length, MEAL_IDEAS_COUNT);
  });

  test("une forme inattendue rend null", () => {
    assert.equal(parseMealIdeas(null), null);
    assert.equal(parseMealIdeas([]), null);
    assert.equal(parseMealIdeas({ idees: "non" }), null);
    assert.equal(parseMealIdeas({ idees: [{ description: "sans titre" }] }), null);
  });
});

describe("buildMealIdeasPrompt", () => {
  test("porte la consigne, les préférences et les titres déjà rendus", () => {
    const prompt = buildMealIdeasPrompt({
      prompt: "un plat léger sans viande pour ce soir",
      globalConstraints: "pas de champignons",
      previousTitles: ["Dahl de lentilles corail", "  ", "Omelette aux herbes"],
    });
    assert.match(prompt, /un plat léger sans viande pour ce soir/);
    assert.match(prompt, /pas de champignons/);
    assert.match(prompt, /- Dahl de lentilles corail/);
    assert.match(prompt, /- Omelette aux herbes/);
    assert.match(prompt, new RegExp(`exactement ${MEAL_IDEAS_COUNT} idées`));
  });

  test("sans préférences ni titres, leurs sections n'apparaissent pas", () => {
    const prompt = buildMealIdeasPrompt({ prompt: "des pâtes" });
    assert.doesNotMatch(prompt, /PRÉFÉRENCES GÉNÉRALES/);
    assert.doesNotMatch(prompt, /DÉJÀ PROPOSÉ/);
  });

  test("le format de réponse décrit les clés sans exemple rempli", () => {
    const prompt = buildMealIdeasPrompt({ prompt: "des pâtes" });
    assert.match(prompt, /"idees"/);
    assert.match(prompt, /"preparation_min"/);
    // Un exemple rempli — un plat nommé dans le format — oriente le modèle
    // vers cet exemple. Le format ne nomme aucun plat.
    assert.doesNotMatch(prompt, /"titre": "[^"]+"/);
  });
});
