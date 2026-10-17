/**
 * Titres des recettes validées des livres privés des membres de mes groupes.
 *
 * `listFamilyPrivateTitlesFn()` rend `{ titles: [{ id, titre, bookTitre,
 * createdBy }] }`. La feuille « Suggérer un plat » les propose avec un
 * cadenas : le destinataire d'une suggestion ne voit que ce titre. Les règles
 * Firestore interdisent la lecture d'une recette privée ; seul le serveur la
 * lit, et seuls ces quatre champs repartent (`privateTitleOf`).
 *
 * Ce que le serveur vérifie : un compte approuvé, non révoqué (`requireAuth`).
 * La portée vient de `group_reach/{uid}` du demandeur, écrit par le serveur :
 * un compte sans groupe en commun avec l'auteur ne reçoit rien de lui.
 *
 * Aucun appel de modèle : pas de poste d'IA.
 */

import { onCall, HttpsError } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import { COLL_GROUP_REACH, COLL_RECIPES, MAX_CALLABLE_INSTANCES, REGION } from "../config";
import { requireAuth } from "./_auth";
import { logError } from "../logging";
import {
  PRIVATE_TITLES_MAX_RESULTS,
  collectPrivateTitles,
  ownersToQuery,
  type PrivateTitle,
} from "../gemini/privateTitles";

const ALLOWED_ORIGINS = [
  "https://kassdale-6d948.web.app",
  "https://kassdale-6d948.firebaseapp.com",
];

export const listFamilyPrivateTitlesFn = onCall(
  {
    region: REGION,
    cors: ALLOWED_ORIGINS,
    maxInstances: MAX_CALLABLE_INSTANCES,
    timeoutSeconds: 30,
  },
  async (req): Promise<{ titles: PrivateTitle[] }> => {
    const ctx = await requireAuth(req, "titres_recettes_privees");
    try {
      const db = getFirestore();
      const reach = await db.collection(COLL_GROUP_REACH).doc(ctx.userId).get();
      const owners = ownersToQuery(reach.data()?.uids, ctx.userId);
      if (owners.length === 0) return { titles: [] };
      const snap = await db
        .collection(COLL_RECIPES)
        .where("created_by", "in", owners)
        .where("review_status", "==", "validated")
        .where("is_private", "==", true)
        .limit(PRIVATE_TITLES_MAX_RESULTS)
        .select("titre", "book_titre", "created_by", "review_status", "is_private", "page_type")
        .get();
      return {
        titles: collectPrivateTitles(snap.docs.map((d) => ({ id: d.id, data: d.data() }))),
      };
    } catch (err) {
      await logError({
        message: "listFamilyPrivateTitlesFn: lecture impossible",
        errorDescription: err instanceof Error ? err.message : String(err),
        userId: ctx.userId,
        correlationId: ctx.correlationId,
      });
      throw new HttpsError("internal", "Lecture impossible. Réessayez.");
    }
  },
);
