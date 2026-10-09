/**
 * Lecture d'une recette par une callable : la même confidentialité que les
 * règles Firestore.
 *
 * Les callables lisent les recettes par l'Admin SDK, hors des règles. Le
 * conseil de dressage, le conseil de conservation, le visuel d'une étape et le
 * calcul de nutrition lisaient donc la recette privée d'un autre — son texte
 * partait dans un prompt, et le résultat revenait à l'appelant. Ce contrôle
 * ne porte que sur la LECTURE : qui peut écrire un conseil sur une recette
 * partagée reste une décision à venir (faille 5 de l'audit).
 */

import { HttpsError } from "firebase-functions/v2/https";

import { isAdminAccount } from "./_auth";

/**
 * Refus de lire une recette, ou `null` si permis. Pure et exportée pour être
 * testée : une recette privée (`is_private === true`) ne se lit que par son
 * créateur ou un administrateur.
 */
export function privateRecipeReadDenial(args: {
  data: Record<string, unknown> | undefined;
  callerUid: string;
  callerIsAdmin: boolean;
}): string | null {
  if (args.data?.is_private !== true) return null;
  const createdBy = typeof args.data.created_by === "string" ? args.data.created_by : "";
  if (createdBy.length > 0 && createdBy === args.callerUid) return null;
  if (args.callerIsAdmin) return null;
  return "Cette recette est privée : seuls son créateur et un administrateur y accèdent.";
}

/**
 * Lève `permission-denied` si l'appelant ne peut pas lire la recette, AVANT
 * tout appel de modèle. Le rôle administrateur n'est relu (sur le document)
 * que pour une recette privée d'un autre.
 */
export async function assertCanReadRecipe(
  data: Record<string, unknown> | undefined,
  callerUid: string,
): Promise<void> {
  if (privateRecipeReadDenial({ data, callerUid, callerIsAdmin: false }) == null) return;
  const denial = privateRecipeReadDenial({
    data,
    callerUid,
    callerIsAdmin: await isAdminAccount(callerUid),
  });
  if (denial) throw new HttpsError("permission-denied", denial);
}
