/**
 * La chaîne d'extraction en deux passes.
 *
 * Ce que ces tests verrouillent : la fidélité au livre est CONSTATÉE, pas
 * espérée. Un prompt qui demande de ne pas réécrire la recette et que rien ne
 * vérifie est un vœu — c'est ainsi qu'une recette résumée est partie en base
 * pendant des semaines sans qu'aucune erreur ne soit levée.
 */

import { test, describe } from "node:test";
import assert from "node:assert/strict";

import {
  parseTranscription,
  resolvePageType,
  type TranscribedRecipe,
} from "../gemini/transcription";
import { parseTagged, renderTranscriptionForTagging, ingredientLinesOf } from "../gemini/tagging";
import {
  checkFidelity,
  cooklangSectionTitles,
  cooklangStepLines,
  verbatimCooklang,
} from "../gemini/fidelity";
import { deriveShoppingProducts, numericQty } from "../nutrition/shoppingDerivation";

/** Une recette de livre à deux sections, telle que la passe 1 la rend. */
function gravlax(): TranscribedRecipe {
  return {
    titre: "Gravlax de saumon",
    page: 42,
    portions: 8,
    tempsPreparation: "30 min",
    tempsCuisson: null,
    difficulte: "moyen",
    sectionsIngredients: [
      {
        titre: "Pour le saumon",
        lignes: [
          "1 filet de saumon de 1,8 kg avec la peau mais écaillée",
          "200 g de gros sel",
          "1 bouquet d'aneth",
        ],
      },
      {
        titre: "Pour la sauce à l'aneth et à la moutarde",
        lignes: ["2 c. à soupe de moutarde", "1 bouquet d'aneth"],
      },
    ],
    sectionsEtapes: [
      {
        titre: "Pour le saumon",
        etapes: [
          "Posez le filet sur un plat.",
          "Recouvrez de gros sel.",
          "Laissez reposer 24 heures au réfrigérateur.",
        ],
      },
      {
        titre: "Pour la sauce à l'aneth et à la moutarde",
        etapes: ["Mélangez la moutarde et l'aneth ciselé."],
      },
    ],
    notes: [{ genre: "Le conseil du chef", texte: "Se conserve trois jours au frais." }],
  };
}

const gravlaxCooklang = [
  ">> titre: Gravlax de saumon",
  ">> portions: 8",
  "== Pour le saumon ==",
  "Posez le @filet de saumon{1.8%kg} sur un #plat{}.",
  "Recouvrez de @gros sel{200%g}.",
  "Laissez reposer ~{24%heures} au réfrigérateur.",
  "== Pour la sauce à l'aneth et à la moutarde ==",
  "Mélangez la @moutarde{2%c. à soupe} et l'@aneth{1%bouquet} ciselé.",
  "> Le conseil du chef : Se conserve trois jours au frais.",
].join("\n");

function taggedGravlax(over: Partial<ReturnType<typeof parseTagged>> = {}) {
  return {
    cooklang: gravlaxCooklang,
    ingredients: [
      {
        brut: "1 filet de saumon de 1,8 kg avec la peau mais écaillée",
        section: "Pour le saumon",
        nom: "filet de saumon",
        qte: "1.8",
        unite: "kg",
        note: "avec la peau mais écaillée",
      },
      {
        brut: "200 g de gros sel",
        section: "Pour le saumon",
        nom: "gros sel",
        qte: "200",
        unite: "g",
        note: "",
      },
      {
        brut: "1 bouquet d'aneth",
        section: "Pour le saumon",
        nom: "aneth",
        qte: "1",
        unite: "bouquet",
        note: "",
      },
      {
        brut: "2 c. à soupe de moutarde",
        section: "Pour la sauce à l'aneth et à la moutarde",
        nom: "moutarde",
        qte: "2",
        unite: "c. à soupe",
        note: "",
      },
      {
        brut: "1 bouquet d'aneth",
        section: "Pour la sauce à l'aneth et à la moutarde",
        nom: "aneth",
        qte: "1",
        unite: "bouquet",
        note: "",
      },
    ],
    cuisines: ["scandinave"],
    dishTypes: ["poisson"],
    ...over,
  };
}

describe("passe 1 — transcription", () => {
  test("une page annoncée recette sans une seule étape n'en est pas une", () => {
    // Le repli optimiste d'avant fabriquait une recette vide qu'il fallait
    // ensuite retrouver dans les brouillons.
    const out = parseTranscription({
      raison: "Présentation de produits du placard.",
      page_type: "recipe",
      titre: "Les épices",
      recettes: [],
    });
    assert.notEqual(out.pageType, "recipe");
  });

  test("une justification qui se contredit ne fait pas foi", () => {
    assert.equal(
      resolvePageType("recipe", "Cette page n'est pas une recette : elle décrit des produits."),
      "ingredient_note",
    );
    assert.equal(resolvePageType("recipe", "Séquence complète de préparation."), "recipe");
  });

  test("un type inconnu ne devient pas une recette par défaut", () => {
    assert.equal(resolvePageType("poème", "peu importe"), "other");
  });

  test("les lignes d'ingrédients sont conservées entières", () => {
    const out = parseTranscription({
      raison: "Étapes de fabrication.",
      page_type: "recipe",
      titre: "Gravlax",
      recettes: [
        {
          titre: "Gravlax",
          sections_ingredients: [
            { titre: "Pour le saumon", lignes: ["1 filet de saumon de 1,8 kg avec la peau"] },
          ],
          sections_etapes: [{ titre: "", etapes: ["Posez le filet."] }],
        },
      ],
    });
    assert.equal(out.recettes.length, 1);
    assert.equal(
      out.recettes[0].sectionsIngredients[0].lignes[0],
      "1 filet de saumon de 1,8 kg avec la peau",
    );
  });

  test("une section sans ligne ni étape ne pollue pas la sortie", () => {
    const out = parseTranscription({
      raison: "Étapes.",
      page_type: "recipe",
      titre: "T",
      recettes: [
        {
          titre: "T",
          sections_ingredients: [{ titre: "Vide", lignes: [] }],
          sections_etapes: [{ titre: "", etapes: ["Une étape."] }],
        },
      ],
    });
    assert.equal(out.recettes[0].sectionsIngredients.length, 0);
  });
});

describe("passe 2 — mise en forme de l'entrée", () => {
  test("les lignes et les étapes sont numérotées", () => {
    // Le modèle doit rendre autant d'entrées, dans le même ordre : un numéro
    // rend l'écart immédiatement lisible dans les journaux.
    const rendu = renderTranscriptionForTagging(gravlax());
    assert.match(rendu, /1\. 1 filet de saumon de 1,8 kg avec la peau mais écaillée/);
    assert.match(rendu, /5\. 1 bouquet d'aneth/);
    assert.match(rendu, /-- section : Pour la sauce à l'aneth et à la moutarde/);
  });

  test("un ingrédient sans nom est écarté, pas gardé à moitié", () => {
    const out = parseTagged({
      cooklang: "Texte.",
      ingredients: [
        { brut: "…", nom: "", qte: "2", unite: "g" },
        { brut: "sel", nom: "sel" },
      ],
    });
    assert.equal(out.ingredients.length, 1);
    assert.equal(out.ingredients[0].nom, "sel");
  });

  test("la note est reprise telle quelle", () => {
    const out = parseTagged({
      cooklang: "T",
      ingredients: [
        {
          brut: "1 filet de saumon de 1,8 kg avec la peau mais écaillée",
          nom: "filet de saumon",
          qte: "1.8",
          unite: "kg",
          note: "avec la peau mais écaillée",
        },
      ],
    });
    assert.equal(out.ingredients[0].note, "avec la peau mais écaillée");
  });
});

describe("contrôle de fidélité", () => {
  test("une recette balisée fidèlement passe sans réserve", () => {
    const report = checkFidelity(gravlax(), taggedGravlax());
    assert.equal(report.level, "ok", JSON.stringify(report.findings));
    assert.equal(report.rejette, false);
  });

  test("un ingrédient fusionné est une RUPTURE", () => {
    // Deux bouquets d'aneth dans deux sections font deux lignes du livre :
    // les fondre en une, c'est perdre un achat et fausser la nutrition.
    const tagged = taggedGravlax();
    tagged.ingredients = tagged.ingredients.slice(0, 4);
    const report = checkFidelity(gravlax(), tagged);
    assert.equal(report.rejette, true);
    assert.ok(report.findings.some((f) => f.code === "ingredients_compte"));
  });

  test("un ingrédient inventé avertit sans rejeter", () => {
    const tagged = taggedGravlax();
    tagged.ingredients = [...tagged.ingredients, { ...tagged.ingredients[0], nom: "poivre" }];
    const report = checkFidelity(gravlax(), tagged);
    assert.equal(report.level, "avertissement");
    assert.equal(report.rejette, false);
  });

  test("des étapes résumées sont une RUPTURE", () => {
    // Le défaut le plus grave : quatre phrases devenues une.
    const report = checkFidelity(
      gravlax(),
      taggedGravlax({ cooklang: ">> titre: Gravlax\nSalez le saumon et laissez reposer." }),
    );
    assert.equal(report.rejette, true);
    assert.ok(report.findings.some((f) => f.code === "etapes_compte"));
  });

  test("une étape de plus reste tolérée", () => {
    const avec = gravlaxCooklang.replace(
      "Recouvrez de @gros sel{200%g}.",
      "Recouvrez de @gros sel{200%g}.\nTassez bien.",
    );
    const report = checkFidelity(gravlax(), taggedGravlax({ cooklang: avec }));
    assert.equal(report.rejette, false);
  });

  test("un titre de section raccourci est signalé", () => {
    // « Pour la sauce à l'aneth et à la moutarde » devenu « Pour la sauce » :
    // aucun écran ne casse, et les deux sauces de la recette se confondent.
    const raccourci = gravlaxCooklang.replace(
      "== Pour la sauce à l'aneth et à la moutarde ==",
      "== Pour la sauce ==",
    );
    const report = checkFidelity(gravlax(), taggedGravlax({ cooklang: raccourci }));
    assert.ok(report.findings.some((f) => f.code === "sections_titres"));
    assert.equal(report.rejette, false);
  });

  test("la casse d'un titre ne compte pas pour un écart", () => {
    const majuscules = gravlaxCooklang
      .replace("== Pour le saumon ==", "== POUR LE SAUMON ==")
      .replace(
        "== Pour la sauce à l'aneth et à la moutarde ==",
        "== POUR LA SAUCE A L'ANETH ET A LA MOUTARDE ==",
      );
    const report = checkFidelity(gravlax(), taggedGravlax({ cooklang: majuscules }));
    assert.equal(report.findings.filter((f) => f.code === "sections_titres").length, 0);
  });

  test("un balisage vide est rejeté", () => {
    const report = checkFidelity(gravlax(), taggedGravlax({ cooklang: "   " }));
    assert.equal(report.rejette, true);
  });
});

describe("lecture d'un texte CookLang", () => {
  test("métadonnées, sections et notes ne comptent pas pour des étapes", () => {
    assert.equal(cooklangStepLines(gravlaxCooklang).length, 4);
  });

  test("une continuation appartient à l'étape précédente", () => {
    assert.equal(cooklangStepLines("Première étape.\n+ suite de la première.").length, 1);
  });

  test("les titres de section sont lus dans l'ordre", () => {
    assert.deepEqual(cooklangSectionTitles(gravlaxCooklang), [
      "Pour le saumon",
      "Pour la sauce à l'aneth et à la moutarde",
    ]);
  });
});

describe("repli verbatim", () => {
  test("le texte du livre survit au rejet du balisage", () => {
    const out = verbatimCooklang(gravlax());
    assert.match(out, /Posez le filet sur un plat\./);
    assert.match(out, /== Pour la sauce à l'aneth et à la moutarde ==/);
    assert.match(out, /> Le conseil du chef : Se conserve trois jours au frais\./);
    // Sans balise : mieux vaut exact et non balisé que balisé et faux.
    assert.equal(out.includes("@"), false);
  });

  test("autant d'étapes qu'à la transcription", () => {
    const recipe = gravlax();
    assert.equal(cooklangStepLines(verbatimCooklang(recipe)).length, 4);
    assert.equal(ingredientLinesOf(recipe).length, 5);
  });
});

describe("produits d'achat dérivés", () => {
  test("le même ingrédient dans deux sections fait un seul achat", () => {
    // Deux cuillères de sauce soja pour la farce et six pour la sauce font une
    // seule bouteille : c'est la différence entre la liste de courses et la
    // liste d'ingrédients.
    const out = deriveShoppingProducts([
      { name: "sauce soja claire", qty: "2", unit: "c. à soupe" },
      { name: "porc haché", qty: "250", unit: "g" },
      { name: "sauce soja claire", qty: "6", unit: "c. à soupe" },
    ]);
    assert.equal(out.length, 2);
    assert.deepEqual(out[0], { name: "sauce soja claire", qty: "8", unit: "c. à soupe" });
  });

  test("deux unités incompatibles restent deux lignes", () => {
    // Additionner supposerait un taux de conversion, et un taux inventé produit
    // une quantité fausse présentée comme exacte.
    const out = deriveShoppingProducts([
      { name: "ail", qty: "2", unit: "gousse" },
      { name: "ail", qty: "1", unit: "c. à café" },
    ]);
    assert.equal(out.length, 2);
  });

  test("une quantité non chiffrable n'est pas jetée", () => {
    const out = deriveShoppingProducts([{ name: "huile", qty: "à volonté", unit: "" }]);
    assert.equal(out.length, 1);
    assert.equal(out[0].qty, "à volonté");
  });

  test("le chiffrable et le non-chiffrable se lisent ensemble", () => {
    const out = deriveShoppingProducts([
      { name: "huile", qty: "2", unit: "c. à soupe" },
      { name: "huile", qty: "pour la friture", unit: "c. à soupe" },
    ]);
    assert.equal(out[0].qty, "2 + pour la friture");
  });

  test("les fractions des livres de cuisine s'additionnent", () => {
    assert.equal(numericQty("2½"), 2.5);
    assert.equal(numericQty("½"), 0.5);
    assert.equal(numericQty("1/2"), 0.5);
    assert.equal(numericQty("1,5"), 1.5);
    assert.equal(numericQty("qsp"), null);
    assert.equal(numericQty(""), null);
  });

  test("le pluriel d'une unité ne crée pas un second produit", () => {
    const out = deriveShoppingProducts([
      { name: "oeuf", qty: "2", unit: "pièce" },
      { name: "oeuf", qty: "1", unit: "pièces" },
    ]);
    assert.equal(out.length, 1);
    assert.equal(out[0].qty, "3");
  });

  test("un ingrédient sans nom ne devient pas une ligne fantôme", () => {
    assert.equal(deriveShoppingProducts([{ name: "  ", qty: "2", unit: "g" }]).length, 0);
  });
});
