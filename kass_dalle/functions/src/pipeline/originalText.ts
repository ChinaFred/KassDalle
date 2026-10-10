/**
 * Texte d'origine d'une recette traduite : où il vit et quelle forme il a.
 *
 * `recipes/{id}/origine/texte`, écrit par le serveur dans le même lot que la
 * recette, jamais par le client. Il se lit avec les droits de la recette, et
 * disparaît avec elle (`onRecipeWritten`).
 */

import type { RecipeTranslationOrigin } from "../gemini/transcription";

/** Sous-collection du texte d'origine d'une recette traduite. */
export const SUBCOLL_ORIGINAL_TEXT = "origine";
/** Identifiant du seul document de cette sous-collection. */
export const ORIGINAL_TEXT_DOC_ID = "texte";

/**
 * Le texte d'origine tel que la transcription l'a lu, avant traduction.
 *
 * Les clés reprennent celles de la transcription. Les lectures incertaines et
 * l'inventaire n'y figurent pas : ils servent au contrôle de l'import, pas au
 * lecteur.
 */
export function originalTextDocument(
  traduction: RecipeTranslationOrigin,
  createdAt: unknown,
): Record<string, unknown> {
  const r = traduction.recette;
  return {
    langue: traduction.langue,
    titre: r.titre,
    introduction: r.introduction || null,
    portions: r.portions,
    temps_preparation: r.tempsPreparation,
    temps_cuisson: r.tempsCuisson,
    temps_repos: r.tempsRepos,
    sections_ingredients: r.sectionsIngredients.map((s) => ({ titre: s.titre, lignes: s.lignes })),
    sections_etapes: r.sectionsEtapes.map((s) => ({ titre: s.titre, etapes: s.etapes })),
    notes: r.notes.map((n) => ({ genre: n.genre, texte: n.texte })),
    created_at: createdAt,
  };
}
