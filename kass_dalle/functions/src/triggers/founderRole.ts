/**
 * Maintient le rôle du compte fondateur, sans jamais faire confiance au client.
 *
 * Le rôle d'un compte neuf était décidé par l'application : elle comptait la
 * collection `users` et s'attribuait `admin` si elle la trouvait vide. Comme
 * les règles Firestore ne contraignaient aucun champ à la création, n'importe
 * qui pouvait créer son propre document avec `role: "admin"` — et
 * `syncUserClaims`, qui fait confiance au document, lui frappait le claim
 * correspondant. Le contrôle d'accès entier tenait sur la bonne foi du client.
 *
 * Désormais : le client crée toujours un compte `pending`, les règles le
 * vérifient, et l'administration se transmet par nomination. Reste à amorcer
 * le tout premier administrateur — c'est ce que fait ce déclencheur.
 *
 * Trois précautions :
 *
 *  1. L'adresse qui décide est celle du **compte Auth**, lue ici par
 *     `getUser()`, vérifiée et rattachée à une connexion Google
 *     (`isFounderAccount`). Celle du document est écrite par le client ; les règles la
 *     verrouillent désormais sur celle du jeton, mais un contrôle d'autorité
 *     ne se fonde pas sur une donnée que le client a pu poser.
 *  2. Le déclencheur **restaure** aussi bien qu'il amorce : si le rôle du
 *     fondateur est rabaissé ou son compte révoqué, il revient. Un
 *     administrateur adoubé ne peut donc pas mettre dehors celui qui l'a
 *     nommé — les règles le refusent déjà, ce filet couvre ce qui passerait
 *     par l'Admin SDK ou par la console.
 *  3. Aucune boucle : la réécriture rappelle le déclencheur, qui trouve alors
 *     le rôle correct et ne réécrit rien.
 */

import { onDocumentWritten } from "firebase-functions/v2/firestore";
import { getAuth } from "firebase-admin/auth";

import { REGION } from "../config";
import { logError, logInfo } from "../logging";

/**
 * Le compte propriétaire de l'application.
 *
 * En dur, et c'est voulu : cette adresse est la racine de confiance de tout le
 * contrôle d'accès. La mettre en base la rendrait modifiable par qui sait
 * écrire en base, c'est-à-dire par un administrateur — l'inverse de ce qu'elle
 * garantit. En faire un secret n'apporterait rien : ce n'est pas une donnée
 * confidentielle, c'est une donnée qui ne doit pas bouger sans déploiement.
 */
export const FOUNDER_EMAIL = "china.fred.75@gmail.com";

/** Vrai si l'adresse désigne le compte fondateur, casse et espaces ignorés. */
export function isFounderEmail(email: string | null | undefined): boolean {
  return typeof email === "string" && email.trim().toLowerCase() === FOUNDER_EMAIL;
}

/** Ce que `founderAccount` lit d'un compte Auth (`UserRecord` de l'Admin SDK). */
export interface FounderCandidate {
  email?: string | null;
  emailVerified?: boolean;
  providerData?: ReadonlyArray<{ providerId?: string }>;
}

/**
 * Vrai si le compte Auth est celui du fondateur : son adresse, **vérifiée**,
 * et une connexion Google.
 *
 * L'adresse seule ne suffisait pas (audit sécurité, « à confirmer ») : un
 * fournisseur qui laisse créer un compte avec une adresse non vérifiée
 * (e-mail et mot de passe, par exemple) aurait suffi à se faire reconnaître
 * fondateur. Même contrôle que `isFounder()` dans `firestore.rules`
 * (`email_verified` et `sign_in_provider == 'google.com'`). Pure, testée.
 */
export function isFounderAccount(user: FounderCandidate | null | undefined): boolean {
  if (!user) return false;
  return (
    isFounderEmail(user.email) &&
    user.emailVerified === true &&
    (user.providerData ?? []).some((p) => p.providerId === "google.com")
  );
}

/**
 * Ce qu'il faut écrire sur un document utilisateur pour rétablir le fondateur,
 * ou `null` s'il n'y a rien à faire.
 *
 * Fonction pure, testée : c'est elle qui porte la décision, le déclencheur ne
 * fait que l'appliquer.
 */
export function founderRepair(
  data: Record<string, unknown> | undefined,
): { role: string; is_revoked: boolean } | null {
  if (!data) return null;
  const roleOk = data.role === "admin";
  const activeOk = data.is_revoked !== true;
  if (roleOk && activeOk) return null;
  return { role: "admin", is_revoked: false };
}

export const enforceFounderRole = onDocumentWritten(
  { document: "users/{uid}", region: REGION },
  async (event) => {
    const uid = event.params.uid;
    const after = event.data?.after;
    if (!after?.exists) return;

    const data = after.data() as Record<string, unknown> | undefined;

    // Rien à réparer : on sort avant toute lecture, ce qui est le cas de
    // presque toutes les écritures (chaque connexion touche `last_seen_at`).
    const repair = founderRepair(data);
    if (!repair) return;

    // Filtre de premier niveau sur l'adresse du document — non pas pour
    // décider, mais pour éviter un appel Auth sur les comptes qui ne
    // prétendent pas être le fondateur. La décision, elle, vient de `getUser`.
    const claimedEmail = typeof data?.email === "string" ? data.email : null;
    if (!isFounderEmail(claimedEmail)) return;

    let authUser: FounderCandidate;
    try {
      authUser = await getAuth().getUser(uid);
    } catch (err) {
      // Un document utilisateur sans compte Auth correspondant : impossible de
      // vérifier l'identité, donc on ne promeut rien. Doit rester visible.
      await logError({
        message: `enforceFounderRole: compte Auth introuvable pour ${uid}`,
        errorDescription: err instanceof Error ? err.message : String(err),
        userId: uid,
      });
      return;
    }

    if (!isFounderAccount(authUser)) {
      await logInfo({
        message:
          "enforceFounderRole: document se réclamant du fondateur sans compte Auth " +
          "Google à l'adresse vérifiée — aucune promotion",
        userId: uid,
        extra: {
          documentEmail: claimedEmail,
          authEmailMatches: isFounderEmail(authUser.email),
          emailVerified: authUser.emailVerified === true,
          providers: (authUser.providerData ?? []).map((p) => p.providerId ?? null),
        },
      });
      return;
    }

    try {
      await after.ref.update(repair);
      await logInfo({
        message: `enforceFounderRole: rôle du fondateur rétabli (${uid})`,
        userId: uid,
        extra: { previousRole: data?.role ?? null, previousRevoked: data?.is_revoked ?? null },
      });
    } catch (err) {
      await logError({
        message: `enforceFounderRole: écriture impossible pour ${uid}`,
        errorDescription: err instanceof Error ? err.message : String(err),
        userId: uid,
      });
    }
  },
);
