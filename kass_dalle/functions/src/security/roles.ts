/**
 * Lecture du champ `role` d'un compte (document `users/{uid}` ou claim du jeton).
 *
 * Quatre valeurs, comparées à l'identique : `admin`, `editor`, `reader` et
 * `pending`. Toute autre valeur — `"superadmin"`, `"admin "`, `"Admin"`, un
 * nombre — se lit `null`, c'est-à-dire « aucun rôle », et ferme l'accès.
 *
 * Les lectures retiraient auparavant les espaces (`trim`) : un `"admin "` écrit
 * dans un document devenait administrateur pour les callables et pour le claim
 * du jeton, alors que `firestore.rules` le comparait tel quel et le refusait
 * (audit #151, ticket #163). Les deux sources lisent désormais la même chose.
 *
 * Même vocabulaire que l'énumération `UserRole` côté Dart
 * (`features/auth/domain/app_user.dart`), qui lit aussi le nom à l'identique
 * et rabat une valeur inconnue sur `pending`, et que la liste des rôles
 * qu'un administrateur peut écrire dans `firestore.rules` (`users`).
 */

/** Les rôles qu'un compte peut porter. */
export const KNOWN_ROLES = ["admin", "editor", "reader", "pending"] as const;

export type KnownRole = (typeof KNOWN_ROLES)[number];

/** Le rôle lu à l'identique, ou `null` s'il est absent ou inconnu. Pure, testée. */
export function readRole(value: unknown): KnownRole | null {
  return typeof value === "string" && (KNOWN_ROLES as readonly string[]).includes(value)
    ? (value as KnownRole)
    : null;
}
