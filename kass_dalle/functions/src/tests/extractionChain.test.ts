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
  checkTranscriptionInventory,
  cooklangSectionTitles,
  cooklangStepLines,
  significantWords,
  stripCooklangTags,
  verbatimCooklang,
} from "../gemini/fidelity";
import { deriveShoppingProducts, numericQty } from "../nutrition/shoppingDerivation";
import { TEXT_TRANSCRIPTION_PREAMBLE, TRANSCRIPTION_PROMPT } from "../gemini/promptsExtraction";

/** Une recette de livre à deux sections, telle que la passe 1 la rend. */
function gravlax(): TranscribedRecipe {
  return {
    titre: "Gravlax de saumon",
    introduction: "Une méthode scandinave pour fumer le saumon dans le sel.",
    lecturesIncertaines: [],
    page: 42,
    portions: 8,
    tempsPreparation: "30 min",
    tempsCuisson: null,
    tempsRepos: null,
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
    mealRole: null,
    contains: [],
    suggestedSides: [],
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

  test("un ingrédient fusionné est SIGNALÉ, sans faire jeter le balisage", () => {
    // Deux bouquets d'aneth dans deux sections font deux lignes du livre : les
    // fondre en une, c'est perdre un achat et fausser la nutrition. Il faut
    // donc le dire.
    //
    // Mais pas jeter le travail. Ce contrôle rapproche des CHAÎNES : il
    // constate une correspondance manquante, pas une perte de contenu. En
    // faire une rupture a coûté une recette entière dont les deux ingrédients
    // étaient présents — la transcription avait coupé une ligne en deux, le
    // balisage l'avait gardée entière, et rien ne s'alignait.
    const tagged = taggedGravlax();
    tagged.ingredients = tagged.ingredients.slice(0, 4);
    const report = checkFidelity(gravlax(), tagged);
    assert.equal(report.rejette, false);
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

describe("ce que le contrôle ne voyait pas — cas réels", () => {
  test("une clause disparue d'une étape est attrapée, à décompte égal", () => {
    // « la moutarde mélangée à deux cuillères à café de miel » devenue « la
    // moutarde » : même nombre d'étapes, un ingrédient de moins dans la
    // recette et dans les courses. Le décompte ne pouvait rien voir.
    const recette: TranscribedRecipe = {
      ...gravlax(),
      sectionsEtapes: [
        {
          titre: "",
          etapes: [
            "Fouettez la moutarde mélangée à deux cuillères à café de miel liquide.",
            "Incorporez lentement l'huile de tournesol en filet continu.",
          ],
        },
      ],
      notes: [],
      introduction: "",
      sectionsIngredients: [],
    };
    const ampute = checkFidelity(recette, {
      ...taggedGravlax(),
      ingredients: [],
      cooklang: "Fouettez la @moutarde{}.\nIncorporez lentement l'@huile de tournesol{}.",
    });
    assert.ok(
      ampute.findings.some((f) => f.code === "texte_perdu"),
      JSON.stringify(ampute.findings),
    );
  });

  test("le texte fidèlement balisé garde sa couverture", () => {
    const recette: TranscribedRecipe = {
      ...gravlax(),
      sectionsEtapes: [
        {
          titre: "",
          etapes: ["Fouettez la moutarde mélangée à deux cuillères à café de miel liquide."],
        },
      ],
      notes: [],
      introduction: "",
      sectionsIngredients: [],
    };
    const fidele = checkFidelity(recette, {
      ...taggedGravlax(),
      ingredients: [],
      cooklang: "Fouettez la @moutarde{2%c. à soupe} mélangée à @miel liquide{2%c. à café}.",
    });
    assert.equal(
      fidele.findings.some((f) => f.code === "texte_perdu"),
      false,
      JSON.stringify(fidele.findings),
    );
  });

  test("un ingrédient que sa propre ligne dément est nommé", () => {
    // « 4 cuil. à soupe d'aneth frais » ne peut pas donner « aneth en poudre » :
    // ce n'est pas une reformulation, c'est un autre produit.
    const report = checkFidelity(gravlax(), {
      ...taggedGravlax(),
      ingredients: [
        {
          brut: "4 cuil. à soupe d'aneth frais",
          section: "",
          nom: "aneth en poudre",
          qte: "4",
          unite: "c. à soupe",
          note: "",
        },
      ],
    });
    const trouve = report.findings.find((f) => f.code === "ingredient_invente");
    assert.ok(trouve, JSON.stringify(report.findings));
    // Le détail vit dans `items` : l’écran le rend en puces, parce que sept
    // constats concaténés dans une phrase forment un pavé qu’on ne relit pas.
    const detail = (trouve.items ?? []).join(" ");
    assert.match(detail, /poudre/);
    assert.match(detail, /aneth frais/);
  });

  test("un nom simplifié par rapport à sa ligne ne déclenche rien", () => {
    // « 250 g de porc haché » → « porc haché » retire des mots, n'en ajoute
    // pas : c'est exactement le travail demandé.
    const report = checkFidelity(gravlax(), {
      ...taggedGravlax(),
      ingredients: [
        {
          brut: "250 g de porc haché",
          section: "",
          nom: "porc haché",
          qte: "250",
          unite: "g",
          note: "",
        },
      ],
    });
    assert.equal(
      report.findings.some((f) => f.code === "ingredient_invente"),
      false,
    );
  });

  test("une note perdue au balisage est signalée", () => {
    // Rien d'autre ne la porte : ni les étapes, ni les ingrédients. Elle
    // disparaîtrait sans laisser de trace.
    const sansNote = gravlaxCooklang.replace(
      "> Le conseil du chef : Se conserve trois jours au frais.",
      "",
    );
    const report = checkFidelity(gravlax(), taggedGravlax({ cooklang: sansNote }));
    assert.ok(
      report.findings.some((f) => f.code === "notes_perdues"),
      JSON.stringify(report.findings),
    );
  });

  test("les balises sont retirées avant toute comparaison", () => {
    assert.equal(
      stripCooklangTags("Mélangez @aneth frais{4%c. à soupe} et ~{20%minutes} au #saladier{}.")
        .replace(/\s+/g, " ")
        .trim(),
      // Le contenu des accolades est CONSERVÉ : les quantités quittent
      // légitimement la phrase pour y entrer, et les jeter ferait accuser un
      // balisage fidèle d'avoir perdu un tiers de la page.
      "Mélangez aneth frais 4 c. à soupe et 20 minutes au saladier .",
    );
  });

  test("les mots courts et les chiffres ne pèsent pas dans la comparaison", () => {
    // « deux » dans la phrase peut légitimement devenir « 2 » dans une
    // accolade : compter cet écart ferait échouer un balisage correct.
    const mots = significantWords("Ajoutez 2 c. à café de miel liquide");
    assert.equal(mots.has("miel"), true);
    assert.equal(mots.has("liquide"), true);
    assert.equal(mots.has("de"), false);
    assert.equal(mots.has("2"), false);
  });
});

describe("inventaire déclaré par la passe 1", () => {
  test("une section vue mais non transcrite est signalée", () => {
    // Le trou que rien d'autre ne pouvait voir : tous les autres contrôles
    // comparent la passe 2 à la passe 1, et sont donc aveugles à ce que la
    // passe 1 elle-même a perdu.
    const recette: TranscribedRecipe = {
      ...gravlax(),
      inventaire: {
        sections: ["Pour le saumon", "Pour la sauce à l'aneth et à la moutarde", "Pour le service"],
        lignesIngredients: 5,
        etapes: 4,
      },
    };
    const findings = checkTranscriptionInventory(recette);
    const trouve = findings.find((f) => f.code === "section_non_transcrite");
    assert.ok(trouve, JSON.stringify(findings));
    assert.match((trouve.items ?? []).join(" "), /Pour le service/);
  });

  test("un inventaire qui tombe juste ne dit rien", () => {
    const recette: TranscribedRecipe = {
      ...gravlax(),
      inventaire: {
        sections: ["POUR LE SAUMON", "Pour la sauce à l'aneth et à la moutarde"],
        lignesIngredients: 5,
        etapes: 4,
      },
    };
    assert.deepEqual(checkTranscriptionInventory(recette), []);
  });

  test("des lignes ou des étapes manquantes sont comptées", () => {
    const recette: TranscribedRecipe = {
      ...gravlax(),
      inventaire: { sections: [], lignesIngredients: 9, etapes: 12 },
    };
    const codes = checkTranscriptionInventory(recette).map((f) => f.code);
    assert.ok(codes.includes("lignes_non_transcrites"));
    assert.ok(codes.includes("etapes_non_transcrites"));
  });

  test("une transcription plus riche que son annonce ne déclenche rien", () => {
    // Compter est approximatif : un modèle qui annonce trois étapes et en rend
    // quatre a peut-être découpé une phrase. Ce n'est pas une perte.
    const recette: TranscribedRecipe = {
      ...gravlax(),
      inventaire: { sections: [], lignesIngredients: 2, etapes: 1 },
    };
    assert.deepEqual(checkTranscriptionInventory(recette), []);
  });

  test("sans inventaire, aucun verdict — les anciennes recettes ne sont pas accusées", () => {
    assert.deepEqual(checkTranscriptionInventory(gravlax()), []);
  });

  test("le verdict d'inventaire reste un avertissement, jamais une rupture", () => {
    // Cette déclaration est produite par le modèle lui-même : s'y fier pour
    // jeter son travail reviendrait à lui demander de s'auto-condamner.
    const recette: TranscribedRecipe = {
      ...gravlax(),
      inventaire: { sections: ["Pour le service"], lignesIngredients: 99, etapes: 99 },
    };
    const report = checkFidelity(recette, taggedGravlax());
    assert.equal(report.rejette, false, JSON.stringify(report.findings));
    assert.ok(report.findings.some((f) => f.code === "section_non_transcrite"));
  });
});

describe("erreur de lecture — le seul défaut que rien ne peut prouver", () => {
  test("un doute déclaré remonte jusqu'à la recette", () => {
    // « peau en dessous » lu « peu profonde en dessous » : la phrase rendue est
    // impeccable, seulement elle ne dit plus la même chose. Aucun décompte,
    // aucune couverture de mots ne peut s'en émouvoir — la transcription EST
    // la référence de tous les autres contrôles.
    const recette: TranscribedRecipe = {
      ...gravlax(),
      lecturesIncertaines: ["peau en dessous"],
    };
    const trouve = checkTranscriptionInventory(recette).find(
      (f) => f.code === "lecture_incertaine",
    );
    assert.ok(trouve);
    assert.deepEqual(trouve.items, ["peau en dessous"]);
    assert.match(trouve.message, /vérifier sur le livre/);
  });

  test("un doute ne fait pas jeter le travail", () => {
    // Il signale où regarder, il ne condamne pas : le reste de la recette est
    // bon, et la retirer priverait l'utilisateur de tout pour deux mots.
    const recette: TranscribedRecipe = {
      ...gravlax(),
      lecturesIncertaines: ["peau"],
    };
    assert.equal(checkFidelity(recette, taggedGravlax()).rejette, false);
  });

  test("sans doute déclaré, rien n'est affiché", () => {
    assert.deepEqual(checkTranscriptionInventory(gravlax()), []);
  });

  test("le doute est signalé même sans inventaire", () => {
    // Les deux constats sont indépendants : lier le premier au second ferait
    // taire le doute sur toute transcription qui n'aurait pas déclaré ses
    // comptes.
    const recette: TranscribedRecipe = {
      ...gravlax(),
      inventaire: undefined,
      lecturesIncertaines: ["peau"],
    };
    assert.equal(checkTranscriptionInventory(recette).length, 1);
  });
});

describe("une ligne du livre peut nommer deux ingrédients", () => {
  const ligne = "2 cuil. à café de moutarde à l'ancienne mélangée à 2 cuil. à café de miel";

  function recetteADeuxAliments(): TranscribedRecipe {
    return {
      ...gravlax(),
      sectionsIngredients: [{ titre: "", lignes: [ligne] }],
      sectionsEtapes: [{ titre: "", etapes: ["Fouettez le tout."] }],
      notes: [],
    };
  }

  test("deux entrées pour une ligne ne sont pas une anomalie", () => {
    // Deux aliments, deux quantités, deux achats. La règle « une ligne, une
    // entrée » obligeait à en choisir un — le miel disparaissait de la liste de
    // courses et du calcul, sans un mot.
    const report = checkFidelity(recetteADeuxAliments(), {
      ...taggedGravlax(),
      cooklang: "Fouettez le tout.",
      ingredients: [
        {
          brut: ligne,
          section: "",
          nom: "moutarde à l'ancienne",
          qte: "2",
          unite: "c. à café",
          note: "mélangée au miel",
        },
        {
          brut: ligne,
          section: "",
          nom: "miel",
          qte: "2",
          unite: "c. à café",
          note: "mélangé à la moutarde à l'ancienne",
        },
      ],
    });
    assert.equal(
      report.findings.some((f) => f.code === "ingredients_compte"),
      false,
      JSON.stringify(report.findings),
    );
  });

  test("n'en garder aucun est signalé — et le texte perdu, lui, rompt", () => {
    // Deux contrôles, deux rôles. `ingredients_compte` rapproche des chaînes et
    // signale ; `texte_perdu` compare les mots de la page à ceux du texte
    // balisé et DÉMONTRE la perte. C'est le second qui a le droit de jeter.
    const report = checkFidelity(recetteADeuxAliments(), {
      ...taggedGravlax(),
      cooklang: "Fouettez le tout.",
      ingredients: [],
    });
    assert.ok(report.findings.some((f) => f.code === "ingredients_compte"));
  });

  test("deux lignes identiques dans deux sections font deux achats", () => {
    // « 1 bouquet d'aneth » figure dans « Pour le saumon » ET dans la sauce.
    // Vérifier que la ligne « existe quelque part » laisserait passer leur
    // fusion — celle-là même que ce contrôle existe pour attraper.
    const tagged = taggedGravlax();
    const report = checkFidelity(gravlax(), {
      ...tagged,
      ingredients: tagged.ingredients.filter((_, i) => i !== 4),
    });
    const trouve = report.findings.find((f) => f.code === "ingredients_compte");
    assert.ok(trouve, JSON.stringify(report.findings));
    // Le constat DIT OÙ : la ligne telle que le livre l’écrit, son rang et sa
    // section. Un écart sans emplacement oblige à relire la page entière pour
    // le retrouver — et une vérification coûteuse ne se fait pas.
    const detail = (trouve.items ?? []).join(" ");
    assert.match(detail, /1 bouquet d'aneth/);
    assert.match(detail, /ingrédient 3/);
    assert.match(detail, /Pour le saumon/);
    assert.match(detail, /1 sur 2/);
  });
});

describe("le chapeau de la recette", () => {
  test("il survit au repli verbatim, et se lit en premier", () => {
    // « Une méthode scandinave pour fumer le saumon dans le sel… » dit d'où
    // vient le plat. C'est du contenu, et il se perdait : la consigne de ne pas
    // recopier les en-têtes de page l'emportait sur lui.
    const out = verbatimCooklang(gravlax());
    const lignes = out.split("\n").filter((l) => l.trim().length > 0);
    const indexChapeau = lignes.findIndex((l) => l.includes("méthode scandinave"));
    const indexPremiereEtape = lignes.findIndex((l) => l.includes("Posez le filet"));
    assert.ok(indexChapeau >= 0, out);
    assert.ok(indexChapeau < indexPremiereEtape);
  });

  test("il est transmis à la passe de balisage", () => {
    assert.match(renderTranscriptionForTagging(gravlax()), /INTRODUCTION : Une méthode scandinave/);
  });

  test("sa perte au balisage est constatée", () => {
    // Sans cela, un chapeau oublié disparaîtrait comme il le faisait avant :
    // aucune étape en moins, aucun ingrédient en moins, aucun signal.
    const recette: TranscribedRecipe = {
      ...gravlax(),
      introduction:
        "Une méthode scandinave venue de Norvège pour fumer le saumon dans le sel et le sucre pendant deux jours entiers.",
      sectionsEtapes: [{ titre: "", etapes: ["Posez le filet sur un plat."] }],
      notes: [],
      sectionsIngredients: [],
    };
    const report = checkFidelity(recette, {
      ...taggedGravlax(),
      ingredients: [],
      cooklang: "Posez le @filet de saumon{} sur un #plat{}.",
    });
    assert.ok(
      report.findings.some((f) => f.code === "texte_perdu"),
      JSON.stringify(report.findings),
    );
  });

  test("une recette sans chapeau n'en fabrique pas", () => {
    const sans: TranscribedRecipe = { ...gravlax(), introduction: "" };
    assert.equal(verbatimCooklang(sans).includes("scandinave"), false);
    assert.equal(renderTranscriptionForTagging(sans).includes("INTRODUCTION"), false);
  });
});

describe("la précision d'une ligne va quelque part, ou se signale", () => {
  function avecIngredient(brut: string, nom: string, note: string) {
    return checkFidelity(
      {
        ...gravlax(),
        introduction: "",
        notes: [],
        sectionsIngredients: [{ titre: "", lignes: [brut] }],
        sectionsEtapes: [{ titre: "", etapes: ["Posez le filet sur un plat."] }],
      },
      {
        ...taggedGravlax(),
        cooklang: "Posez le @filet de saumon{} sur un #plat{}.",
        ingredients: [{ brut, section: "", nom, qte: "1.8", unite: "kg", note }],
      },
    );
  }

  test("une note vide alors que la ligne dit plus est signalée", () => {
    // « avec la peau mais écaillée » n'est plus dans le nom, plus dans la note,
    // plus nulle part — et rien ne le disait : la ligne compte pour une, le nom
    // est correct, la quantité aussi.
    const report = avecIngredient(
      "1 filet de saumon de 1,8 kg avec la peau mais écaillée",
      "filet de saumon",
      "",
    );
    const trouve = report.findings.find((f) => f.code === "precision_perdue");
    assert.ok(trouve, JSON.stringify(report.findings));
    assert.match((trouve.items ?? []).join(" "), /ecaillee|peau/i);
  });

  test("la même ligne avec sa note ne déclenche rien", () => {
    const report = avecIngredient(
      "1 filet de saumon de 1,8 kg avec la peau mais écaillée",
      "filet de saumon",
      "avec la peau mais écaillée",
    );
    assert.equal(
      report.findings.some((f) => f.code === "precision_perdue"),
      false,
      JSON.stringify(report.findings),
    );
  });

  test("une ligne simple ne réclame pas de note", () => {
    // Le cas fréquent : rien ne reste, et il ne faut surtout pas inventer.
    const report = avecIngredient("250 g de porc haché", "porc haché", "");
    assert.equal(
      report.findings.some((f) => f.code === "precision_perdue"),
      false,
      JSON.stringify(report.findings),
    );
  });

  test("un seul mot restant n'alerte pas", () => {
    // Presque toujours un article ou une variante d'orthographe : alerter là
    // ferait du bruit, et le bruit fait ignorer le signal.
    const report = avecIngredient("200 g de gros sel marin", "gros sel", "");
    assert.equal(
      report.findings.some((f) => f.code === "precision_perdue"),
      false,
      JSON.stringify(report.findings),
    );
  });
});

describe("un constat dit toujours OÙ regarder", () => {
  test("le titre de section s'affiche avec ses accents, pas sa clé de comparaison", () => {
    // La forme comparable est mise à plat pour que « POUR LA SAUCE » et « Pour
    // la sauce » se reconnaissent. L'afficher rendait « sauce a l aneth et a la
    // moutarde », qu'on lit comme une faute de frappe et non comme le titre du
    // livre.
    const raccourci = gravlaxCooklang.replace(
      "== Pour la sauce à l'aneth et à la moutarde ==",
      "== Pour la sauce ==",
    );
    const report = checkFidelity(gravlax(), taggedGravlax({ cooklang: raccourci }));
    const trouve = report.findings.find((f) => f.code === "sections_titres");
    assert.ok(trouve, JSON.stringify(report.findings));
    assert.deepEqual(trouve.items, ["Pour la sauce à l'aneth et à la moutarde"]);
  });

  test("une précision perdue nomme l'ingrédient et sa place", () => {
    const report = checkFidelity(
      {
        ...gravlax(),
        introduction: "",
        notes: [],
        sectionsIngredients: [
          {
            titre: "Pour le saumon",
            lignes: ["1 filet de saumon de 1,8 kg avec la peau mais écaillée"],
          },
        ],
        sectionsEtapes: [{ titre: "", etapes: ["Posez le filet sur un plat."] }],
      },
      {
        ...taggedGravlax(),
        cooklang: "Posez le @filet de saumon{} sur un #plat{}.",
        ingredients: [
          {
            brut: "1 filet de saumon de 1,8 kg avec la peau mais écaillée",
            section: "Pour le saumon",
            nom: "filet de saumon",
            qte: "1.8",
            unite: "kg",
            note: "",
          },
        ],
      },
    );
    const trouve = report.findings.find((f) => f.code === "precision_perdue");
    assert.ok(trouve, JSON.stringify(report.findings));
    const detail = (trouve.items ?? []).join(" ");
    assert.match(detail, /filet de saumon/);
    assert.match(detail, /ingrédient 1/);
    assert.match(detail, /Pour le saumon/);
  });

  test("une note perdue dit laquelle", () => {
    // « 0 note sur 1 » n'aide personne quand la recette en porte plusieurs.
    const sansNote = gravlaxCooklang.replace(
      "> Le conseil du chef : Se conserve trois jours au frais.",
      "",
    );
    const report = checkFidelity(gravlax(), taggedGravlax({ cooklang: sansNote }));
    const trouve = report.findings.find((f) => f.code === "notes_perdues");
    assert.ok(trouve, JSON.stringify(report.findings));
    assert.match((trouve.items ?? []).join(" "), /Le conseil du chef/);
    assert.match((trouve.items ?? []).join(" "), /Se conserve trois jours/);
  });

  test("un écart d'étapes dit combien la page en portait, section par section", () => {
    const report = checkFidelity(
      gravlax(),
      taggedGravlax({ cooklang: ">> titre: Gravlax\nSalez le saumon." }),
    );
    const trouve = report.findings.find((f) => f.code === "etapes_compte");
    assert.ok(trouve, JSON.stringify(report.findings));
    assert.match((trouve.items ?? []).join(" "), /Pour le saumon : 3 étape/);
  });
});

describe("texte collé — un préambule, pas un second prompt", () => {
  test("le préambule ne recopie aucune règle de transcription", () => {
    // Le garde-fou de la duplication. Le jour où quelqu'un commencera à
    // recopier ici les règles du prompt de page — recopier sans réécrire,
    // garder les sections, chercher le temps de repos — ce test tombera, et
    // avec lui l'illusion qu'un seul endroit décide encore de la fidélité.
    assert.ok(
      TEXT_TRANSCRIPTION_PREAMBLE.length < TRANSCRIPTION_PROMPT.length / 5,
      "le préambule grossit : il est en train de redevenir un second prompt",
    );
    for (const regle of ["▸ LA LISTE D'INGRÉDIENTS", "▸ LES ÉTAPES", "════ SORTIE ════"]) {
      assert.ok(
        !TEXT_TRANSCRIPTION_PREAMBLE.includes(regle),
        `« ${regle} » est recopié dans le préambule au lieu d'être hérité`,
      );
    }
  });

  test("il nomme les deux seules différences", () => {
    // Le numéro de page, qui n'existe pas pour un texte collé, et le mobilier
    // à ignorer, qui n'est plus un folio. Tout le reste s'applique tel quel :
    // si l'une de ces deux mentions disparaît, le modèle remplira « page »
    // avec un nombre trouvé au hasard, ou recopiera les avis des lecteurs.
    assert.match(TEXT_TRANSCRIPTION_PREAMBLE, /"page".*vaut null/s);
    assert.match(TEXT_TRANSCRIPTION_PREAMBLE, /CE QU'ON NE RECOPIE PAS/);
  });
});
