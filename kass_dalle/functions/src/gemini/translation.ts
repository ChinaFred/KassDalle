/**
 * Traduction d'une recette transcrite dans une autre langue que le français.
 *
 * Elle prend place entre la passe 1 (transcription) et la passe 2 (balisage).
 * Le balisage, les référentiels de nutrition et de courses, les tags : tout ce
 * qui suit lit du français. Traduire une fois, en amont, leur rend une entrée
 * qu'ils savent lire.
 *
 * L'appel ne voit pas l'image : il reçoit la transcription en JSON et rend le
 * même JSON, en français, mesures converties en métrique. Le contrôle de
 * fidélité compare ensuite le balisage à cette traduction, comme il le fait
 * pour une recette française.
 *
 * Une recette française ne passe jamais ici : la langue est lue par la
 * transcription, sans appel de plus (voir `needsTranslation`).
 */

import { extractJsonObject } from "./client";
import { logAiText, logError } from "../logging";
import { callModel } from "../ai/router";
import { codeEffortFor } from "../ai/featureEfforts";
import { textPart, type ModelCallContext } from "../ai/types";
import {
  normalizeLanguageCode,
  type TranscribedIngredientSection,
  type TranscribedNote,
  type TranscribedRecipe,
  type TranscribedStepSection,
} from "./transcription";

/** Une traduction rend à peu près autant de texte que la transcription. */
const TRANSLATION_MAX_TOKENS = 16_000;

export const TRANSLATION_PROMPT = String.raw`
Tu traduis en français une recette de cuisine écrite dans une autre langue.
Tu reçois la recette en JSON. Tu rends le MÊME JSON, traduit.

════ CE QUE TU TRADUIS ════

Tout le texte : titre, introduction, titres de groupe, lignes d'ingrédients,
étapes, notes, sections de l'inventaire, temps, difficulté (facile, moyen ou
difficile).

Tu traduis phrase par phrase, sans résumer, sans fusionner, sans ajouter.
Chaque ligne d'ingrédient reste une ligne, chaque étape reste une étape, dans
le même ordre. Les nombres de groupes, de lignes, d'étapes et de notes sont
comparés à l'original : un écart fait rejeter la traduction.

Les noms établis en français restent tels quels : cheddar, cheesecake,
banana bread, wok, crumble, mozzarella. Un ingrédient sans équivalent garde
son nom d'origine, suivi d'un équivalent courant entre parenthèses s'il en
existe un : « 200 g de graham crackers (ou biscuits sablés type spéculoos) ».
Tu ne remplaces jamais un ingrédient par un autre sans le dire.

════ LES MESURES : CONVERTIES EN MÉTRIQUE ════

Une recette française s'écrit en grammes, millilitres, °C et centimètres.

- Un solide mesuré en volume se convertit en GRAMMES, selon l'ingrédient :
  1 cup de farine ≈ 125 g, de sucre ≈ 200 g, de sucre glace ≈ 120 g,
  de cassonade ≈ 220 g, de beurre ≈ 225 g, de riz cru ≈ 190 g,
  de flocons d'avoine ≈ 90 g, de fromage râpé ≈ 100 g.
  1 stick de beurre = 113 g.
- Un liquide mesuré en volume se convertit en MILLILITRES :
  1 cup = 240 ml ; 1 fl oz = 30 ml ; 1 pint US = 475 ml, UK = 570 ml ;
  1 quart US = 950 ml. Valeur UK seulement si la source est britannique
  (orthographe, mention, éditeur) ; dans le doute, valeur US.
- tbsp → c. à soupe, tsp → c. à café : tu gardes le nombre.
- oz (poids) → g (1 oz = 28 g) ; lb → g (1 lb = 454 g).
- °F → °C, arrondi à 5 °C (350 °F → 175 °C). « Gas mark » → °C.
  Un thermostat ne s'ajoute que s'il figure déjà dans la source.
- inch → cm, arrondi au centimètre (moule de 9 inch → moule de 23 cm).
- Arrondis les grammes et les millilitres à une valeur qu'on peut peser :
  5 g près sous 100 g, 10 g près au-delà.
- Une quantité sans unité (« 2 eggs », « 1 onion ») garde son nombre.
- Les unités déjà métriques restent telles quelles.

════ CE QUE TU NE TOUCHES PAS ════

- "portions" et "page" : nombres recopiés tels quels.
- "lectures_incertaines" : n'apparaît pas dans l'entrée, ne l'ajoute pas.
- La structure : mêmes clés, même ordre, mêmes tableaux.

════ SORTIE ════

UNIQUEMENT un JSON valide, sans markdown, sans commentaire, de la forme :

{
  "titre": "<titre traduit>",
  "introduction": "<introduction traduite, ou null>",
  "portions": <nombre ou null>,
  "temps_preparation": "<durée traduite ou null>",
  "temps_cuisson": "<durée traduite ou null>",
  "temps_repos": "<durée traduite ou null>",
  "difficulte": "<facile|moyen|difficile, ou null>",
  "inventaire_sections": ["<titre traduit>"],
  "sections_ingredients": [ { "titre": "<traduit>", "lignes": ["<ligne traduite et convertie>"] } ],
  "sections_etapes": [ { "titre": "<traduit>", "etapes": ["<étape traduite et convertie>"] } ],
  "notes": [ { "genre": "<Astuce|Variante|Conservation|…>", "texte": "<traduit>" } ]
}
`;

/** La recette à traduire, sous la forme que le prompt décrit. */
export function translationInput(recette: TranscribedRecipe): Record<string, unknown> {
  return {
    titre: recette.titre,
    introduction: recette.introduction || null,
    portions: recette.portions,
    temps_preparation: recette.tempsPreparation,
    temps_cuisson: recette.tempsCuisson,
    temps_repos: recette.tempsRepos,
    difficulte: recette.difficulte,
    inventaire_sections: recette.inventaire?.sections ?? [],
    sections_ingredients: recette.sectionsIngredients,
    sections_etapes: recette.sectionsEtapes,
    notes: recette.notes,
  };
}

function asString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function asStringOrNull(value: unknown): string | null {
  const out = asString(value);
  return out.length > 0 ? out : null;
}

function records(value: unknown): Record<string, unknown>[] {
  return Array.isArray(value)
    ? value.filter((v): v is Record<string, unknown> => !!v && typeof v === "object")
    : [];
}

/**
 * Les chaînes d'une liste, vides comprises.
 *
 * Une ligne vide n'est pas retirée ici : elle doit compter dans le contrôle des
 * nombres, sinon une ligne que le modèle n'a pas traduite passerait inaperçue.
 */
function strings(value: unknown): string[] {
  return Array.isArray(value) ? value.map(asString) : [];
}

/**
 * Reconstruit la recette traduite depuis le JSON du modèle.
 *
 * Ce que la traduction ne doit pas toucher vient de l'original : portions, page,
 * lectures incertaines (des mots lus sur le livre, à y vérifier), compteurs de
 * l'inventaire.
 */
export function parseTranslation(
  json: Record<string, unknown>,
  original: TranscribedRecipe,
): TranscribedRecipe {
  const sectionsIngredients: TranscribedIngredientSection[] = records(
    json.sections_ingredients,
  ).map((s) => ({ titre: asString(s.titre), lignes: strings(s.lignes) }));
  const sectionsEtapes: TranscribedStepSection[] = records(json.sections_etapes).map((s) => ({
    titre: asString(s.titre),
    etapes: strings(s.etapes),
  }));
  const notes: TranscribedNote[] = records(json.notes).map((n) => ({
    genre: asString(n.genre),
    texte: asString(n.texte),
  }));
  const inventaireSections = strings(json.inventaire_sections);

  return {
    titre: asString(json.titre),
    langue: "fr",
    introduction: asString(json.introduction),
    // Les titres de l'inventaire sont comparés aux titres rendus par le
    // contrôle de fidélité. Des titres restés dans la langue d'origine ne
    // ressembleraient à aucun titre traduit : chaque section passerait pour
    // perdue. Sans traduction exploitable, on retire les titres et on garde
    // les compteurs.
    ...(original.inventaire
      ? {
          inventaire: {
            ...original.inventaire,
            sections:
              inventaireSections.length === original.inventaire.sections.length
                ? inventaireSections
                : [],
          },
        }
      : {}),
    lecturesIncertaines: original.lecturesIncertaines,
    page: original.page,
    portions: original.portions,
    tempsPreparation: asStringOrNull(json.temps_preparation),
    tempsCuisson: asStringOrNull(json.temps_cuisson),
    tempsRepos: asStringOrNull(json.temps_repos),
    difficulte: asStringOrNull(json.difficulte),
    sectionsIngredients,
    sectionsEtapes,
    notes,
    traduction: { langue: normalizeLanguageCode(original.langue), recette: original },
  };
}

/**
 * Ce qui diffère entre l'original et sa traduction, en nombres.
 *
 * Rend une liste vide quand la traduction a gardé la forme de l'original :
 * mêmes groupes, mêmes lignes par groupe, mêmes étapes par groupe, mêmes notes,
 * et aucun texte vidé : titre, introduction, titre de groupe, ligne, étape ou
 * note. Les durées ne sont pas contrôlées : une durée absente reste `null`. Contrôle programmé, sans appel de modèle.
 */
export function translationShapeMismatches(
  original: TranscribedRecipe,
  traduite: TranscribedRecipe,
): string[] {
  const ecarts: string[] = [];
  if (!traduite.titre) ecarts.push("titre vide");
  if (original.introduction && !traduite.introduction) ecarts.push("introduction vide");

  if (traduite.sectionsIngredients.length !== original.sectionsIngredients.length) {
    ecarts.push(
      `${traduite.sectionsIngredients.length} groupe(s) d'ingrédients pour ${original.sectionsIngredients.length}`,
    );
  } else {
    original.sectionsIngredients.forEach((s, i) => {
      const lignes = traduite.sectionsIngredients[i].lignes;
      if (s.titre && !traduite.sectionsIngredients[i].titre) {
        ecarts.push(`groupe d'ingrédients ${i + 1} : titre vide`);
      }
      if (lignes.length !== s.lignes.length) {
        ecarts.push(
          `groupe d'ingrédients ${i + 1} : ${lignes.length} ligne(s) pour ${s.lignes.length}`,
        );
      } else if (lignes.some((l) => l.length === 0)) {
        ecarts.push(`groupe d'ingrédients ${i + 1} : ligne vide`);
      }
    });
  }

  if (traduite.sectionsEtapes.length !== original.sectionsEtapes.length) {
    ecarts.push(
      `${traduite.sectionsEtapes.length} groupe(s) d'étapes pour ${original.sectionsEtapes.length}`,
    );
  } else {
    original.sectionsEtapes.forEach((s, i) => {
      const etapes = traduite.sectionsEtapes[i].etapes;
      if (s.titre && !traduite.sectionsEtapes[i].titre) {
        ecarts.push(`groupe d'étapes ${i + 1} : titre vide`);
      }
      if (etapes.length !== s.etapes.length) {
        ecarts.push(`groupe d'étapes ${i + 1} : ${etapes.length} étape(s) pour ${s.etapes.length}`);
      } else if (etapes.some((e) => e.length === 0)) {
        ecarts.push(`groupe d'étapes ${i + 1} : étape vide`);
      }
    });
  }

  if (traduite.notes.length !== original.notes.length) {
    ecarts.push(`${traduite.notes.length} note(s) pour ${original.notes.length}`);
  } else if (traduite.notes.some((n) => n.texte.length === 0)) {
    ecarts.push("note vide");
  }

  return ecarts;
}

/**
 * Traduit une recette en français, ou lève.
 *
 * Une réponse illisible ou une traduction qui n'a pas la forme de l'original
 * fait échouer le job : la suite de la chaîne ne sait pas lire la langue
 * d'origine, et une recette à moitié traduite ne se voit pas à la relecture.
 * Le job reste relançable, et la relance repart de la transcription enregistrée.
 */
export async function translateRecipe(
  recette: TranscribedRecipe,
  ctx: ModelCallContext,
): Promise<TranscribedRecipe> {
  const langue = normalizeLanguageCode(recette.langue);
  const result = await callModel({
    parts: [
      textPart(TRANSLATION_PROMPT, { cache: true }),
      textPart(
        `Langue d'origine : ${langue}\n\n${JSON.stringify(translationInput(recette), null, 2)}`,
      ),
    ],
    ctx: {
      ...ctx,
      feature: "recipe_translation",
      timeoutMs: 3 * 60 * 1000,
      effort: codeEffortFor("recipe_translation"),
    },
    maxTokens: TRANSLATION_MAX_TOKENS,
  });

  const text = result.text.trim();
  await logAiText({
    stage: "traduction",
    text,
    message: `Recette traduite depuis « ${langue} », avant tout balisage`,
    feature: "recipe_translation",
    provider: result.provider,
    model: result.model,
    moduleType: "IMPORT",
    correlationId: ctx.correlationId,
    scanId: ctx.scanId,
    callId: result.callId,
    jobId: ctx.jobId,
    userId: ctx.userId,
    extra: { langue, titre: recette.titre },
  });

  let traduite: TranscribedRecipe;
  try {
    traduite = parseTranslation(
      JSON.parse(extractJsonObject(text)) as Record<string, unknown>,
      recette,
    );
  } catch (err) {
    await logError({
      message: "recipe_translation: réponse illisible",
      errorDescription: err instanceof Error ? err.message : String(err),
      moduleType: "IMPORT",
      correlationId: ctx.correlationId,
      jobId: ctx.jobId,
      userId: ctx.userId,
      extra: { langue, longueur: text.length },
    });
    throw new Error("Traduction impossible : la réponse du modèle n'a pas pu être lue.");
  }

  const ecarts = translationShapeMismatches(recette, traduite);
  if (ecarts.length > 0) {
    await logError({
      message: `recipe_translation: traduction rejetée (${ecarts.join(" ; ")})`,
      moduleType: "IMPORT",
      correlationId: ctx.correlationId,
      jobId: ctx.jobId,
      userId: ctx.userId,
      extra: { langue, titre: recette.titre, ecarts },
    });
    throw new Error(`Traduction impossible : ${ecarts.join(" ; ")}.`);
  }
  return traduite;
}
