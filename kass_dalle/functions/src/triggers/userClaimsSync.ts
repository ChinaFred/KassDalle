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
 */

import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { onCall } from "firebase-functions/v2/https";
import { getFirestore } from "firebase-admin/firestore";

import { requireAdmin } from "../callable/_auth";
import { getAuth } from "firebase-admin/auth";

import { REGION, MAX_CALLABLE_INSTANCES } from "../config";
import { logError, logInfo } from "../logging";

/** Claims dérivés du document utilisateur. */
interface UserClaims {
  role: string | null;
  revoked: boolean;
}

function claimsFrom(data: Record<string, unknown> | undefined): UserClaims {
  if (!data) return { role: null, revoked: false };
  const role = typeof data.role === "string" && data.role.trim() ? data.role.trim() : null;
  return { role, revoked: data.is_revoked === true };
}

function sameClaims(a: UserClaims, b: UserClaims): boolean {
  return a.role === b.role && a.revoked === b.revoked;
}

export const syncUserClaims = onDocumentWritten(
  { document: "users/{uid}", region: REGION },
  async (event) => {
    const uid = event.params.uid;
    const before = claimsFrom(event.data?.before?.data() as Record<string, unknown> | undefined);
    const after = claimsFrom(event.data?.after?.data() as Record<string, unknown> | undefined);

    // Rien à faire si ni le rôle ni la révocation n'ont bougé : ce déclencheur
    // se réveille à chaque écriture sur le document, y compris pour des champs
    // sans rapport.
    if (sameClaims(before, after)) return;

    if (!event.data?.after?.exists) {
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
  },
);

/**
 * Amorce les claims de tous les comptes existants.
 *
 * Le déclencheur ci-dessus ne se réveille qu'à l'écriture d'un document
 * `users/{uid}`, or ces documents bougent rarement. Sans ce parcours initial,
 * aucun compte déjà créé ne porterait de claim, et les règles Storage — qui
 * faillent ouvert par conception — resteraient inertes.
 *
 * Idempotent : relancer ne fait que réécrire les mêmes valeurs.
 */
export const backfillUserClaimsFn = onCall(
  {
    region: REGION,
    memory: "256MiB",
    timeoutSeconds: 540,
    cors: true,
    maxInstances: MAX_CALLABLE_INSTANCES,
  },
  async (req) => {
    await requireAdmin(req);

    const db = getFirestore();
    const snap = await db.collection("users").get();
    let updated = 0;
    let failed = 0;

    for (const doc of snap.docs) {
      const claims = claimsFrom(doc.data() as Record<string, unknown>);
      try {
        await getAuth().setCustomUserClaims(doc.id, {
          role: claims.role,
          revoked: claims.revoked,
        });
        updated++;
      } catch (err) {
        // Un compte Firestore sans compte Auth correspondant fait échouer
        // l'écriture. Ce n'est pas bloquant, mais doit rester visible.
        failed++;
        await logError({
          message: `backfillUserClaims: échec pour ${doc.id}`,
          errorDescription: err instanceof Error ? err.message : String(err),
          userId: doc.id,
        });
      }
    }

    await logInfo({
      message: `backfillUserClaims: ${updated} compte(s) amorcé(s), ${failed} en échec`,
      extra: { scanned: snap.size },
    });
    return { scanned: snap.size, updated, failed };
  },
);
