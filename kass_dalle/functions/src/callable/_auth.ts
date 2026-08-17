/**
 * Helpers pour les Cloud Functions HTTPS Callable.
 *
 * Centralise :
 *  - Vérification d'authentification (rejet si pas connecté)
 *  - Vérification du sas d'entrée et de la révocation
 *  - Vérification de rôle (admin ou éditeur pour certaines functions)
 *  - Génération d'un correlationId par appel
 *
 * Être connecté ne suffit plus. Ces entrées dépensent de l'argent — chaque
 * appel part chez Gemini ou Anthropic — et elles n'étaient gardées que par la
 * présence d'un compte Google. Un compte en attente d'approbation, ou un
 * compte révoqué, les atteignait donc aussi bien qu'un membre de la famille.
 *
 * Deux sources d'autorité, dans cet ordre :
 *
 *  1. Les **claims du jeton** (`role`, `revoked`), entretenus par
 *     `syncUserClaims`. Gratuits, lus sans appel réseau.
 *  2. Le **document utilisateur**, lu seulement quand le jeton ne porte pas de
 *     claim de rôle — cas d'un jeton émis avant l'amorçage. Une lecture
 *     Firestore vaut infiniment moins qu'un appel d'IA laissé passer.
 *
 * La révocation, elle, est toujours relue sur le document pour les rôles
 * privilégiés : ils lisent déjà le document, et couper l'accès à un
 * administrateur ne doit pas attendre le renouvellement de son jeton.
 */

import { HttpsError, type CallableRequest } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";
import { COLL_USERS } from "../config";
import { newCorrelationId } from "../logging";

export interface AuthContext {
  userId: string;
  correlationId: string;
}

/** Les rôles qui ouvrent l'application. `pending` n'en fait pas partie. */
const APPROVED_ROLES = ["reader", "editor", "admin"] as const;
const EDITOR_ROLES = ["editor", "admin"] as const;

const PENDING_MESSAGE =
  "Votre compte attend l'approbation d'un administrateur avant de pouvoir utiliser l'application.";
const REVOKED_MESSAGE = "Votre accès a été révoqué.";

/** Ce qu'un compte présente : son rôle et son état, quelle qu'en soit la source. */
export interface AccountState {
  role: string | null;
  revoked: boolean;
}

/**
 * Décide si un compte peut passer, et pourquoi non le cas échéant.
 *
 * Pure et exportée pour être testée : c'est la seule règle d'autorisation des
 * callables, et elle ne doit pas dépendre d'un émulateur pour être vérifiée.
 * Retourne `null` quand l'accès est accordé.
 */
export function accessDenial(
  account: AccountState,
  need: "approved" | "editor" | "admin",
): { code: "permission-denied"; message: string } | null {
  if (account.revoked) {
    return { code: "permission-denied", message: REVOKED_MESSAGE };
  }
  const role = account.role;
  if (need === "admin") {
    return role === "admin"
      ? null
      : { code: "permission-denied", message: "Réservé aux administrateurs." };
  }
  if (need === "editor") {
    return role !== null && (EDITOR_ROLES as readonly string[]).includes(role)
      ? null
      : { code: "permission-denied", message: "Réservé aux éditeurs et administrateurs." };
  }
  return role !== null && (APPROVED_ROLES as readonly string[]).includes(role)
    ? null
    : { code: "permission-denied", message: PENDING_MESSAGE };
}

/** Le rôle et l'état portés par le jeton, `role: null` si le claim manque. */
export function accountFromToken(req: CallableRequest<unknown>): AccountState {
  const token = req.auth?.token as Record<string, unknown> | undefined;
  const role = typeof token?.role === "string" && token.role.trim() ? token.role.trim() : null;
  return { role, revoked: token?.revoked === true };
}

function baseContext(req: CallableRequest<unknown>, feature: string): AuthContext {
  const uid = req.auth?.uid;
  if (!uid) {
    throw new HttpsError("unauthenticated", "Authentification requise.");
  }
  return { userId: uid, correlationId: newCorrelationId(feature) };
}

async function accountFromFirestore(uid: string): Promise<AccountState> {
  const snap = await getFirestore().collection(COLL_USERS).doc(uid).get();
  const data = snap.data();
  const role = typeof data?.role === "string" && data.role.trim() ? data.role.trim() : null;
  return { role, revoked: data?.is_revoked === true };
}

function deny(denial: { message: string }): never {
  throw new HttpsError("permission-denied", denial.message);
}

/**
 * Exige un compte connecté, nommé et non révoqué. Retourne son uid + un
 * correlationId frais.
 *
 * `feature` nomme le traitement, et ce nom se retrouve dans la racine du
 * `correlationId` : c'est lui que l'écran de logs affiche en titre de groupe.
 * Toutes les callables partageaient auparavant le préfixe « call », si bien que
 * l'écran alignait des dizaines de traitements tous intitulés « call » — un
 * regroupement correct, et illisible.
 */
export async function requireAuth(
  req: CallableRequest<unknown>,
  feature = "call",
): Promise<AuthContext> {
  const ctx = baseContext(req, feature);
  const fromToken = accountFromToken(req);

  // Un jeton qui porte son rôle tranche seul : pas de lecture Firestore sur le
  // chemin normal. Sans claim, on va lire le document plutôt que de laisser
  // passer — c'est le seul moyen de tenir le sas d'entrée dès la première
  // minute d'un compte, avant que son jeton ne soit renouvelé.
  const account = fromToken.role !== null ? fromToken : await accountFromFirestore(ctx.userId);

  const denial = accessDenial(account, "approved");
  if (denial) deny(denial);
  return ctx;
}

/** Exige le rôle admin (lu sur le document : une révocation ne s'attend pas). */
export async function requireAdmin(
  req: CallableRequest<unknown>,
  feature = "call",
): Promise<AuthContext> {
  const ctx = baseContext(req, feature);
  const denial = accessDenial(await accountFromFirestore(ctx.userId), "admin");
  if (denial) deny(denial);
  return ctx;
}

/**
 * Exige un rôle capable de modifier le contenu (admin ou editor).
 *
 * Un `reader` peut consulter et demander du conseil ; il ne déclenche pas les
 * postes qui écrivent dans une recette ou qui coûtent à l'image.
 */
export async function requireEditor(
  req: CallableRequest<unknown>,
  feature = "call",
): Promise<AuthContext> {
  const ctx = baseContext(req, feature);
  const denial = accessDenial(await accountFromFirestore(ctx.userId), "editor");
  if (denial) deny(denial);
  return ctx;
}
