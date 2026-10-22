/**
 * Écriture sur une recette par une callable : la même règle que
 * `allow update` sur `recipes` dans `firestore.rules`.
 *
 * Le conseil de dressage, le conseil de conservation, le visuel d'étape et le
 * calcul de nutrition lisent et écrivent la recette par l'Admin SDK, hors des
 * règles. La v0.23.8 y refusait la recette privée d'un autre. Restait la
 * recette partagée d'un autre (faille 5 de l'audit) : n'importe quel compte
 * déclenchait l'appel facturé, écrasait le résultat précédent, et
 * l'instruction libre d'un tiers était stockée dans
 * `plating_advice.user_instruction`. Décision de l'utilisateur (v0.23.9) :
 * seuls le créateur et un administrateur déclenchent ces écritures.
 */

import { HttpsError } from "firebase-functions/v2/https";

import { logWarn } from "../logging";
import { isAdminAccount, isEditorAccount } from "./_auth";

/**
 * Refus d'écrire sur une recette, ou `null` si permis. Pure et exportée pour
 * être testée : seuls le créateur (`created_by` non vide, égal à l'appelant)
 * et un administrateur écrivent. Une recette absente (`data` indéfini) ou sans
 * `created_by` n'appartient à personne : seul l'administrateur y écrit.
 */
export function recipeWriteDenial(args: {
  data: Record<string, unknown> | undefined;
  callerUid: string;
  callerIsAdmin: boolean;
}): string | null {
  const createdBy = typeof args.data?.created_by === "string" ? args.data.created_by : "";
  if (createdBy.length > 0 && createdBy === args.callerUid) return null;
  if (args.callerIsAdmin) return null;
  return (
    "Seuls le créateur de cette recette et un administrateur peuvent y enregistrer " +
    "un conseil ou un calcul."
  );
}

/**
 * Lève `permission-denied` si l'appelant ne peut pas écrire sur la recette,
 * AVANT tout appel de modèle. Écrire implique lire : le créateur et
 * l'administrateur lisent aussi une recette privée, ce contrôle couvre donc
 * la confidentialité qu'assurait `assertCanReadRecipe` (v0.23.8). Le rôle
 * administrateur n'est relu (sur le document) que si l'appelant n'est pas le
 * créateur.
 */
export async function assertCanModifyRecipe(
  data: Record<string, unknown> | undefined,
  callerUid: string,
): Promise<void> {
  if (recipeWriteDenial({ data, callerUid, callerIsAdmin: false }) == null) return;
  const denial = recipeWriteDenial({
    data,
    callerUid,
    callerIsAdmin: await isAdminAccount(callerUid),
  });
  if (denial) throw new HttpsError("permission-denied", denial);
}

/**
 * Refus de normaliser une recette contre les référentiels, ou `null` si
 * permis. Pure et exportée pour être testée.
 *
 * La normalisation (`normalizeRecipeReferentialsFn`) crée et enrichit les
 * fiches du référentiel partagé `nutrition_ingredients` à partir des noms
 * reçus, et appelle des modèles (unités, poids, per100g). Éditeur et
 * administrateur seulement, avec ou sans recette : la création d'une recette
 * normalise avant que le document existe. Le lecteur y passait pour
 * enregistrer une de ses recettes ; il ne modifie plus ses recettes et toute
 * IA est réservée aux éditeurs (v0.24.66, tickets #162 et #163).
 */
export function referentialNormalizationDenial(args: { callerIsEditor: boolean }): string | null {
  if (args.callerIsEditor) return null;
  return "La normalisation d'une recette est réservée aux éditeurs et aux administrateurs.";
}

/**
 * Lève `permission-denied` si l'appelant n'est ni éditeur ni administrateur,
 * AVANT toute écriture dans le référentiel et tout appel de modèle. Le rôle
 * est relu sur le document.
 */
export async function assertCanNormalizeReferentials(args: {
  recipeId: unknown;
  callerUid: string;
  correlationId: string;
}): Promise<void> {
  const denial = referentialNormalizationDenial({
    callerIsEditor: await isEditorAccount(args.callerUid),
  });
  if (!denial) return;
  await logWarn({
    message: "Normalisation refusée : compte qui n'est pas éditeur",
    userId: args.callerUid,
    correlationId: args.correlationId,
    feature: "normalisation_referentiels",
    extra: { recipeId: typeof args.recipeId === "string" ? args.recipeId.slice(0, 200) : null },
  });
  throw new HttpsError("permission-denied", denial);
}
