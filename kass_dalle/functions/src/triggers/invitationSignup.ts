/**
 * Invitations par e-mail appliquées à la connexion : deux déclencheurs.
 *
 * `applyEmailInvitation` — première connexion d'un compte neuf : le rôle et
 * le groupe de son invitation (`target: "new"`).
 *
 * `applyRevokedInvitation` — reconnexion d'un compte révoqué invité de nouveau
 * (`target: "revoked"`, `target_uid`) : accès rétabli, rôle de l'invitation, et
 * une invitation de groupe à accepter. Détail plus bas.
 *
 * ## Compte neuf
 *
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
 *  - l'administrateur qui a fait le dernier envoi (`last_sent_by`, sinon
 *    `invited_by`) est relu dans la transaction : s'il n'est plus
 *    administrateur, ou s'il est révoqué, rien n'est appliqué. Le compte
 *    reste `pending` et l'invitation inchangée ; un administrateur en place
 *    décide à la main ;
 *  - groupe supprimé entre-temps : le rôle est donné quand même, et
 *    l'invitation porte `group_missing: true`.
 *
 * L'écriture du rôle réveille `syncUserClaims`, qui pose les claims et le
 * profil public, et l'ajout au groupe réveille `syncGroupReach`. Le client
 * suit `users/{uid}` en temps réel : la salle d'attente se ferme seule.
 */

import { onDocumentCreated, onDocumentUpdated } from "firebase-functions/v2/firestore";
import { getAuth } from "firebase-admin/auth";
import { FieldValue, getFirestore, Timestamp } from "firebase-admin/firestore";

import { COLL_GROUPS, COLL_INVITATIONS, COLL_USERS, REGION } from "../config";
import { accessDenial } from "../callable/_auth";
import { readRole } from "../security/roles";
import { logError, logInfo } from "../logging";
import { isFounderEmail } from "./founderRole";
import {
  asDate,
  groupInviteFor,
  invitationGroupOf,
  isInvitableRole,
  isOpenReturnInvitationFor,
  isStaleReturnInvitation,
  normalizeEmailKey,
  pickActiveInvitation,
  staleReturnInvitations,
} from "../invitations/rules";

/** Vrai si le document décrit un compte qui attend un rôle. Pure, testée. */
export function awaitsRole(data: Record<string, unknown> | undefined | null): boolean {
  if (!data) return false;
  return data.role === "pending" && data.is_revoked !== true;
}

/** L'administrateur qui répond de l'invitation : dernier envoi, sinon création. */
export function inviterUidOf(invitation: Record<string, unknown>): string | null {
  for (const key of ["last_sent_by", "invited_by"]) {
    const v = invitation[key];
    if (typeof v === "string" && v.trim() && !v.includes("/")) return v.trim();
  }
  return null;
}

/**
 * Vrai si le compte de l'invitant peut encore donner un rôle : document
 * présent, rôle `admin`, non révoqué (même règle que `requireAdmin`). Pure.
 */
export function inviterStillAdmin(userData: Record<string, unknown> | undefined | null): boolean {
  if (!userData) return false;
  return (
    accessDenial(
      { role: readRole(userData.role), revoked: userData.is_revoked === true },
      "admin",
    ) === null
  );
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
        // Seules les invitations de compte neuf : une invitation de retour
        // vise un compte révoqué précis, jamais un compte qui naît.
        const chosen = pickActiveInvitation(
          sameKey.docs.map((d) => ({ ref: d.ref, id: d.id, data: d.data() })),
          now,
          { kind: "new" },
        );
        if (chosen === null) return null;
        // Adresse non vérifiée : on ne donne rien, mais on le dit.
        if (!verified) {
          return { skipped: "unverified" as const, invitationId: chosen.id, inviterUid: null };
        }

        const role = chosen.data.role;
        if (!isInvitableRole(role)) {
          return { skipped: "bad_role" as const, invitationId: chosen.id, inviterUid: null };
        }

        const inviterUid = inviterUidOf(chosen.data);
        if (inviterUid === null) {
          return { skipped: "no_inviter" as const, invitationId: chosen.id, inviterUid: null };
        }
        const inviterSnap = await tx.get(db.collection(COLL_USERS).doc(inviterUid));
        if (!inviterStillAdmin(inviterSnap.data())) {
          return { skipped: "inviter_not_admin" as const, invitationId: chosen.id, inviterUid };
        }

        const userSnap = await tx.get(userRef);
        if (!awaitsRole(userSnap.data())) return null;

        const groupId = typeof chosen.data.group_id === "string" ? chosen.data.group_id : "";
        const groupRef = groupId ? db.collection(COLL_GROUPS).doc(groupId) : null;
        const groupSnap = groupRef ? await tx.get(groupRef) : null;
        // Un groupe recréé sous le même identifiant par un autre compte, ou
        // une invitation sans `group_owner_id`, compte comme un groupe absent :
        // l'invité ne rejoint pas un groupe qu'on ne lui a pas proposé.
        const groupExists =
          groupSnap?.exists === true && invitationGroupOf(groupSnap.data(), chosen.data) !== null;

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
        switch (outcome.skipped) {
          case "unverified":
            await logInfo({
              message: "applyEmailInvitation: adresse non vérifiée, invitation non appliquée",
              userId: uid,
              firestoreDocId: outcome.invitationId,
            });
            return;
          case "inviter_not_admin":
            await logInfo({
              message:
                `applyEmailInvitation: l'invitant ${outcome.inviterUid} n'est plus ` +
                "administrateur (ou est révoqué), invitation non appliquée",
              userId: uid,
              firestoreDocId: outcome.invitationId,
            });
            return;
          case "bad_role":
          case "no_inviter":
            // Donnée mal formée : à corriger, donc visible dans les erreurs.
            await logError({
              message:
                outcome.skipped === "bad_role"
                  ? "applyEmailInvitation: rôle d'invitation illisible, invitation non appliquée"
                  : "applyEmailInvitation: invitant absent de l'invitation, non appliquée",
              errorDescription: `invitation ${outcome.invitationId}`,
              userId: uid,
              firestoreDocId: outcome.invitationId,
            });
            return;
        }
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

/**
 * Vrai si l'écriture est la connexion d'un compte révoqué : révoqué avant et
 * après, et `last_seen_at` a changé. C'est ce qu'écrit le client à chaque
 * connexion (`AuthRepository._upsertUser`), et les règles laissent le
 * titulaire révoqué l'écrire. Toute autre écriture (rétablissement, rôle,
 * nom préféré) ne déclenche rien. Pure, testée.
 */
export function isRevokedSignIn(
  before: Record<string, unknown> | undefined | null,
  after: Record<string, unknown> | undefined | null,
): boolean {
  if (!before || !after) return false;
  if (before.is_revoked !== true || after.is_revoked !== true) return false;
  const seenAfter = asDate(after.last_seen_at)?.getTime() ?? null;
  if (seenAfter === null) return false;
  const seenBefore = asDate(before.last_seen_at)?.getTime() ?? null;
  return seenBefore !== seenAfter;
}

/**
 * Reconnexion d'un compte révoqué invité de nouveau par e-mail.
 *
 * Avant tout appel à Auth, une requête `target_uid == uid` vérifie qu'une
 * invitation de retour active existe : sans elle, rien ne se passe.
 *
 * L'administrateur a invité l'adresse d'un compte révoqué : l'invitation porte
 * `target: "revoked"` et l'uid du compte (`target_uid`). Le compte reste
 * révoqué jusqu'à ce que son titulaire se reconnecte. À cette connexion, le
 * client écrit `last_seen_at` (`isRevokedSignIn`), et ce déclencheur, dans une
 * transaction :
 *  - relit l'invitation active de même clé d'adresse qui vise **ce** compte
 *    (`pickActiveInvitation`, `{ kind: "revoked", uid }`) ;
 *  - exige l'adresse **Auth** vérifiée (`getUser`, `emailVerified`) ;
 *  - exige que le compte soit toujours révoqué et ne soit pas le fondateur ;
 *  - exige que l'administrateur du dernier envoi soit toujours administrateur
 *    et non révoqué (même garde que pour un compte neuf) ;
 *  - rétablit le compte (`is_revoked: false`) avec le rôle de l'invitation ;
 *  - ajoute son uid à `invited_ids` du groupe (`groupInviteFor`) : il accepte
 *    dans Groupes familiaux. Jamais d'entrée directe dans `member_ids`. Groupe
 *    supprimé : rôle seul, `group_missing: true`. Invitant sorti du groupe
 *    (ni propriétaire ni membre, relu dans la transaction) : rôle seul,
 *    `group_invite: "missing"` ;
 *  - passe l'invitation à `accepted`, avec `group_invite`.
 *
 * Le statut `accepted`, relu dans la transaction, empêche une seconde
 * application. L'écriture de `is_revoked` réveille `syncUserClaims` (claims,
 * profil public) et `syncPlanningReachOnRole` (portée des plannings) ; l'ajout
 * à `invited_ids` ne change aucune portée. Le client suit `users/{uid}` :
 * l'écran de révocation se ferme seul, après le renouvellement du jeton
 * (`AuthRepository.watchAppUser`).
 */
export const applyRevokedInvitation = onDocumentUpdated(
  { document: "users/{uid}", region: REGION },
  async (event) => {
    const uid = event.params.uid;
    const before = event.data?.before?.data() as Record<string, unknown> | undefined;
    const after = event.data?.after?.data() as Record<string, unknown> | undefined;
    if (!isRevokedSignIn(before, after)) return;

    // Filtre d'entrée : la plupart des connexions d'un compte révoqué n'ont
    // aucune invitation de retour, et n'ont pas à coûter un appel Auth.
    // Requête d'égalité sur un seul champ (index automatique, aucun index
    // composite) ; le statut se lit ici, avec l'expiration.
    try {
      const forUid = await getFirestore()
        .collection(COLL_INVITATIONS)
        .where("target_uid", "==", uid)
        .get();
      const now = new Date();
      if (!forUid.docs.some((d) => isOpenReturnInvitationFor(d.data(), uid, now))) return;
    } catch (err) {
      await logError({
        message: `applyRevokedInvitation: lecture des invitations de retour impossible pour ${uid}`,
        errorDescription: err instanceof Error ? err.message : String(err),
        userId: uid,
      });
      return;
    }

    let authEmail: string | undefined;
    let verified = false;
    try {
      const user = await getAuth().getUser(uid);
      authEmail = user.email;
      verified = user.emailVerified === true;
    } catch (err) {
      await logError({
        message: `applyRevokedInvitation: compte Auth introuvable pour ${uid}`,
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
          { kind: "revoked", uid },
        );
        if (chosen === null) return null;
        if (!verified) {
          return { skipped: "unverified" as const, invitationId: chosen.id, inviterUid: null };
        }

        const role = chosen.data.role;
        if (!isInvitableRole(role)) {
          return { skipped: "bad_role" as const, invitationId: chosen.id, inviterUid: null };
        }

        const inviterUid = inviterUidOf(chosen.data);
        if (inviterUid === null) {
          return { skipped: "no_inviter" as const, invitationId: chosen.id, inviterUid: null };
        }
        const inviterSnap = await tx.get(db.collection(COLL_USERS).doc(inviterUid));
        if (!inviterStillAdmin(inviterSnap.data())) {
          return { skipped: "inviter_not_admin" as const, invitationId: chosen.id, inviterUid };
        }

        const userSnap = await tx.get(userRef);
        const userData = userSnap.data();
        if (!userSnap.exists || userData?.is_revoked !== true) return null;
        const docEmail = typeof userData.email === "string" ? userData.email : null;
        if (isFounderEmail(docEmail)) return null;

        const groupId = typeof chosen.data.group_id === "string" ? chosen.data.group_id : "";
        const groupRef = groupId ? db.collection(COLL_GROUPS).doc(groupId) : null;
        const groupSnap = groupRef ? await tx.get(groupRef) : null;
        // Même garde qu'à la première connexion : un groupe recréé par un
        // autre compte, ou une invitation sans `group_owner_id`, compte comme
        // un groupe absent.
        const groupExists =
          groupSnap?.exists === true && invitationGroupOf(groupSnap.data(), chosen.data) !== null;
        // L'invitant est relu dans le groupe : sorti entre l'envoi et le
        // retour, il ne peut plus y inviter, et le serveur ne le fait pas à
        // sa place (`missing`). Le rôle et le rétablissement restent.
        const groupInvite = groupInviteFor(groupExists ? groupSnap?.data() : null, uid, inviterUid);

        tx.update(userRef, { is_revoked: false, role });
        if (groupInvite === "invited" && groupRef) {
          tx.update(groupRef, { invited_ids: FieldValue.arrayUnion(uid) });
        }
        tx.update(chosen.ref, {
          status: "accepted",
          accepted_uid: uid,
          accepted_at: Timestamp.fromDate(now),
          group_missing: !groupExists,
          group_invite: groupInvite,
        });
        return { applied: true as const, invitationId: chosen.id, role, groupId, groupInvite };
      });

      if (outcome === null) return;
      if ("skipped" in outcome) {
        switch (outcome.skipped) {
          case "unverified":
            await logInfo({
              message: "applyRevokedInvitation: adresse non vérifiée, accès non rétabli",
              userId: uid,
              firestoreDocId: outcome.invitationId,
            });
            return;
          case "inviter_not_admin":
            await logInfo({
              message:
                `applyRevokedInvitation: l'invitant ${outcome.inviterUid} n'est plus ` +
                "administrateur (ou est révoqué), accès non rétabli",
              userId: uid,
              firestoreDocId: outcome.invitationId,
            });
            return;
          case "bad_role":
          case "no_inviter":
            await logError({
              message:
                outcome.skipped === "bad_role"
                  ? "applyRevokedInvitation: rôle d'invitation illisible, accès non rétabli"
                  : "applyRevokedInvitation: invitant absent de l'invitation, accès non rétabli",
              errorDescription: `invitation ${outcome.invitationId}`,
              userId: uid,
              firestoreDocId: outcome.invitationId,
            });
            return;
        }
      }
      await logInfo({
        message:
          `applyRevokedInvitation: accès rétabli (rôle ${outcome.role}, groupe ` +
          `${outcome.groupId || "aucun"} : ${outcome.groupInvite})`,
        userId: uid,
        firestoreDocId: outcome.invitationId,
      });
    } catch (err) {
      await logError({
        message: `applyRevokedInvitation: invitation de retour non appliquée pour ${uid}`,
        errorDescription: err instanceof Error ? err.message : String(err),
        userId: uid,
      });
    }
  },
);

/**
 * Annule les invitations de retour devenues sans objet : le compte `uid`
 * vient d'être rétabli (`isAccessRestored`). Appelée par `syncUserClaims`,
 * qui voit passer toute écriture de `is_revoked` — pas de fonction déployée
 * de plus.
 *
 * Laissée active, une invitation de retour rétablirait le compte après une
 * nouvelle révocation, sans que l'administrateur de cette révocation le
 * sache. Chaque invitation est relue dans sa propre transaction, avec
 * `users/{uid}` : rien n'est annulé si le compte est de nouveau révoqué
 * (`is_revoked === true`), et seule une invitation encore active qui vise ce
 * compte, envoyée au plus tard à `restoredAt` (`last_sent_at`), passe à
 * `cancelled` (`cancelled_by: "system"`, motif lisible dans `last_error`). Celle
 * qu'`applyRevokedInvitation` vient d'appliquer est déjà `accepted`.
 *
 * Une erreur est journalisée invitation par invitation et n'interrompt pas
 * les autres.
 */
export async function cancelStaleReturnInvitations(uid: string, restoredAt: Date): Promise<void> {
  const db = getFirestore();
  const forUid = await db.collection(COLL_INVITATIONS).where("target_uid", "==", uid).get();
  const { stale, reason } = staleReturnInvitations(
    forUid.docs.map((d) => ({ ref: d.ref, id: d.id, data: d.data() })),
    uid,
    restoredAt,
  );
  for (const inv of stale) {
    try {
      const cancelled = await db.runTransaction(async (tx) => {
        const snap = await tx.get(inv.ref);
        // Révoqué de nouveau depuis le rétablissement : l'invitation de
        // retour a de nouveau un objet, elle reste active.
        const userSnap = await tx.get(db.collection(COLL_USERS).doc(uid));
        if (userSnap.data()?.is_revoked === true) return false;
        if (!isStaleReturnInvitation(snap.data(), uid, restoredAt, new Date())) return false;
        tx.update(inv.ref, {
          status: "cancelled",
          cancelled_by: "system",
          cancelled_at: Timestamp.now(),
          last_error: reason,
        });
        return true;
      });
      if (cancelled) {
        await logInfo({
          message: `cancelStaleReturnInvitations: invitation de retour annulée (${reason})`,
          userId: uid,
          firestoreDocId: inv.id,
        });
      }
    } catch (err) {
      await logError({
        message: `cancelStaleReturnInvitations: invitation de retour non annulée pour ${uid}`,
        errorDescription: err instanceof Error ? err.message : String(err),
        userId: uid,
        firestoreDocId: inv.id,
      });
    }
  }
}
