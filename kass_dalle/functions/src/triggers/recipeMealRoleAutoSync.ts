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

import { isDeepStrictEqual } from "node:util";

import { FieldValue, getFirestore } from "firebase-admin/firestore";

import { recipeBudgetUserId } from "../ai/budget";
import { BACKFILL_FAILURE_LIMIT, readFailureCount } from "../backfills/failureMemory";
import { COLL_RECIPES, GEMINI_API_KEY } from "../config";
import { mainIngredientsPatch } from "../gemini/mealRole";
import { suggestMealRole } from "../gemini/tagger";
import { logError, logInfo } from "../logging";

const FEATURE = "inline_meal_role_classification";

function asString(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function asStrings(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((s): s is string => typeof s === "string") : [];
}

/** Champs que le backfill « Rôle des recettes » écrit pour compter ses échecs. */
const MEAL_ROLE_MEMORY_FIELDS: ReadonlySet<string> = new Set([
  "meal_role_failure_count",
  "meal_role_attempt_at",
]);

/**
 * Champs qui portent le contenu soumis au modèle : le titre, et le CookLang
 * (ingrédients et étapes), brouillon comme publié.
 */
const MEAL_ROLE_CONTENT_FIELDS: readonly string[] = ["titre", "draft_cooklang", "raw_cooklang"];

/**
 * Le contenu de la recette a-t-il changé à cette écriture ? Faux à la
 * création : il n'y a rien à comparer, et aucun compteur d'échecs à lever.
 */
export function mealRoleContentChanged(
  data: Record<string, unknown>,
  beforeData: Record<string, unknown> | undefined,
): boolean {
  if (!beforeData) return false;
  return MEAL_ROLE_CONTENT_FIELDS.some((key) => asString(beforeData[key]) !== asString(data[key]));
}

/**
 * Le déclencheur peut-il demander le rôle au modèle ? Fonction pure.
 *
 *  - non si la recette a déjà un rôle ;
 *  - non si le backfill l'a exclue (`meal_role_failure_count` ≥
 *    `BACKFILL_FAILURE_LIMIT`), sauf si cette écriture change son contenu
 *    (titre, ingrédients ou étapes : `mealRoleContentChanged`). Le modèle
 *    reçoit alors une autre question que celle qu'il n'a pas su trancher.
 *    Sans changement de contenu, seul un administrateur la redemande, par
 *    « Réessayer aussi les éléments exclus après 3 échecs » ;
 *  - non si l'écriture ne change que la mémoire des échecs : c'est le
 *    backfill qui vient de compter un échec, ou ce déclencheur qui vient de
 *    remettre le compteur à zéro. Sans cette garde, chaque échec du backfill
 *    coûtait un second appel, ici, dans la seconde.
 */
export function mealRoleCallAllowed(
  data: Record<string, unknown>,
  beforeData: Record<string, unknown> | undefined,
): boolean {
  const tags = (data.tags && typeof data.tags === "object" ? data.tags : {}) as Record<
    string,
    unknown
  >;
  if (asString(tags.meal_role).length > 0) return false;
  if (
    readFailureCount(data.meal_role_failure_count) >= BACKFILL_FAILURE_LIMIT &&
    !mealRoleContentChanged(data, beforeData)
  ) {
    return false;
  }
  if (beforeData && onlyFieldsChanged(beforeData, data, MEAL_ROLE_MEMORY_FIELDS)) return false;
  return true;
}

/**
 * Le compteur d'échecs du backfill doit-il repartir à zéro ? Oui quand le
 * contenu change et que la recette porte au moins un échec : les échecs
 * comptés portaient sur un autre contenu. `meal_role_attempt_at` est gardé,
 * comme après un succès du backfill : il date le dernier essai, pas l'état.
 */
export function mealRoleFailureResetNeeded(
  data: Record<string, unknown>,
  beforeData: Record<string, unknown> | undefined,
): boolean {
  return (
    readFailureCount(data.meal_role_failure_count) > 0 && mealRoleContentChanged(data, beforeData)
  );
}

/** Vrai quand au moins un champ a changé, et seulement parmi [fields]. */
function onlyFieldsChanged(
  before: Record<string, unknown>,
  after: Record<string, unknown>,
  fields: ReadonlySet<string>,
): boolean {
  const keys = new Set([...Object.keys(before), ...Object.keys(after)]);
  let changed = false;
  for (const key of keys) {
    if (isDeepStrictEqual(before[key], after[key])) continue;
    if (!fields.has(key)) return false;
    changed = true;
  }
  return changed;
}

/**
 * Pose `tags.meal_role` (et `contains`, `suggested_sides`, `main_protein`,
 * `main_starch`) si le rôle est absent. La protéine et le féculent viennent du
 * même appel ; ils ne déclenchent jamais un appel à eux seuls : un
 * déclencheur qui rappellerait le modèle tant qu'ils manquent le rappellerait
 * à chaque écho de sa propre écriture.
 *
 * Un seul appel de modèle, sur le rôle seul — les types de plat déjà connus ne
 * sont pas redemandés. Si le modèle ne sait pas classer la recette, rien n'est
 * écrit : elle reste sans rôle, et la prochaine écriture — ou le backfill
 * « Rôle des recettes dans un repas » — retentera. Aucun compteur d'essais, aucun délai de
 * reprise : un seul champ à remplir ne justifie pas le mécanisme de budget de
 * l'enrichissement nutritionnel, et reproduire sa marque « tentative
 * récente » reproduirait aussi son défaut — une coupure de budget comptée
 * comme un échec réel, qui bloque toute reprise automatique pendant 24 h.
 *
 * Il lit en revanche le compteur du backfill (`meal_role_failure_count`) :
 * une recette que le backfill n'a plus le droit de soumettre au modèle ne lui
 * est pas soumise non plus ici (`mealRoleCallAllowed`), sauf si son contenu
 * vient de changer — et le compteur repart alors à zéro
 * (`mealRoleFailureResetNeeded`).
 */
export async function syncRecipeMealRole(args: {
  recipeId: string;
  data: Record<string, unknown>;
  /** Le document avant l'écriture, absent à la création. */
  beforeData?: Record<string, unknown>;
  correlationId: string;
  scanId?: string;
}): Promise<void> {
  const { recipeId, data, correlationId, scanId } = args;

  // Jamais vide : une recette sans propriétaire s'impute au compte des
  // recettes orphelines, plafonné comme un autre (`ai/budget.ts`). Un uid vide
  // faisait passer l'appel hors de tout plafond.
  const userId = recipeBudgetUserId(data.created_by);
  const titre = asString(data.titre);

  // Avant l'appel, et indépendamment de son issue : un appel qui échoue ici
  // ne compte pas d'échec, et le backfill reprendra la recette avec un
  // compteur à zéro. L'écho de cette écriture ne change que la mémoire des
  // échecs : `mealRoleCallAllowed` l'écarte, et le contenu n'a pas bougé.
  if (mealRoleFailureResetNeeded(data, args.beforeData)) {
    await resetMealRoleFailures({ recipeId, correlationId, userId, scanId, titre });
  }

  if (!mealRoleCallAllowed(data, args.beforeData)) return;
  const tags = (data.tags && typeof data.tags === "object" ? data.tags : {}) as Record<
    string,
    unknown
  >;

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

    const patch = mainIngredientsPatch(tags, fields);
    await getFirestore()
      .collection(COLL_RECIPES)
      .doc(recipeId)
      .update({
        "tags.meal_role": fields.mealRole,
        "tags.contains": fields.contains,
        "tags.suggested_sides": fields.suggestedSides,
        // Une valeur posée à la main avant le classement n'est pas remplacée.
        ...(patch.main_protein ? { "tags.main_protein": patch.main_protein } : {}),
        ...(patch.main_starch ? { "tags.main_starch": patch.main_starch } : {}),
        ...(fields.mainIngredientsChecked
          ? { "tags.main_ingredients_checked_at": FieldValue.serverTimestamp() }
          : {}),
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

/**
 * Remet `meal_role_failure_count` à zéro (Admin SDK). Best-effort : un échec
 * est journalisé et laisse le compteur en place ; l'appel de modèle part
 * quand même, `mealRoleCallAllowed` ne dépendant pas de cette écriture.
 */
async function resetMealRoleFailures(args: {
  recipeId: string;
  correlationId: string;
  userId: string;
  scanId?: string;
  titre: string;
}): Promise<void> {
  const { recipeId, correlationId, userId, scanId, titre } = args;
  try {
    await getFirestore()
      .collection(COLL_RECIPES)
      .doc(recipeId)
      .update({ meal_role_failure_count: 0 });
  } catch (e) {
    await logError({
      message:
        "syncRecipeMealRole: compteur d'échecs non remis à zéro après un changement de contenu",
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
