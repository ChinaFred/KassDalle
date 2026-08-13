/**
 * Helpers pour les Cloud Functions HTTPS Callable.
 *
 * Centralise :
 *  - Vérification d'authentification (rejet si pas connecté)
 *  - Vérification de rôle (admin uniquement pour certaines functions)
 *  - Génération d'un correlationId par appel
 */

import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";
import { COLL_USERS } from "../config";
import { newCorrelationId } from "../logging";

export interface AuthContext {
  userId: string;
  correlationId: string;
}

/** Exige un utilisateur authentifié, retourne son uid + un correlationId frais. */
export function requireAuth(req: CallableRequest<unknown>): AuthContext {
  const uid = req.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Authentification requise.");
  }
  return { userId: uid, correlationId: newCorrelationId("call") };
}

/** Exige que l'utilisateur connecté ait le rôle admin (lecture Firestore users/{uid}). */
export async function requireAdmin(req: CallableRequest<unknown>): Promise<AuthContext> {
  const ctx = requireAuth(req);
  const snap = await getFirestore().collection(COLL_USERS).doc(ctx.userId).get();
  const role = snap.data()?.role as string | undefined;
  if (role !== "admin") {
    throw new HttpsError("permission-denied", "Réservé aux administrateurs.");
  }
  return ctx;
}

/**
 * Exige un rôle capable de modifier le contenu (admin ou editor).
 *
 * Un `reader` peut consulter et demander du conseil ; il ne déclenche pas les
 * postes qui écrivent dans une recette ou qui coûtent à l'image.
 */
export async function requireEditor(req: CallableRequest<unknown>): Promise<AuthContext> {
  const ctx = requireAuth(req);
  const snap = await getFirestore().collection(COLL_USERS).doc(ctx.userId).get();
  const role = snap.data()?.role as string | undefined;
  if (role !== "admin" && role !== "editor") {
    throw new HttpsError("permission-denied", "Réservé aux éditeurs et administrateurs.");
  }
  return ctx;
}
