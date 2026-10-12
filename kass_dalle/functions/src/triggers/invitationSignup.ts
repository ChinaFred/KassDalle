/**
 * Première connexion d'un invité : le rôle et le groupe de son invitation.
 *
 * Un compte neuf naît `pending` (règle de création de `users/{uid}`). Si son
 * adresse Google correspond à une invitation active, ce déclencheur lui donne
 * le rôle de l'invitation, l'ajoute aux membres du groupe et passe
 * l'invitation à `accepted`. C'est la seule exception au sas d'entrée, et
 * c'est le serveur qui la décide : le client ne peut ni lire les invitations
 * ni se donner un rôle.
 *
 * Précautions :
 *  - l'adresse qui décide est celle du **compte Auth** (`getUser`), et elle
 *    doit être vérifiée (`emailVerified`, toujours vrai pour un compte Google) ;
 *  - n'agit que sur un document `pending` et non révoqué, relu dans la
 *    transaction : un administrateur qui a déjà nommé le compte garde la main ;
 *  - le fondateur n'est jamais concerné (`enforceFounderRole` le gère) ;
 *  - groupe supprimé entre-temps : le rôle est donné quand même, et
 *    l'invitation porte `group_missing: true`.
 *
 * L'écriture du rôle réveille `syncUserClaims`, qui pose les claims et le
 * profil public, et l'ajout au groupe réveille `syncGroupReach`. Le client
 * suit `users/{uid}` en temps réel : la salle d'attente se ferme seule.
 */

import { onDocumentCreated } from "firebase-functions/v2/firestore";
import { getAuth } from "firebase-admin/auth";
import { FieldValue, getFirestore, Timestamp } from "firebase-admin/firestore";

import { COLL_GROUPS, COLL_INVITATIONS, REGION } from "../config";
import { logError, logInfo } from "../logging";
import { isFounderEmail } from "./founderRole";
import { isInvitableRole, normalizeEmailKey, pickActiveInvitation } from "../invitations/rules";

/** Vrai si le document décrit un compte qui attend un rôle. Pure, testée. */
export function awaitsRole(data: Record<string, unknown> | undefined | null): boolean {
  if (!data) return false;
  return data.role === "pending" && data.is_revoked !== true;
}

export const applyEmailInvitation = onDocumentCreated(
  { document: "users/{uid}", region: REGION },
  async (event) => {
    const uid = event.params.uid;
    const data = event.data?.data() as Record<string, unknown> | undefined;
    if (!awaitsRole(data)) return;

    let authEmail: string | undefined;
    let verified = false;
    try {
      const user = await getAuth().getUser(uid);
      authEmail = user.email;
      verified = user.emailVerified === true;
    } catch (err) {
      await logError({
        message: `applyEmailInvitation: compte Auth introuvable pour ${uid}`,
        errorDescription: err instanceof Error ? err.message : String(err),
        userId: uid,
      });
      return;
    }

    if (!authEmail || isFounderEmail(authEmail)) return;
    const key = normalizeEmailKey(authEmail);
    if (key === null) return;

    const db = getFirestore();
    const userRef = db.doc(`users/${uid}`);
    const invitations = db.collection(COLL_INVITATIONS);

    try {
      const outcome = await db.runTransaction(async (tx) => {
        const sameKey = await tx.get(invitations.where("email_key", "==", key));
        if (sameKey.empty) return null;
        const now = new Date();
        const chosen = pickActiveInvitation(
          sameKey.docs.map((d) => ({ ref: d.ref, id: d.id, data: d.data() })),
          now,
        );
        if (chosen === null) return null;
        // Adresse non vérifiée : on ne donne rien, mais on le dit.
        if (!verified) return { skipped: "unverified" as const, invitationId: chosen.id };

        const role = chosen.data.role;
        if (!isInvitableRole(role))
          return { skipped: "bad_role" as const, invitationId: chosen.id };

        const userSnap = await tx.get(userRef);
        if (!awaitsRole(userSnap.data())) return null;

        const groupId = typeof chosen.data.group_id === "string" ? chosen.data.group_id : "";
        const groupRef = groupId ? db.collection(COLL_GROUPS).doc(groupId) : null;
        const groupSnap = groupRef ? await tx.get(groupRef) : null;
        const groupExists = groupSnap?.exists === true;

        tx.update(userRef, { role });
        if (groupExists && groupRef) {
          tx.update(groupRef, {
            member_ids: FieldValue.arrayUnion(uid),
            invited_ids: FieldValue.arrayRemove(uid),
          });
        }
        tx.update(chosen.ref, {
          status: "accepted",
          accepted_uid: uid,
          accepted_at: Timestamp.fromDate(now),
          group_missing: !groupExists,
        });
        return { applied: true as const, invitationId: chosen.id, role, groupId, groupExists };
      });

      if (outcome === null) return;
      if ("skipped" in outcome) {
        await logInfo({
          message:
            outcome.skipped === "unverified"
              ? "applyEmailInvitation: adresse non vérifiée, invitation non appliquée"
              : "applyEmailInvitation: rôle d'invitation illisible, invitation non appliquée",
          userId: uid,
          firestoreDocId: outcome.invitationId,
        });
        return;
      }
      await logInfo({
        message:
          `applyEmailInvitation: invitation appliquée (rôle ${outcome.role}` +
          (outcome.groupExists ? `, groupe ${outcome.groupId})` : ", groupe introuvable)"),
        userId: uid,
        firestoreDocId: outcome.invitationId,
      });
    } catch (err) {
      await logError({
        message: `applyEmailInvitation: invitation non appliquée pour ${uid}`,
        errorDescription: err instanceof Error ? err.message : String(err),
        userId: uid,
      });
    }
  },
);
