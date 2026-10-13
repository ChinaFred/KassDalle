/**
 * Membres d'un groupe familial, état de son propriétaire et comparaison d'une
 * portée stockée : la logique commune à `group_reach` (`groupReach.ts`) et
 * `planning_reach` (`planningReach.ts`).
 *
 * Sans dépendance : les deux déclencheurs l'importent sans s'importer l'un
 * l'autre.
 */

/** Données brutes d'un groupe, telles que lues dans Firestore. */
export type GroupData = Record<string, unknown> | undefined | null;

/**
 * Un identifiant de compte utilisable comme identifiant de document : non
 * vide, sans « / », 128 caractères au plus. L'ancienne règle laissait un
 * propriétaire écrire n'importe quelle chaîne dans `member_ids` ; sans ce
 * tri, `doc("a/b")` lèverait à chaque passage, et `retry` rejouerait
 * l'événement en boucle.
 */
function nonEmptyString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  if (!trimmed || trimmed.includes("/") || trimmed.length > 128) return null;
  return trimmed;
}

/**
 * Les membres d'un groupe : `owner_id` et `member_ids` réunis, triés, sans
 * doublon. Un champ mal formé (absent, mauvais type, chaîne vide) est ignoré,
 * jamais une exception.
 */
export function membersOf(group: GroupData): string[] {
  if (!group) return [];
  const members = new Set<string>();
  const owner = nonEmptyString(group.owner_id);
  if (owner) members.add(owner);
  if (Array.isArray(group.member_ids)) {
    for (const value of group.member_ids) {
      const id = nonEmptyString(value);
      if (id) members.add(id);
    }
  }
  return [...members].sort();
}

/** Le propriétaire d'un groupe (`owner_id`), ou `null` s'il est inutilisable. */
export function ownerOf(group: GroupData): string | null {
  return group ? nonEmptyString(group.owner_id) : null;
}

/** Les rôles qui planifient, partagent leur planning et tiennent un groupe. */
const PLANNER_ROLES = ["editor", "admin"];

/**
 * Le compte `users/{uid}` planifie-t-il ? Éditeur ou administrateur, non
 * révoqué. Un document absent ou mal formé ne planifie pas.
 *
 * Décide aussi si un groupe est actif : un groupe dont le propriétaire ne
 * planifie plus (rétrogradé lecteur, en attente, révoqué) est masqué pour
 * tous ses membres — livres partagés par le groupe, planning du groupe,
 * écrans des groupes — sans que rien ne soit effacé. Tout revient s'il
 * redevient éditeur.
 */
export function isPlannerAccount(user: Record<string, unknown> | undefined | null): boolean {
  if (!user) return false;
  const role = typeof user.role === "string" ? user.role.trim() : "";
  return PLANNER_ROLES.includes(role) && user.is_revoked !== true;
}

/**
 * La portée stockée vaut-elle déjà [expected] ? Un document absent ou mal
 * formé ne vaut rien, pas même une liste vide : il faut l'écrire.
 */
export function sameReach(
  stored: Record<string, unknown> | undefined | null,
  expected: string[],
): boolean {
  return sameList(stored?.uids, expected);
}

/** [value] est-elle une liste égale, élément par élément, à [expected] ? */
export function sameList(value: unknown, expected: string[]): boolean {
  if (!Array.isArray(value)) return false;
  return value.length === expected.length && expected.every((id, i) => value[i] === id);
}
