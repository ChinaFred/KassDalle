/**
 * Classe automatiquement le rôle d'une recette dans un repas, à l'écriture.
 *
 * `tags.meal_role` ne se pose que sur ce qui passe par la passe 2 de l'import
 * (`tagAndNormalize`, feature `recipe_tagging`). Trois autres chemins créent
 * une recette sans ce champ : une création manuelle sans clic « Suggérer »
 * (`recipe_form_mixin.dart`), une recette de l'Explorer IA (`generateRecipeFn`
 * ne demande pas ce champ au modèle), une recette dupliquée dont l'original
 * n'était pas classé (`copyRecipeAsDraft`, qui copie les tags tels quels).
 *
 * Plutôt que de corriger ces trois chemins un par un côté client, ce module
 * se branche sur le même déclencheur unique que la nutrition et les produits
 * d'achat : toute écriture d'une recette sans rôle en déclenche un, quelle que
 * soit son origine. Le planning ne peut composer un plat et son accompagnement
 * que pour une recette classée — un trou ici est un trou silencieux là-bas.
 */

import { FieldValue, getFirestore } from "firebase-admin/firestore";

import { COLL_RECIPES, GEMINI_API_KEY } from "../config";
import { suggestMealRole } from "../gemini/tagger";
import { logError, logInfo } from "../logging";

const FEATURE = "inline_meal_role_classification";

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function asStrings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((s): s is string => typeof s === "string") : [];
}

/**
 * Pose `tags.meal_role` (et `contains`, `suggested_sides`) si absent.
 *
 * Un seul appel de modèle, sur le rôle seul — comme le backfill, les types de
 * plat déjà connus ne sont pas redemandés. Si le modèle ne sait pas classer la
 * recette, rien n'est écrit : elle reste sans rôle, et la prochaine écriture
 * — ou le backfill — retentera. Aucun compteur d'essais, aucun délai de
 * reprise : un seul champ à remplir ne justifie pas le mécanisme de budget de
 * l'enrichissement nutritionnel, et reproduire sa marque « tentative
 * récente » reproduirait aussi son défaut — une coupure de budget comptée
 * comme un échec réel, qui bloque toute reprise automatique pendant 24 h.
 */
export async function syncRecipeMealRole(args: {
  recipeId: string;
  data: Record<string, unknown>;
  correlationId: string;
  scanId?: string;
}): Promise<void> {
  const { recipeId, data, correlationId, scanId } = args;

  const tags = (data.tags && typeof data.tags === "object" ? data.tags : {}) as Record<
    string,
    unknown
  >;
  if (asString(tags.meal_role).length > 0) return;

  const userId = (data.created_by as string | undefined) ?? undefined;
  const titre = asString(data.titre);
  const cooklang = asString(data.draft_cooklang) || asString(data.raw_cooklang);

  try {
    const fields = await suggestMealRole(
      GEMINI_API_KEY.value(),
      { titre, cooklang, dishTypes: asStrings(tags.dish_types) },
      { correlationId, userId, feature: FEATURE, moduleType: "DESIGN", scanId },
    );

    if (fields.mealRole == null) {
      await logInfo({
        message: "syncRecipeMealRole: le modèle n'a pas su classer la recette",
        correlationId,
        userId,
        scanId,
        moduleType: "DESIGN",
        feature: FEATURE,
        extra: { recipeId, titre },
      });
      return;
    }

    await getFirestore().collection(COLL_RECIPES).doc(recipeId).update({
      "tags.meal_role": fields.mealRole,
      "tags.contains": fields.contains,
      "tags.suggested_sides": fields.suggestedSides,
      "tags.roles_tagged_at": FieldValue.serverTimestamp(),
    });
  } catch (e) {
    await logError({
      message: "syncRecipeMealRole: échec de la classification",
      correlationId,
      userId,
      scanId,
      moduleType: "DESIGN",
      feature: FEATURE,
      errorDescription: e instanceof Error ? e.message : String(e),
      extra: { recipeId, titre },
    });
  }
}
