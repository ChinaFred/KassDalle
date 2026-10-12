/**
 * Profil public d'un compte : la part de `users/{uid}` que les autres membres
 * voient.
 *
 * `users/{uid}` porte l'adresse, le rôle et la révocation. Il ne se lit plus
 * que par son titulaire et par un administrateur (v0.23.14). Les écrans qui
 * affichent le nom d'un autre membre — file de travail, détail d'une recette,
 * bibliothèque, groupes — lisent `user_profiles/{uid}`, tenu ici.
 *
 * Champs recopiés, et eux seuls : `display_name`, `preferred_name`,
 * `free_recipe_cover_url`. Le client calcule le nom affiché à partir des deux
 * premiers, comme il le fait pour son propre compte.
 *
 * Un compte en attente (`pending`, ou rôle absent) n'a pas de profil : il
 * n'a encore rien créé que la famille verrait, et rien ne doit l'exposer aux
 * autres membres. Un compte révoqué garde le sien : ses recettes restent dans
 * la bibliothèque, et elles gardent un nom d'auteur.
 *
 * Aucun SDK lourd : `firebase-admin/firestore` est déjà chargé par toutes les
 * fonctions du bundle.
 */

import { FieldValue, getFirestore } from "firebase-admin/firestore";

import { COLL_USER_PROFILES } from "../config";

/** Rôles qui donnent un profil public. `pending` n'en fait pas partie. */
const PROFILE_ROLES = ["reader", "editor", "admin"];

/**
 * Longueur maximale, en caractères, d'un nom recopié dans le profil public.
 * Les règles Firestore refusent au-delà sur `users/{uid}` ; la troncature ici
 * couvre un document écrit par le serveur ou antérieur à la règle. Même
 * valeur côté client : `UserProfile.maxNameLength`.
 */
export const MAX_NAME_LENGTH = 60;

/**
 * [value] coupé à {@link MAX_NAME_LENGTH} unités UTF-16, sans couper un
 * caractère en deux. Les règles Firestore (`string.size()`) comptent en unités
 * UTF-16 : un emoji y vaut 2.
 */
export function truncateName(value: string): string {
  if (value.length <= MAX_NAME_LENGTH) return value;
  let end = MAX_NAME_LENGTH;
  const last = value.charCodeAt(end - 1);
  // Une moitié haute de paire de substitution ne reste pas seule.
  if (last >= 0xd800 && last <= 0xdbff) end -= 1;
  return value.slice(0, end);
}

/** Longueur maximale de l'adresse de couverture — même borne que les règles. */
export const MAX_COVER_URL_LENGTH = 500;

/**
 * Forme admise d'une couverture « Recette libre » : l'adresse de
 * téléchargement exacte que produit la modération (`targetPathFor`,
 * `moderation/promote.ts`) — `users/{uid}/free_recipe_cover_{horodatage}.{ext}`
 * dans le bucket du projet. Le chemin est fermé caractère par caractère : ni
 * `..`, ni `%2E`, ni `%25`, qui laisseraient viser un fichier hors de
 * `users/{uid}/`. Même expression que `coverUrlOk()` dans `firestore.rules`.
 */
function coverUrlPattern(uid: string): RegExp {
  return new RegExp(
    "^https://firebasestorage\\.googleapis\\.com/v0/b/kassdale-6d948\\.(firebasestorage\\.app|appspot\\.com)" +
      `/o/users%2F${uid}%2Ffree_recipe_cover_[0-9]+\\.(jpg|jpeg|png|webp)(\\?[^/#%]*)?$`,
  );
}

/** Un uid Firebase : alphanumérique, sans `.`, `%` ni `/`. */
const UID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;

/**
 * La couverture recopiée dans le profil public de [uid], ou `null`.
 *
 * Défense en profondeur : les règles refusent déjà une autre adresse sur
 * `users/{uid}`. Ce filtre couvre une écriture du serveur ou un document
 * antérieur à la règle — une adresse externe n'a pas été modérée, et le profil
 * public est lu par toute la famille.
 */
export function publicCoverUrl(value: unknown, uid: string): string | null {
  const url = optionalString(value);
  if (url === null || url.length > MAX_COVER_URL_LENGTH) return null;
  if (!UID_PATTERN.test(uid)) return null;
  return coverUrlPattern(uid).test(url) ? url : null;
}

/** Les champs publics d'un compte. */
export interface PublicProfile {
  display_name: string;
  preferred_name: string | null;
  free_recipe_cover_url: string | null;
}

function optionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

function optionalName(value: unknown): string | null {
  const name = optionalString(value);
  return name === null ? null : truncateName(name).trim();
}

/**
 * Le profil public dérivé d'un document `users/{uid}`, ou `null` si le compte
 * ne doit pas en avoir (document absent, rôle en attente ou inconnu).
 * Pure et exportée pour être testée.
 */
export function publicProfileFrom(
  data: Record<string, unknown> | undefined | null,
  uid: string,
): PublicProfile | null {
  if (!data) return null;
  const role = typeof data.role === "string" ? data.role.trim() : "";
  if (!PROFILE_ROLES.includes(role)) return null;
  return {
    display_name: optionalName(data.display_name) ?? "",
    preferred_name: optionalName(data.preferred_name),
    free_recipe_cover_url: publicCoverUrl(data.free_recipe_cover_url, uid),
  };
}

/**
 * Le profil stocké correspond-il déjà au profil attendu ? Seuls les champs
 * publics comptent : `updated_at` change à chaque écriture.
 */
export function sameProfile(
  stored: Record<string, unknown> | undefined | null,
  expected: PublicProfile,
): boolean {
  if (!stored) return false;
  return (
    stored.display_name === expected.display_name &&
    (stored.preferred_name ?? null) === expected.preferred_name &&
    (stored.free_recipe_cover_url ?? null) === expected.free_recipe_cover_url
  );
}

/** Ce que `syncPublicProfile` a fait. */
export type ProfileSyncOutcome = "created" | "updated" | "deleted" | "unchanged";

/**
 * Aligne `user_profiles/{uid}` sur le document `users/{uid}` donné.
 *
 * Lit le profil stocké avant d'écrire, et n'écrit que s'il diffère : la
 * comparaison se fait contre ce qui est en base, pas contre l'état précédent
 * de `users/{uid}`. Un profil manquant se recrée donc à la première écriture
 * sur le compte (connexion, nom préféré, couverture).
 *
 * Les erreurs remontent à l'appelant, qui les journalise.
 */
export async function syncPublicProfile(
  uid: string,
  userData: Record<string, unknown> | undefined | null,
): Promise<ProfileSyncOutcome> {
  const ref = getFirestore().collection(COLL_USER_PROFILES).doc(uid);
  const expected = publicProfileFrom(userData, uid);
  const stored = await ref.get();

  if (expected === null) {
    if (!stored.exists) return "unchanged";
    await ref.delete();
    return "deleted";
  }

  if (stored.exists && sameProfile(stored.data(), expected)) return "unchanged";
  await ref.set({ ...expected, updated_at: FieldValue.serverTimestamp() });
  return stored.exists ? "updated" : "created";
}
