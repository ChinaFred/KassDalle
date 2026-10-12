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
 * Le même déclencheur tient le profil public `user_profiles/{uid}`
 * (`userPublicProfile.ts`, v0.23.14) : un second déclencheur sur
 * `users/{uid}` aurait doublé les réveils pour la même écriture. Le profil
 * est traité avant les claims et indépendamment d'eux : l'un peut échouer
 * sans empêcher l'autre, et chacun laisse sa trace.
 */

import { onDocumentWritten } from "firebase-functions/v2/firestore";

import { getAuth } from "firebase-admin/auth";

import { REGION } from "../config";
import { logError, logInfo } from "../logging";
import { syncPublicProfile } from "./userPublicProfile";

/** Claims dérivés du document utilisateur. */
export interface UserClaims {
  role: string | null;
  revoked: boolean;
}

export function claimsFrom(data: Record<string, unknown> | undefined): UserClaims {
  if (!data) return { role: null, revoked: false };
  const role = typeof data.role === "string" && data.role.trim() ? data.role.trim() : null;
  return { role, revoked: data.is_revoked === true };
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

export const syncUserClaims = onDocumentWritten(
  { document: "users/{uid}", region: REGION },
  async (event) => {
    const uid = event.params.uid;
    const afterData = event.data?.after?.exists
      ? (event.data.after.data() as Record<string, unknown> | undefined)
      : undefined;

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

    const before = claimsFrom(event.data?.before?.data() as Record<string, unknown> | undefined);
    const after = claimsFrom(event.data?.after?.data() as Record<string, unknown> | undefined);

    // Rien à faire si ni le rôle ni la révocation n'ont bougé : ce déclencheur
    // se réveille à chaque écriture sur le document, y compris pour des champs
    // sans rapport.
    if (sameClaims(before, after)) return;

    const afterExists = event.data?.after?.exists === true;

    if (!afterExists) {
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
  },
);
