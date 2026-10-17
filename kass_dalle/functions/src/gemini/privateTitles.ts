/**
 * Titres des recettes validées des livres privés des membres de mes groupes,
 * pour la feuille « Suggérer un plat ». Logique pure : le callable
 * `listFamilyPrivateTitlesFn` lit Firestore, ce fichier décide ce qui sort.
 *
 * Seuls l'identifiant, le titre, le nom du livre et l'auteur repartent. Aucun
 * autre champ de la recette ne traverse la frontière : c'est le contrat de
 * confidentialité de la suggestion (le destinataire sans accès ne voit que
 * le titre).
 */

/** Comptes de la portée interrogés au plus (limite `in` de Firestore). */
export const PRIVATE_TITLES_MAX_OWNERS = 30;

/** Titres rendus au plus. */
export const PRIVATE_TITLES_MAX_RESULTS = 500;

export interface PrivateTitle {
  id: string;
  titre: string;
  bookTitre: string | null;
  createdBy: string;
}

/** Les comptes à interroger : la portée du demandeur, sans lui, bornée. */
export function ownersToQuery(reachUids: unknown, myUid: string): string[] {
  if (!Array.isArray(reachUids)) return [];
  const seen = new Set<string>();
  for (const u of reachUids) {
    if (typeof u === "string" && u.length > 0 && u !== myUid) seen.add(u);
  }
  return [...seen].slice(0, PRIVATE_TITLES_MAX_OWNERS);
}

/**
 * Projette un document de recette en titre. `null` si la recette n'est pas une
 * recette validée et privée, ou si son titre est vide. Une page d'un autre
 * type (technique, introduction…) est écartée comme dans le sélecteur.
 */
export function privateTitleOf(id: string, data: Record<string, unknown>): PrivateTitle | null {
  if (data.review_status !== "validated") return null;
  if (data.is_private !== true) return null;
  const pageType = data.page_type;
  if (pageType !== undefined && pageType !== null && pageType !== "recipe") return null;
  const titre = typeof data.titre === "string" ? data.titre.trim() : "";
  const createdBy = typeof data.created_by === "string" ? data.created_by : "";
  if (titre.length === 0 || createdBy.length === 0) return null;
  const book = typeof data.book_titre === "string" ? data.book_titre.trim() : "";
  return { id, titre, bookTitre: book.length > 0 ? book : null, createdBy };
}

/** Les titres retenus, triés par titre, bornés. */
export function collectPrivateTitles(
  docs: Array<{ id: string; data: Record<string, unknown> }>,
): PrivateTitle[] {
  const out: PrivateTitle[] = [];
  for (const d of docs) {
    const t = privateTitleOf(d.id, d.data);
    if (t) out.push(t);
  }
  out.sort((a, b) => a.titre.toLowerCase().localeCompare(b.titre.toLowerCase(), "fr"));
  return out.slice(0, PRIVATE_TITLES_MAX_RESULTS);
}
