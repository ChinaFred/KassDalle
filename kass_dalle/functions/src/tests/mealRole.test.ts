/**
 * Le rôle d'une recette dans un repas — lecture de la réponse du modèle.
 *
 * Une valeur mal lue ne lève rien : un « Entrée » avec accent tomberait à
 * `null`, la recette resterait sans rôle, et le planning la traiterait comme
 * un plat. Ces tests verrouillent ce qui passe, ce qui est ramené, et ce qui
 * est refusé.
 *
 * Logique pure : ni Firestore, ni réseau, ni appel de modèle.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import {
  EMPTY_MEAL_ROLE_FIELDS,
  MEAL_ROLES,
  needsSide,
  normalizeRoleKey,
  parseMealContains,
  parseMealRole,
  parseMealRoleFields,
  parseSuggestedSides,
} from "../gemini/mealRole";

describe("clé de comparaison", () => {
  test("minuscules, sans accent, tirets et espaces réduits", () => {
    assert.equal(normalizeRoleKey("  Petit-Déjeuner "), "petit dejeuner");
    assert.equal(normalizeRoleKey("Entrée"), "entree");
    assert.equal(normalizeRoleKey("plat_principal"), "plat principal");
  });
});

describe("rôle dans un repas", () => {
  test("les cinq valeurs passent, accent et casse compris", () => {
    assert.equal(parseMealRole("plat"), "plat");
    assert.equal(parseMealRole("Accompagnement"), "accompagnement");
    assert.equal(parseMealRole("Entrée"), "entree");
    assert.equal(parseMealRole("DESSERT"), "dessert");
    assert.equal(parseMealRole(" snack "), "snack");
  });

  test("les synonymes courants sont ramenés", () => {
    assert.equal(parseMealRole("plat principal"), "plat");
    assert.equal(parseMealRole("garniture"), "accompagnement");
    assert.equal(parseMealRole("goûter"), "snack");
    assert.equal(parseMealRole("petit-déjeuner"), "snack");
  });

  test("une valeur inconnue ne donne rien", () => {
    assert.equal(parseMealRole("boeuf"), null);
    assert.equal(parseMealRole(42), null);
    assert.equal(parseMealRole(undefined), null);
  });
});

describe("ce que la recette apporte", () => {
  test("ordre fixe, une fois chacun, accents tolérés", () => {
    assert.deepEqual(parseMealContains(["légume", "Protéine", "legumes"]), ["proteine", "legume"]);
  });

  test("hors liste ignoré", () => {
    assert.deepEqual(parseMealContains(["sauce", "feculent"]), ["feculent"]);
  });

  test("pas un tableau : rien", () => {
    assert.deepEqual(parseMealContains("feculent"), []);
  });
});

describe("accompagnements suggérés", () => {
  test("nettoyés, dédoublonnés, quatre au plus", () => {
    assert.deepEqual(
      parseSuggestedSides([
        "Riz",
        " riz ",
        "Purée",
        "purée de pommes de terre",
        "haricots  verts",
        "salade verte",
        "pain",
      ]),
      ["Riz", "Purée", "purée de pommes de terre", "haricots verts"],
    );
  });

  test("une phrase n'est pas une garniture", () => {
    const phrase = "servir avec un riz basmati parfumé et quelques légumes de saison";
    assert.deepEqual(parseSuggestedSides([phrase, "riz"]), ["riz"]);
  });

  test("pas un tableau : rien", () => {
    assert.deepEqual(parseSuggestedSides("riz"), []);
  });
});

describe("lecture d'une réponse", () => {
  test("sans rôle reconnu, rien n'est gardé", () => {
    assert.deepEqual(
      parseMealRoleFields({ contains: ["proteine"], suggested_sides: ["riz"] }),
      EMPTY_MEAL_ROLE_FIELDS,
    );
  });

  test("un dessert ne porte pas d'accompagnement", () => {
    assert.deepEqual(parseMealRoleFields({ meal_role: "dessert", suggested_sides: ["riz"] }), {
      mealRole: "dessert",
      contains: [],
      suggestedSides: [],
    });
  });

  test("un plat garde tout", () => {
    assert.deepEqual(
      parseMealRoleFields({
        meal_role: "Plat",
        contains: ["proteine"],
        suggested_sides: ["riz", "pommes vapeur"],
      }),
      { mealRole: "plat", contains: ["proteine"], suggestedSides: ["riz", "pommes vapeur"] },
    );
  });
});

describe("appelle un accompagnement", () => {
  test("un plat sans féculent en appelle un", () => {
    assert.equal(needsSide({ mealRole: "plat", contains: ["proteine", "legume"] }), true);
  });

  test("un plat sans légume en appelle un", () => {
    assert.equal(needsSide({ mealRole: "plat", contains: ["proteine", "feculent"] }), true);
  });

  test("un plat complet n'en appelle pas", () => {
    assert.equal(
      needsSide({ mealRole: "plat", contains: ["proteine", "feculent", "legume"] }),
      false,
    );
  });

  test("un plat végétarien avec féculent et légume n'en appelle pas", () => {
    assert.equal(needsSide({ mealRole: "plat", contains: ["feculent", "legume"] }), false);
  });

  test("les autres rôles n'en appellent jamais", () => {
    assert.equal(needsSide({ mealRole: "accompagnement", contains: [] }), false);
    assert.equal(needsSide({ mealRole: "dessert", contains: [] }), false);
    assert.equal(needsSide({ mealRole: null, contains: [] }), false);
  });
});

describe("fixture partagée avec le client", () => {
  // Le client propose ces rôles dans une liste et les affiche en français ;
  // un rôle de plus ici sans son jumeau là-bas se choisirait au backfill et ne
  // se verrait jamais dans le formulaire.
  test("la liste des rôles est la même que côté client", () => {
    const fixturePath = path.join(__dirname, "..", "..", "..", "test-fixtures", "meal_roles.json");
    const fixture = JSON.parse(readFileSync(fixturePath, "utf8")) as { roles: string[] };
    assert.deepEqual([...MEAL_ROLES], fixture.roles);
  });
});
