/**
 * Conversion d'un texte libre en CookLang.
 *
 * Ce fichier faisait tenir ce travail dans UN appel : un prompt demandait au
 * modèle de lire et de baliser en même temps, et rendait du CookLang. C'est
 * exactement ce que la chaîne d'import a cessé de faire — voir l'en-tête de
 * `promptsExtraction.ts`. Le défaut est le même ici : un modèle qui balise
 * pendant qu'il lit doit DÉCIDER où placer chaque ligne de la liste
 * d'ingrédients, donc fusionner des phrases, en déplacer, en abréger. Et la
 * liste elle-même se dissout dans les étapes : « 2 gousses d'ail dégermées »
 * perdait « dégermées », qu'aucune accolade ne peut porter.
 *
 * Le texte collé emprunte donc la même chaîne que la page scannée :
 * transcription, puis balisage, puis contrôle de fidélité — ce dernier ne
 * coûtant aucun appel. Seule la passe 1 diffère, et seulement par ce qu'elle
 * reçoit.
 *
 * Ce fichier portait aussi trois étapes de l'ancien import : l'extraction
 * depuis une image ou un PDF (`extractRecipes`), la classification de la page
 * (`classifyPage`) et l'extraction verbatim d'un document non-recette
 * (`extractDocument`). La transcription en deux passes les a remplacées, et
 * plus rien ne les appelait depuis.
 *
 * Leurs trois postes de coût restent au catalogue comptable : les mois déjà
 * comptabilisés doivent continuer de les nommer. Ils ont en revanche quitté
 * `ROUTABLE_FEATURES` : un sélecteur de moteur qui ne commande aucun appel est
 * pire qu'une absence, il fait croire à un réglage.
 */

import { logInfo } from "../logging";
import type { ModelCallContext } from "../ai/types";
import { needsTranslation, transcribeText } from "./transcription";
import { translateRecipe } from "./translation";
import { tagAndNormalize, type NormalizedIngredientLine } from "./tagging";
import { checkFidelity, verbatimCooklang, type FidelityReport } from "./fidelity";

/** Ce qu'un texte libre donne une fois lu, balisé et vérifié. */
export interface TextExtraction {
  cooklang: string;
  /** Une entrée par ligne d'ingrédient du texte, avec sa note explicative. */
  ingredients: NormalizedIngredientLine[];
  cuisines: string[];
  dishTypes: string[];
  fidelity: FidelityReport;
  /**
   * Combien de recettes le texte contenait.
   *
   * Une seule est rendue — l'écran de création n'en édite qu'une. Le compte
   * part quand même : un utilisateur qui colle deux recettes doit apprendre
   * que la seconde n'a pas été reprise, plutôt que de la découvrir absente.
   */
  recettesTrouvees: number;
  /** Code ISO 639-1 de la langue du texte collé, quand il a été traduit. */
  langueOrigine?: string;
}

/**
 * Convertit un texte libre en recette balisée et vérifiée.
 *
 * Retourne null quand le texte ne contient aucune recette — l'équivalent du
 * `NO_RECIPE` de l'ancien prompt, décidé cette fois par le même classement que
 * pour une page de livre.
 */
export async function extractRecipeFromText(
  freeText: string,
  ctx: ModelCallContext,
): Promise<TextExtraction | null> {
  // ── PASSE 1 : transcription du texte ────────────────────────────────────
  const transcription = await transcribeText(freeText, {
    ...ctx,
    feature: "text_extraction",
  });

  logInfo({
    message: `Texte transcrit: ${transcription.pageType} — "${transcription.titre}"`,
    moduleType: "IMPORT",
    correlationId: ctx.correlationId,
    userId: ctx.userId,
    extra: {
      pageType: transcription.pageType,
      titre: transcription.titre,
      recettes: transcription.recettes.length,
      raison: transcription.raison,
    },
  });

  const lue = transcription.recettes[0];
  if (!lue) return null;

  // Un texte collé dans une autre langue est traduit avant le balisage, comme
  // une page scannée. Son original n'est pas conservé : la recette n'existe pas
  // encore, et l'utilisateur garde le texte qu'il vient de coller.
  const recette = needsTranslation(lue)
    ? await translateRecipe(lue, { ...ctx, feature: "recipe_translation", moduleType: "IMPORT" })
    : lue;

  // ── PASSE 2 : balisage et normalisation ─────────────────────────────────
  //
  // Le même appel que pour un scan, sur la même entrée : une transcription.
  // Le poste de coût est donc le même — c'est le même travail, et lui en
  // donner un second nom aurait coupé en deux une ligne comptable qui mesure
  // une seule chose.
  const tagged = await tagAndNormalize(recette, {
    ...ctx,
    feature: "recipe_tagging",
    moduleType: "IMPORT",
  });

  const fidelity = checkFidelity(recette, tagged);
  if (fidelity.findings.length > 0) {
    logInfo({
      message: `Contrôle de fidélité (${fidelity.level}) : ${fidelity.findings
        .map((f) => f.message)
        .join(" ")}`,
      moduleType: "IMPORT",
      correlationId: ctx.correlationId,
      userId: ctx.userId,
      extra: {
        titre: recette.titre,
        niveau: fidelity.level,
        codes: fidelity.findings.map((f) => f.code),
      },
    });
  }

  return {
    // Repli : mieux vaut une recette exacte et non balisée qu'une recette
    // balisée et fausse. Les ingrédients, eux, restent ceux de la passe 2 —
    // ils viennent de la liste du texte, que le balisage n'a pas touchée.
    cooklang: fidelity.rejette ? verbatimCooklang(recette) : tagged.cooklang,
    ingredients: tagged.ingredients,
    cuisines: tagged.cuisines,
    dishTypes: tagged.dishTypes,
    fidelity,
    recettesTrouvees: transcription.recettes.length,
    ...(recette.traduction ? { langueOrigine: recette.traduction.langue } : {}),
  };
}
