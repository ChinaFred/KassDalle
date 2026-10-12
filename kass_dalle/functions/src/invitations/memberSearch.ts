/**
 * Recherche d'un membre à inviter dans un groupe, par son adresse exacte : les
 * règles, sans Firestore.
 *
 * `users/{uid}` ne se lit plus que par son titulaire et par un administrateur
 * (v0.23.14) : le propriétaire d'un groupe ne peut donc pas chercher une
 * adresse lui-même. `findMemberByEmailFn` (`callable/memberSearchCallable.ts`)
 * le fait pour lui, et ne rend qu'un compte dont l'adresse correspond **en
 * entier** à la saisie : aucune liste d'adresses ne sort du serveur, et la
 * réponse ne contient jamais l'adresse.
 *
 * Correspondance stricte, après espaces retirés et minuscules
 * (`cleanEmail`) : pas de clé normalisée Gmail (`normalizeEmailKey`). La clé
 * normalisée sert à l'invitation par e-mail, où une adresse saisie autrement
 * créerait un doublon de compte. Ici, elle ferait trouver un compte sous une
 * autre écriture de l'adresse (points, suffixe `+…`, `googlemail.com`) que
 * celle saisie : la comparaison stricte ne rend que le compte dont l'appelant
 * connaît déjà l'adresse exacte.
 *
 * Logique serveur seule. Le client ne fait qu'un contrôle de forme
 * (`looksLikeEmail`) avant d'appeler.
 */

import { cleanEmail } from "./rules";
import { publicProfileFrom } from "../triggers/userPublicProfile";

/** Recherches par adresse autorisées par compte et par jour UTC. */
export const MEMBER_EMAIL_SEARCH_DAILY_LIMIT = 10;

/**
 * Réponses « aucun compte » du jour à partir desquelles un avertissement part
 * dans les journaux (une fois par jour et par compte) : une série d'adresses
 * essayées sans succès ressemble à une devinette, que l'administrateur doit
 * pouvoir voir dans Admin › Logs.
 */
export const MEMBER_EMAIL_SEARCH_MISS_ALERT = 5;

/**
 * Durée de conservation d'un compteur du jour, comptée depuis sa dernière
 * écriture. La politique TTL de `firestore.indexes.json` supprime le document
 * à son `expires_at` ; le jour suivant écrit ailleurs, le compteur n'a plus
 * d'usage passé ce délai, sinon la lecture d'un incident récent.
 */
export const MEMBER_EMAIL_SEARCH_RETENTION_DAYS = 30;

/** L'échéance TTL d'un compteur écrit à `at`. */
export function searchCounterExpiry(at: Date): Date {
  return new Date(at.getTime() + MEMBER_EMAIL_SEARCH_RETENTION_DAYS * 24 * 60 * 60 * 1000);
}

/**
 * Vrai quand le nombre de réponses « aucun compte » du jour, après celle-ci,
 * atteint le seuil d'alerte. Égalité stricte : l'avertissement part une fois
 * par jour, pas à chaque essai suivant.
 */
export function shouldWarnMisses(missesAfter: number): boolean {
  return missesAfter === MEMBER_EMAIL_SEARCH_MISS_ALERT;
}

/**
 * L'identifiant de groupe tel qu'il peut figurer dans un journal avant que
 * le groupe ait été confirmé : 32 caractères au plus. Une saisie arbitraire
 * de l'appelant ne remplit pas les journaux.
 */
export function unverifiedGroupRef(groupId: string): string {
  return groupId.slice(0, 32);
}

/** Message du refus au-delà du plafond, affiché tel quel par le client. */
export const MEMBER_EMAIL_SEARCH_LIMIT_MESSAGE =
  "Trop de recherches aujourd'hui. Réessayez demain.";

/** Ce que la callable rend. Jamais l'adresse, jamais le rôle. */
export type MemberEmailSearchResult =
  | { found: false }
  | { found: true; uid: string; displayName: string; preferredName: string | null };

/** Un refus de la garde de groupe. */
export interface SearchDenial {
  code: "not-found" | "permission-denied";
  message: string;
}

/**
 * Seul le propriétaire du groupe cherche un membre à inviter : c'est lui seul
 * qui invite (`isManagement` dans `firestore.rules`, bouton réservé au
 * propriétaire dans `groups_screen.dart`). Un administrateur qui n'est pas
 * propriétaire n'en a pas besoin : il lit `users` directement.
 *
 * `group` vaut `null` quand le document n'existe pas. Retourne `null` quand
 * l'appelant peut chercher.
 */
export function searcherDenial(
  group: Record<string, unknown> | null | undefined,
  uid: string,
): SearchDenial | null {
  if (!group) return { code: "not-found", message: "Ce groupe n'existe plus." };
  if (typeof group.owner_id !== "string" || group.owner_id !== uid) {
    return {
      code: "permission-denied",
      message: "Seul le propriétaire du groupe peut y inviter quelqu'un.",
    };
  }
  return null;
}

/** Un identifiant de groupe utilisable comme identifiant de document, ou `null`. */
export function readGroupId(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const id = raw.trim();
  if (id.length === 0 || id.length > 128 || id.includes("/")) return null;
  return id;
}

/** Un compte lu dans `users` : son identifiant et ses champs. */
export interface AccountRow {
  id: string;
  data: Record<string, unknown> | undefined;
}

/**
 * Le compte dont l'adresse vaut `email`, réduit à ce que `user_profiles` en
 * montre déjà à tout compte approuvé (identifiant, nom Google, nom préféré).
 *
 * `email` est déjà nettoyée (`cleanEmail`). L'adresse stockée l'est ici de la
 * même façon : `users.email` est l'adresse du jeton Google, dont la casse
 * n'est pas garantie sur un compte ancien.
 *
 * Écartés : un compte révoqué, un compte en attente (`pending` ou rôle
 * absent), qui n'a pas de profil public. Un compte écarté reçoit la même
 * réponse qu'une adresse inconnue : la réponse ne dit pas qu'un compte existe
 * sans pouvoir être invité.
 */
export function findAccountByEmail(email: string, accounts: AccountRow[]): MemberEmailSearchResult {
  for (const account of accounts) {
    const data = account.data;
    if (!data) continue;
    if (cleanEmail(data.email) !== email) continue;
    if (data.is_revoked === true) continue;
    const profile = publicProfileFrom(data, account.id);
    if (profile === null) continue;
    return {
      found: true,
      uid: account.id,
      displayName: profile.display_name,
      preferredName: profile.preferred_name,
    };
  }
  return { found: false };
}
