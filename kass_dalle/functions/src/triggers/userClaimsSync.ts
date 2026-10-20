/**
 * Synchronise le rôle et la révocation d'un utilisateur vers ses custom claims.
 *
 * Pourquoi passer par les claims plutôt que par une lecture Firestore depuis les
 * règles Storage : une règle qui appelle `firestore.get()` est une lecture
 * inter-services. Elle est facturée à chaque requête d'image, et surtout elle
 * peut échouer — auquel cas la règle entière est refusée. C'est ce qui a cassé
 * l'import de recettes : l'envoi vers `quarantine/` était rejeté alors que la
 * seule condition réelle était une égalité d'identifiant.
 *
 * Un claim, lui, voyage dans le jeton. Les règles le lisent sans appel réseau,
 * sans coût, et son absence ne provoque jamais d'erreur — seulement une
 * comparaison fausse. C'est la seule forme d'autorisation qu'une règle Storage
 * peut évaluer de façon fiable.
 *
 * Contrepartie : un claim n'est rafraîchi qu'au renouvellement du jeton. Une
 * révocation devient donc effective sur les images au prochain rafraîchissement
 * (une heure au plus), immédiatement sur les données Firestore qui, elles,
 * lisent le document utilisateur.
 *
 * Quand un compte perd l'accès — révoqué, rôle sorti de reader/editor/admin,
 * document supprimé —, ses jetons de rafraîchissement sont en plus invalidés
 * (`revokeRefreshTokens`) : la session ne se renouvelle plus, et le jeton en
 * cours n'est plus prolongé au-delà de son heure. Les callables relisent le
 * document à chaque appel (`requireAuth`) et n'attendent pas cette heure.
 *
 * Quand un compte révoqué est rétabli, le même déclencheur annule les
 * invitations de retour encore actives qui le visent
 * (`cancelStaleReturnInvitations`, `invitationSignup.ts`).
 *
 * Le même déclencheur tient le profil public `user_profiles/{uid}`
 * (`userPublicProfile.ts`, v0.23.14), pour ne pas ajouter un déclencheur
 * de plus sur `users/{uid}`. La portée des plannings, elle, a son propre
 * déclencheur (`syncPlanningReachOnRole`) : elle doit rejouer en cas
 * d'échec (`retry: true`), ce que celui-ci ne fait pas. Le profil
 * est traité avant les claims et indépendamment d'eux : l'un peut échouer
 * sans empêcher l'autre, et chacun laisse sa trace.
 *
 * Il crée aussi les livres système du compte quand celui-ci reçoit l'accès
 * (`gainsAccess`) : approbation d'un compte en attente, ou levée d'une
 * révocation. Le client ne les crée que pour un éditeur ou un administrateur ;
 * un lecteur approuvé les reçoit ici (`books/systemBooks.ts`).
 */

import { onDocumentWritten } from "firebase-functions/v2/firestore";

import { getAuth } from "firebase-admin/auth";
import { getFirestore } from "firebase-admin/firestore";

import { COLL_USERS, REGION } from "../config";
import { ensureSystemBooksFor } from "../books/systemBooks";
import { logError, logInfo, newCorrelationId } from "../logging";
import { syncPublicProfile } from "./userPublicProfile";
import { cancelStaleReturnInvitations } from "./invitationSignup";
import { isAccessRestored } from "../invitations/rules";
import { readRole } from "../security/roles";

/** Claims dérivés du document utilisateur. */
export interface UserClaims {
  role: string | null;
  revoked: boolean;
}

/**
 * Le rôle et la révocation à poser en claims. Pure, testée.
 *
 * Le rôle n'est gardé que s'il vaut `admin`, `editor`, `reader` ou `pending`,
 * à l'identique (`readRole`) : un `"superadmin"` ou un `"admin "` donne
 * `role: null`, donc aucun accès, comme dans `firestore.rules`.
 */
export function claimsFrom(data: Record<string, unknown> | undefined): UserClaims {
  if (!data) return { role: null, revoked: false };
  return { role: readRole(data.role), revoked: data.is_revoked === true };
}

function sameClaims(a: UserClaims, b: UserClaims): boolean {
  return a.role === b.role && a.revoked === b.revoked;
}

const APPROVED_ROLES = ["reader", "editor", "admin"];

function isApprovedRole(role: string | null): boolean {
  return role !== null && APPROVED_ROLES.includes(role);
}

/**
 * Faut-il couper les sessions du compte (`revokeRefreshTokens`) ?
 *
 * Oui quand il perd l'accès : il passe à révoqué, son rôle sort de
 * reader/editor/admin (remis en `pending`, effacé), ou son document est
 * supprimé alors qu'il avait un rôle nommé.
 */
export function shouldRevokeSessions(
  before: UserClaims,
  after: UserClaims,
  afterExists: boolean,
): boolean {
  if (!afterExists) return isApprovedRole(before.role) || before.revoked;
  if (!before.revoked && after.revoked) return true;
  return isApprovedRole(before.role) && !isApprovedRole(after.role);
}

/**
 * Le compte reçoit-il l'accès à l'application ? Oui quand il devient
 * `reader`, `editor` ou `admin` non révoqué alors qu'il ne l'était pas :
 * approbation d'un compte en attente, levée d'une révocation. Un changement
 * de rôle entre deux rôles approuvés ne compte pas.
 */
export function gainsAccess(before: UserClaims, after: UserClaims, afterExists: boolean): boolean {
  if (!afterExists) return false;
  const hadAccess = isApprovedRole(before.role) && !before.revoked;
  const hasAccess = isApprovedRole(after.role) && !after.revoked;
  return hasAccess && !hadAccess;
}

/** Crée les livres système manquants ; un échec est journalisé, jamais tu. */
async function ensureBooksOnAccess(
  uid: string,
  data: Record<string, unknown> | undefined,
): Promise<void> {
  const displayName = (typeof data?.display_name === "string" && data.display_name.trim()) || "";
  const ctx = { userId: uid, correlationId: newCorrelationId("system_books") };
  const progress = { created: 0 };
  try {
    await ensureSystemBooksFor(uid, displayName, ctx, progress);
    if (progress.created > 0) {
      await logInfo({
        message: `syncUserClaims: ${progress.created} livre(s) système créé(s) pour ${uid}`,
        ...ctx,
      });
    }
  } catch (err) {
    await logError({
      message: `syncUserClaims: livres système non créés pour ${uid}`,
      errorDescription: err instanceof Error ? err.message : String(err),
      ...ctx,
      extra: { created: progress.created },
    });
  }
}

/** Révoque les jetons de rafraîchissement ; un échec est journalisé, jamais tu. */
async function revokeSessions(uid: string, reason: string): Promise<void> {
  try {
    await getAuth().revokeRefreshTokens(uid);
    await logInfo({
      message: `syncUserClaims: jetons de rafraîchissement révoqués pour ${uid} (${reason})`,
      userId: uid,
    });
  } catch (err) {
    await logError({
      message: `syncUserClaims: révocation des jetons impossible pour ${uid} (${reason})`,
      errorDescription: err instanceof Error ? err.message : String(err),
      userId: uid,
    });
  }
}

/** Résultat de la relecture de `users/{uid}` au moment d'agir. */
export type UserReread =
  { kind: "found"; data: Record<string, unknown> } | { kind: "missing" } | { kind: "failed" };

/**
 * L'état du document à appliquer, d'après la relecture. Pure, testée.
 *
 *  - document trouvé : son contenu actuel ;
 *  - document absent : supprimé entre l'événement et la relecture. On le
 *    traite comme une suppression (claims effacés, sessions coupées s'il avait
 *    un rôle nommé). Reposer les claims de l'instantané rendrait un rôle à un
 *    compte supprimé, si l'exécution de la suppression passait avant celle-ci ;
 *  - lecture en échec : repli sur l'instantané de l'événement, seule donnée
 *    disponible (l'échec est journalisé par l'appelant).
 */
export function stateAfterReread(
  eventAfter: Record<string, unknown> | undefined,
  reread: UserReread,
): { exists: boolean; data: Record<string, unknown> | undefined } {
  switch (reread.kind) {
    case "found":
      return { exists: true, data: reread.data };
    case "missing":
      return { exists: false, data: undefined };
    case "failed":
      return { exists: eventAfter !== undefined, data: eventAfter };
  }
}

/** Relit `users/{uid}`. Un échec de lecture est journalisé, jamais tu. */
async function rereadUser(uid: string): Promise<UserReread> {
  try {
    const snap = await getFirestore().collection(COLL_USERS).doc(uid).get();
    if (!snap.exists) return { kind: "missing" };
    return { kind: "found", data: (snap.data() as Record<string, unknown> | undefined) ?? {} };
  } catch (err) {
    await logError({
      message: `syncUserClaims: relecture du document impossible pour ${uid}`,
      errorDescription: err instanceof Error ? err.message : String(err),
      userId: uid,
    });
    return { kind: "failed" };
  }
}

export const syncUserClaims = onDocumentWritten(
  { document: "users/{uid}", region: REGION },
  async (event) => {
    const uid = event.params.uid;
    const eventAfter = event.data?.after?.exists
      ? (event.data.after.data() as Record<string, unknown> | undefined)
      : undefined;
    // Ce qui est écrit (profil, claims) vient du document tel qu'il est
    // maintenant, pas de l'instantané de l'événement : deux écritures
    // rapprochées réveillent deux exécutions dont l'ordre n'est pas garanti.
    // C'est le cas d'une invitation par e-mail (création `pending`, puis rôle
    // posé par `applyEmailInvitation` une seconde plus tard) : si l'exécution
    // de la création passait en dernier, elle remettait le claim `pending` et
    // effaçait le profil public d'un compte déjà nommé.
    // La relecture n'a lieu que si l'événement change le rôle ou la
    // révocation : une connexion ordinaire (`last_seen_at`) n'en coûte pas.
    const eventBefore = event.data?.before?.data() as Record<string, unknown> | undefined;
    const authorityMoved = !sameClaims(claimsFrom(eventBefore), claimsFrom(eventAfter));
    const current =
      eventAfter !== undefined && authorityMoved
        ? stateAfterReread(eventAfter, await rereadUser(uid))
        : { exists: eventAfter !== undefined, data: eventAfter };
    const afterData = current.data;

    try {
      const outcome = await syncPublicProfile(uid, afterData);
      if (outcome !== "unchanged") {
        await logInfo({ message: `syncUserClaims: profil public ${outcome}`, userId: uid });
      }
    } catch (err) {
      await logError({
        message: `syncUserClaims: profil public non synchronisé pour ${uid}`,
        errorDescription: err instanceof Error ? err.message : String(err),
        userId: uid,
      });
    }

    const before = claimsFrom(eventBefore);
    const after = claimsFrom(afterData);

    // Rien à faire si ni le rôle ni la révocation n'ont bougé : ce déclencheur
    // se réveille à chaque écriture sur le document, y compris pour des champs
    // sans rapport.
    if (!authorityMoved) return;

    // Absent de l'événement, ou supprimé avant la relecture : suppression.
    if (!current.exists) {
      // Utilisateur supprimé : les claims partent avec le compte, s'il existe
      // encore. Un compte déjà supprimé fait échouer setCustomUserClaims, ce
      // qui est sans conséquence — mais doit rester visible.
      try {
        await getAuth().setCustomUserClaims(uid, null);
        await logInfo({ message: `syncUserClaims: claims effacés pour ${uid}`, userId: uid });
      } catch (err) {
        await logError({
          message: `syncUserClaims: effacement impossible pour ${uid}`,
          errorDescription: err instanceof Error ? err.message : String(err),
          userId: uid,
        });
      }
      if (shouldRevokeSessions(before, after, false))
        await revokeSessions(uid, "document supprimé");
      return;
    }

    try {
      await getAuth().setCustomUserClaims(uid, {
        role: after.role,
        revoked: after.revoked,
      });
      await logInfo({
        message: `syncUserClaims: rôle="${after.role ?? "aucun"}" révoqué=${after.revoked}`,
        userId: uid,
      });
    } catch (err) {
      await logError({
        message: `syncUserClaims: écriture des claims impossible pour ${uid}`,
        errorDescription: err instanceof Error ? err.message : String(err),
        userId: uid,
        extra: { role: after.role, revoked: after.revoked },
      });
    }

    // Séparé de l'écriture des claims : l'un peut réussir sans l'autre, et
    // chacun doit laisser sa trace.
    if (shouldRevokeSessions(before, after, true)) {
      await revokeSessions(uid, after.revoked ? "révoqué" : `rôle ${after.role ?? "aucun"}`);
    }

    // Compte rétabli (à la main dans Comptes, ou par une invitation de
    // retour) : les invitations de retour encore actives n'ont plus d'objet.
    // Lu sur l'événement, pas sur la relecture : c'est cette écriture-là qui
    // rétablit.
    if (isAccessRestored(eventBefore, eventAfter)) {
      try {
        const at = new Date(event.time);
        await cancelStaleReturnInvitations(uid, Number.isNaN(at.getTime()) ? new Date() : at);
      } catch (err) {
        await logError({
          message: `syncUserClaims: invitations de retour non annulées pour ${uid}`,
          errorDescription: err instanceof Error ? err.message : String(err),
          userId: uid,
        });
      }
    }

    // Après les claims : un livre système ne conditionne pas l'accès, et son
    // échec n'empêche pas le reste. Le backfill `system_books` le rattrape.
    if (gainsAccess(before, after, true)) {
      await ensureBooksOnAccess(uid, afterData);
    }
  },
);
