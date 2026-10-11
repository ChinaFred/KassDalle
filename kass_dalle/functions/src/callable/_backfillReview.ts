/**
 * Liste « à revoir » d'un backfill : les éléments qu'un passage n'a pas pu
 * traiter, chacun avec son nom et la raison.
 *
 * Un compte rendu chiffré dit combien d'éléments restent en erreur ; il ne dit
 * pas lesquels. Le backfill des allergènes a rendu « en erreur=17, encore
 * incomplètes=39 » sans un seul nom, et l'admin n'avait aucun moyen de
 * retrouver ces 56 éléments. Chaque backfill d'Admin › Backfills renvoie donc
 * `aRevoir: { items, total }` dans sa réponse, construit par ce collecteur.
 *
 * La liste vit dans la réponse du passage. Elle n'est recopiée que dans le
 * `last_report` du point de reprise, quand le backfill en écrit un. Elle ne
 * part jamais dans les journaux : elle porte des noms de comptes et des titres
 * de recettes privées. Les journaux reçoivent `withoutReviewList`.
 *
 * Plafond : `BACKFILL_REVIEW_LIMIT` entrées, dans l'ordre de traitement.
 * `total` continue de compter au-delà, et le client affiche « 100 affichés sur
 * 240 ».
 */

/** Nombre d'entrées gardées dans la liste ; `total` compte au-delà. */
export const BACKFILL_REVIEW_LIMIT = 100;

/** Longueur maximale d'un nom ou d'une raison, pour borner la réponse. */
const TEXT_MAX_LENGTH = 200;

/** Longueur maximale d'un message d'erreur cité dans une raison. */
const ERROR_MESSAGE_MAX_LENGTH = 120;

/**
 * Nature de l'élément : le client ouvre un ingrédient ou une unité dans son
 * référentiel, une recette dans sa fiche. Une nature qu'il ne connaît pas
 * s'affiche sans lien.
 */
export type BackfillReviewKind = "ingredient" | "unit" | "recipe" | "account";

export interface BackfillReviewItem {
  kind: BackfillReviewKind;
  /** Identifiant du document (ingrédient, unité, recette, compte). */
  id: string;
  /** Nom lisible : nom canonique, titre de la recette, nom du compte. */
  label: string;
  /** Pourquoi l'élément est à revoir, en français simple. */
  reason: string;
}

/** Forme envoyée au client sous `aRevoir`. */
export interface BackfillReviewList {
  items: BackfillReviewItem[];
  /** Éléments à revoir, liste tronquée comprise. */
  total: number;
}

function clip(text: string, max: number): string {
  const clean = text.replace(/\s+/g, " ").trim();
  return clean.length > max ? `${clean.slice(0, max - 1)}…` : clean;
}

/** Collecteur plafonné, rempli dans l'ordre de traitement. */
export class BackfillReview {
  private readonly items: BackfillReviewItem[] = [];
  private count = 0;

  constructor(private readonly limit: number = BACKFILL_REVIEW_LIMIT) {}

  /** Ajoute un élément ; au-delà du plafond, il n'est que compté. */
  add(item: BackfillReviewItem): void {
    this.count += 1;
    if (this.items.length >= this.limit) return;
    const id = item.id.trim();
    this.items.push({
      kind: item.kind,
      id,
      label: clip(item.label, TEXT_MAX_LENGTH) || id,
      reason: clip(item.reason, TEXT_MAX_LENGTH),
    });
  }

  get total(): number {
    return this.count;
  }

  /** Objet simple, prêt pour la réponse et pour Firestore. */
  toJSON(): BackfillReviewList {
    return { items: this.items.map((i) => ({ ...i })), total: this.count };
  }
}

/** Message d'erreur court, pour une raison « Lot en échec : … ». */
/**
 * Le compte rendu tel qu'il part dans un journal : la liste `aRevoir` est
 * remplacée par son seul total.
 */
export function withoutReviewList<T extends { aRevoir?: BackfillReviewList }>(
  report: T,
): Omit<T, "aRevoir"> & { aRevoirTotal: number } {
  const { aRevoir, ...rest } = report;
  return { ...rest, aRevoirTotal: aRevoir?.total ?? 0 };
}

export function shortErrorMessage(err: unknown): string {
  const raw = err instanceof Error ? err.message : String(err);
  const message = clip(raw, ERROR_MESSAGE_MAX_LENGTH);
  return message.length > 0 ? message : "erreur inconnue";
}

/** Titre d'une recette pour la liste, à défaut son identifiant. */
export function recipeReviewLabel(id: string, data: Record<string, unknown>): string {
  const titre = typeof data.titre === "string" ? data.titre.trim() : "";
  return titre || id;
}

/**
 * « beurre, farine » ; au-delà de `max` noms, « a, b, c, d, e et 3 autres ».
 */
export function namesList(names: readonly string[], max = 5): string {
  if (names.length <= max) return names.join(", ");
  const rest = names.length - max;
  return `${names.slice(0, max).join(", ")} et ${rest} autre${rest > 1 ? "s" : ""}`;
}
