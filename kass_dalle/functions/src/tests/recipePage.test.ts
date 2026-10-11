/**
 * Lecture d'une page web de recette : JSON-LD `schema.org/Recipe` (`@graph`,
 * tableaux, `HowToSection` / `HowToStep`, durées ISO 8601, `recipeYield`,
 * image), projection dans la forme de la transcription, et texte principal
 * d'une page sans données structurées.
 *
 * Les pages sont des fixtures HTML réduites, dans `fixtures/web/`.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";

import {
  JSON_LD_BOUNDS,
  decodeEntities,
  exceedsJsonLdBounds,
  extractJsonLdRecipes,
  extractMainText,
  formatMinutes,
  isCompleteRecipe,
  isoDurationMinutes,
  parseRecipePage,
  projectJsonLdRecipe,
  readYield,
} from "../web/recipePage";

function fixture(name: string): string {
  return readFileSync(
    path.join(__dirname, "..", "..", "src", "tests", "fixtures", "web", name),
    "utf8",
  );
}

describe("durées ISO 8601", () => {
  test("PT20M, PT1H5M, P1DT2H, PT0.5H", () => {
    assert.equal(isoDurationMinutes("PT20M"), 20);
    assert.equal(isoDurationMinutes("PT1H5M"), 65);
    assert.equal(isoDurationMinutes("P1DT2H"), 1560);
    assert.equal(isoDurationMinutes("PT0.5H"), 30);
  });
  test("une valeur illisible rend null", () => {
    assert.equal(isoDurationMinutes("20 minutes"), null);
    assert.equal(isoDurationMinutes("PT"), null);
    assert.equal(isoDurationMinutes(42), null);
  });
  test("affichage", () => {
    assert.equal(formatMinutes(20), "20 min");
    assert.equal(formatMinutes(60), "1 h");
    assert.equal(formatMinutes(90), "1 h 30 min");
  });
});

describe("recipeYield", () => {
  test("nombre, chaîne, tableau", () => {
    assert.equal(readYield(4), 4);
    assert.equal(readYield("6 personnes"), 6);
    assert.equal(readYield(["8", "8 slices"]), 8);
    assert.equal(readYield("quelques-uns"), null);
  });
});

describe("entités", () => {
  test("nommées et numériques", () => {
    assert.equal(decodeEntities("cr&egrave;me &amp; &#233;pices &#x153;uf"), "crème & épices œuf");
  });
});

describe("JSON-LD", () => {
  test("@graph, HowToStep, image ImageObject, durées et portions", () => {
    const page = parseRecipePage(fixture("graph_howtostep.html"), "https://www.site.fr/quiche");
    assert.equal(page.recipes.length, 1);
    const r = page.recipes[0];
    assert.equal(r.name, "Quiche lorraine");
    assert.deepEqual(r.ingredients, [
      "1 pâte brisée",
      "200 g de lardons",
      "3 œufs",
      "20 cl de crème fraîche",
    ]);
    assert.deepEqual(r.stepSections, [
      {
        titre: "",
        etapes: [
          "Préchauffer le four à 180 °C.",
          "Faire revenir les lardons.",
          "Battre œufs et crème, verser, cuire 45 min.",
        ],
      },
    ]);
    assert.equal(r.recipeYield, 6);
    assert.equal(r.prepTime, "20 min");
    assert.equal(r.cookTime, "45 min");
    assert.equal(r.image, "https://cdn.example.com/quiche.jpg");
    assert.equal(page.ogImage, "https://www.site.fr/img/og-quiche.jpg");
    assert.equal(page.htmlLang, "fr-FR");
    assert.ok(isCompleteRecipe(r));
  });

  test("HowToSection, tableau racine, langue de la recette", () => {
    const page = parseRecipePage(fixture("sections_english.html"), "https://example.org/b");
    const r = page.recipes[0];
    assert.deepEqual(r.stepSections, [
      { titre: "Batter", etapes: ["Mash the bananas.", "Stir in the butter and sugar."] },
      { titre: "Baking", etapes: ["Bake for 1 hour at 350°F."] },
    ]);
    assert.equal(r.recipeYield, 8);
    assert.equal(r.cookTime, "1 h");
    const projected = projectJsonLdRecipe(r, page.htmlLang);
    assert.equal(projected.langue, "en");
    assert.deepEqual(projected.inventaire?.sections, ["Batter", "Baking"]);
    assert.equal(projected.inventaire?.etapes, 3);
    assert.equal(projected.portions, 8);
    assert.equal(projected.page, null);
  });

  test("ItemList de deux recettes, bloc illisible signalé, chaînes multilignes", () => {
    const { recipes, invalidBlocks } = extractJsonLdRecipes(
      fixture("two_recipes_invalid_block.html"),
    );
    assert.equal(invalidBlocks.length, 1);
    assert.deepEqual(
      recipes.map((r) => r.name),
      ["Crêpes", "Gaufres"],
    );
    assert.deepEqual(recipes[0].ingredients, ["250 g de farine", "4 œufs", "50 cl de lait"]);
    assert.equal(recipes[0].stepSections[0].etapes.length, 3);
    assert.equal(recipes[0].recipeYield, 4);
  });

  test("une recette sans étapes n'est pas complète", () => {
    const html =
      '<script type="application/ld+json">{"@type":"Recipe","name":"X","recipeIngredient":["a"]}</script>';
    const { recipes } = extractJsonLdRecipes(html);
    assert.equal(recipes.length, 1);
    assert.equal(isCompleteRecipe(recipes[0]), false);
  });

  test("une projection française reste en français", () => {
    const page = parseRecipePage(fixture("graph_howtostep.html"), "https://www.site.fr/quiche");
    const projected = projectJsonLdRecipe(page.recipes[0], page.htmlLang);
    assert.equal(projected.langue, "fr");
    assert.equal(projected.introduction, "La vraie, sans fromage.");
    assert.deepEqual(projected.sectionsIngredients[0].lignes.length, 4);
  });
});

describe("texte principal", () => {
  test("sans scripts, styles, menus ni pied de page ; listes en puces", () => {
    const html = fixture("no_jsonld_blog.html");
    const page = parseRecipePage(html, "https://blog.example.fr/tarte");
    assert.equal(page.recipes.length, 0);
    assert.equal(page.ogImage, "https://blog.example.fr/photos/tarte.jpg");
    const text = extractMainText(html);
    assert.ok(text.includes("Ma tarte aux pommes de grand-mère"));
    assert.ok(text.includes("- 4 pommes"));
    assert.ok(text.replace(/\u00a0/g, " ").includes("Cuire 35 minutes à 200 °C."));
    for (const noise of ["tracking", "color: red", "Accueil", "mentions légales", "similaires"]) {
      assert.ok(!text.includes(noise), `le texte contient « ${noise} »`);
    }
  });

  test("tronqué à la borne", () => {
    const html = `<body><p>${"a".repeat(500)}</p></body>`;
    assert.equal(extractMainText(html, 100).length, 100);
  });
});

describe("bornes et pages piégées", () => {
  test("une recette JSON-LD hors bornes n'est pas complète", () => {
    const many = Array.from({ length: JSON_LD_BOUNDS.ingredients + 1 }, (_, i) => `${i} g`);
    const html = `<script type="application/ld+json">${JSON.stringify({
      "@type": "Recipe",
      name: "Trop",
      recipeIngredient: many,
      recipeInstructions: ["Mélanger."],
    })}</script>`;
    const { recipes } = extractJsonLdRecipes(html);
    assert.equal(exceedsJsonLdBounds(recipes[0]), true);
    assert.equal(isCompleteRecipe(recipes[0]), false);
    const longLine = { ...recipes[0], ingredients: ["x".repeat(JSON_LD_BOUNDS.lineChars + 1)] };
    assert.equal(exceedsJsonLdBounds(longLine), true);
  });

  test("balises jamais fermées : lecture en temps linéaire", () => {
    const trap =
      "<script type=application/ld+json>".repeat(20_000) +
      "<script".repeat(50_000) +
      "<article".repeat(50_000) +
      "<!--".repeat(50_000) +
      "<".repeat(200_000) +
      "<meta ".repeat(50_000);
    const started = Date.now();
    const page = parseRecipePage(trap, "https://a.fr/");
    assert.equal(page.recipes.length, 0);
    assert.ok(Date.now() - started < 2_000, `${Date.now() - started} ms`);
  });

  test("balise méta géante sans attribut : lecture en temps linéaire", () => {
    const trap = `<meta ${"a".repeat(8_180)}>`.repeat(375);
    const started = Date.now();
    parseRecipePage(trap, "https://a.fr/");
    assert.ok(Date.now() - started < 2_000, `${Date.now() - started} ms`);
  });

  test("le contenu d'un script n'est jamais lu comme du texte", () => {
    const html = `<body><p>${"Recette ".repeat(40)}</p><script>alert("x")</script><style>p{}</style></body>`;
    const text = extractMainText(html);
    assert.ok(!text.includes("alert"));
    assert.ok(!text.includes("p{}"));
  });
});
