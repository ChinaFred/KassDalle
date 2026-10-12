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
import { getFirestore } from "firebase-admin/firestore";

import { COLL_RECIPES } from "../config";
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
 * reçus. Elle restait ouverte à tout compte nommé : un lecteur y écrivait des
 * noms de son choix, sans recette (audit sécurité, « Faible »).
 *
 *  - Éditeur et administrateur : permis, avec ou sans recette — la création
 *    d'une recette normalise avant que le document existe.
 *  - Lecteur : seulement pour une recette existante dont il est le créateur.
 *    C'est le seul parcours qui l'y amène : l'enregistrement d'une de ses
 *    recettes, que les règles Firestore lui permettent de modifier. Les noms
 *    restent ceux de la requête, puisque la normalisation précède
 *    l'enregistrement : relire la recette normaliserait la version d'avant.
 *    L'enregistrement fait de toute façon passer ces mêmes noms dans le
 *    référentiel par le déclencheur `onRecipeWritten`.
 */
export function referentialNormalizationDenial(args: {
  callerIsEditor: boolean;
  recipeId: string | undefined;
  recipeData: Record<string, unknown> | undefined;
  callerUid: string;
}): string | null {
  if (args.callerIsEditor) return null;
  const denial =
    "La normalisation d'une recette est réservée aux éditeurs, et au créateur " +
    "de la recette pour l'enregistrer.";
  if (!args.recipeId || args.recipeData === undefined) return denial;
  return recipeWriteDenial({
    data: args.recipeData,
    callerUid: args.callerUid,
    callerIsAdmin: false,
  }) == null
    ? null
    : denial;
}

/** Identifiant de document plausible : chaîne non vide, sans « / », bornée. */
function isDocumentId(value: unknown): value is string {
  return (
    typeof value === "string" && value.length > 0 && value.length <= 1500 && !value.includes("/")
  );
}

/**
 * Lève `permission-denied` si l'appelant ne peut pas normaliser
 * [recipeId], AVANT toute écriture dans le référentiel et tout appel de
 * modèle. Le rôle est relu sur le document ; la recette n'est lue que pour un
 * lecteur.
 */
export async function assertCanNormalizeReferentials(args: {
  recipeId: unknown;
  callerUid: string;
  correlationId: string;
}): Promise<void> {
  if (await isEditorAccount(args.callerUid)) return;
  const recipeId = isDocumentId(args.recipeId) ? args.recipeId : undefined;
  const recipeData = recipeId
    ? (await getFirestore().collection(COLL_RECIPES).doc(recipeId).get()).data()
    : undefined;
  const denial = referentialNormalizationDenial({
    callerIsEditor: false,
    recipeId,
    recipeData,
    callerUid: args.callerUid,
  });
  if (!denial) return;
  await logWarn({
    message: "Normalisation refusée : lecteur hors de ses propres recettes",
    userId: args.callerUid,
    correlationId: args.correlationId,
    feature: "normalisation_referentiels",
    extra: { recipeId: typeof args.recipeId === "string" ? args.recipeId.slice(0, 200) : null },
  });
  throw new HttpsError("permission-denied", denial);
}
