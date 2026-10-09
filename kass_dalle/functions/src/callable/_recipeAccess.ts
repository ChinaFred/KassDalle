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

import { isAdminAccount } from "./_auth";

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
