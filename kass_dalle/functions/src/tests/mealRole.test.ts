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
  MAIN_PROTEINS,
  MAIN_STARCHES,
  MEAL_ROLES,
  ROLES_WITH_MAIN_INGREDIENTS,
  needsSide,
  normalizeRoleKey,
  parseMealContains,
  parseMealRole,
  mainIngredientsPatch,
  parseMainProtein,
  parseMainProteinStarch,
  parseMainStarch,
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

describe("protéine et féculent principaux", () => {
  test("les valeurs admises passent, accent, casse et ligature compris", () => {
    assert.equal(parseMainProtein("boeuf"), "boeuf");
    assert.equal(parseMainProtein("Bœuf"), "boeuf");
    assert.equal(parseMainProtein("Fruits de mer"), "fruits_de_mer");
    assert.equal(parseMainProtein("œufs"), "oeuf");
    assert.equal(parseMainProtein("Végétarien"), "vegetarien");
    assert.equal(parseMainProtein("légumineuses"), "legumineuses");
    assert.equal(parseMainStarch("Pâtes"), "pates");
    assert.equal(parseMainStarch("pommes de terre"), "pommes_de_terre");
    assert.equal(parseMainStarch("aucun"), "aucun");
  });

  test("une valeur hors liste ne se range pas dans une valeur voisine", () => {
    assert.equal(parseMainProtein("veau"), null);
    assert.equal(parseMainProtein("poulet"), null);
    assert.equal(parseMainProtein("viande"), null);
    assert.equal(parseMainStarch("quinoa"), null);
    assert.equal(parseMainStarch("polenta"), null);
    assert.equal(parseMainProtein(3), null);
    assert.equal(parseMainStarch(undefined), null);
  });

  test("lecture sans rôle : pour le backfill, dont le rôle est déjà connu", () => {
    assert.deepEqual(parseMainProteinStarch({ main_protein: "porc", main_starch: "riz" }), {
      mainProtein: "porc",
      mainStarch: "riz",
      mainIngredientsChecked: true,
    });
    assert.deepEqual(parseMainProteinStarch({ main_protein: "veau" }), {
      mainProtein: null,
      mainStarch: null,
      mainIngredientsChecked: true,
    });
  });
});

describe("lecture d'une réponse", () => {
  test("sans rôle reconnu, rien n'est gardé", () => {
    assert.deepEqual(
      parseMealRoleFields({ contains: ["proteine"], suggested_sides: ["riz"] }),
      EMPTY_MEAL_ROLE_FIELDS,
    );
  });

  test("un dessert ne porte ni accompagnement, ni protéine, ni féculent", () => {
    assert.deepEqual(
      parseMealRoleFields({
        meal_role: "dessert",
        suggested_sides: ["riz"],
        main_protein: "oeuf",
        main_starch: "pain",
      }),
      {
        mealRole: "dessert",
        contains: [],
        suggestedSides: [],
        mainProtein: null,
        mainStarch: null,
        mainIngredientsChecked: false,
      },
    );
  });

  test("un plat garde tout", () => {
    assert.deepEqual(
      parseMealRoleFields({
        meal_role: "Plat",
        contains: ["proteine"],
        suggested_sides: ["riz", "pommes vapeur"],
        main_protein: "volaille",
        main_starch: "aucun",
      }),
      {
        mealRole: "plat",
        contains: ["proteine"],
        suggestedSides: ["riz", "pommes vapeur"],
        mainProtein: "volaille",
        mainStarch: "aucun",
        mainIngredientsChecked: true,
      },
    );
  });

  test("un accompagnement garde protéine et féculent, pas de suggestion", () => {
    assert.deepEqual(
      parseMealRoleFields({
        meal_role: "accompagnement",
        contains: ["feculent"],
        main_protein: "vegetarien",
        main_starch: "pommes de terre",
      }),
      {
        mealRole: "accompagnement",
        contains: ["feculent"],
        suggestedSides: [],
        mainProtein: "vegetarien",
        mainStarch: "pommes_de_terre",
        mainIngredientsChecked: true,
      },
    );
  });

  test("une protéine hors liste est absente, le reste passe", () => {
    const out = parseMealRoleFields({
      meal_role: "plat",
      main_protein: "veau",
      main_starch: "riz",
    });
    assert.equal(out.mainProtein, null);
    assert.equal(out.mainStarch, "riz");
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

describe("nom d'une propriété héritée", () => {
  const fixturePath = path.join(__dirname, "..", "..", "..", "test-fixtures", "meal_roles.json");
  const fixture = JSON.parse(readFileSync(fixturePath, "utf8")) as { unsafe_keys: string[] };
  for (const key of fixture.unsafe_keys) {
    test(`« ${key} » est hors liste partout`, () => {
      assert.equal(parseMealRole(key), null);
      assert.deepEqual(parseMealContains([key]), []);
      assert.equal(parseMainProtein(key), null);
      assert.equal(parseMainStarch(key), null);
    });
  }
});

describe("protéine et féculent : la question a-t-elle reçu une réponse ?", () => {
  test("une valeur hors liste est une réponse : la recette est examinée", () => {
    const out = parseMealRoleFields({ meal_role: "plat", main_protein: "veau", main_starch: "" });
    assert.equal(out.mainProtein, null);
    assert.equal(out.mainIngredientsChecked, true);
    assert.deepEqual(parseMainProteinStarch({ main_protein: "lapin", main_starch: "polenta" }), {
      mainProtein: null,
      mainStarch: null,
      mainIngredientsChecked: true,
    });
  });

  test("deux chaînes vides ou des clés absentes : pas de réponse", () => {
    assert.equal(
      parseMainProteinStarch({ main_protein: "", main_starch: " " }).mainIngredientsChecked,
      false,
    );
    assert.equal(parseMainProteinStarch({}).mainIngredientsChecked, false);
    assert.equal(parseMainProteinStarch({ main_protein: 3 }).mainIngredientsChecked, false);
  });

  test("un dessert n'est jamais marqué examiné", () => {
    assert.equal(
      parseMealRoleFields({ meal_role: "dessert", main_protein: "oeuf" }).mainIngredientsChecked,
      false,
    );
  });
});

describe("backfill : seuls les champs absents sont écrits", () => {
  test("recette vide : protéine et féculent", () => {
    assert.deepEqual(mainIngredientsPatch({}, { mainProtein: "porc", mainStarch: "riz" }), {
      main_protein: "porc",
      main_starch: "riz",
    });
  });

  test("féculent déjà posé à la main : gardé", () => {
    assert.deepEqual(
      mainIngredientsPatch(
        { main_starch: "semoule" },
        { mainProtein: "agneau", mainStarch: "riz" },
      ),
      { main_protein: "agneau" },
    );
  });

  test("protéine déjà posée : gardée ; valeur vide en base : remplacée", () => {
    assert.deepEqual(
      mainIngredientsPatch(
        { main_protein: "boeuf", main_starch: "" },
        { mainProtein: "porc", mainStarch: "pates" },
      ),
      { main_starch: "pates" },
    );
  });

  test("réponse hors liste : rien à écrire hors le marqueur", () => {
    assert.deepEqual(mainIngredientsPatch({}, { mainProtein: null, mainStarch: null }), {});
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

  // Le client affiche ces valeurs dans « Catégorisation » ; une clé de plus
  // ici sans son libellé là-bas s'afficherait sous sa forme technique.
  test("protéines, féculents et rôles qui les portent : mêmes listes que côté client", () => {
    const fixturePath = path.join(__dirname, "..", "..", "..", "test-fixtures", "meal_roles.json");
    const fixture = JSON.parse(readFileSync(fixturePath, "utf8")) as {
      main_proteins: string[];
      main_starches: string[];
      roles_with_main_ingredients: string[];
    };
    assert.deepEqual([...MAIN_PROTEINS], fixture.main_proteins);
    assert.deepEqual([...MAIN_STARCHES], fixture.main_starches);
    assert.deepEqual([...ROLES_WITH_MAIN_INGREDIENTS], fixture.roles_with_main_ingredients);
  });
});
