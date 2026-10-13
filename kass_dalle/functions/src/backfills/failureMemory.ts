/**
 * Mémoire des échecs d'un backfill récurrent — logique pure.
 *
 * Un ingrédient que le modèle ne sait pas estimer, une recette qu'il ne sait
 * pas classer, étaient redemandés à chaque passage programmé, sans limite :
 * même question, même absence de réponse, un appel facturé de plus chaque
 * semaine. Chaque élément en échec porte donc, sur son propre document, un
 * compteur d'échecs propre au traitement qui l'a demandé, et la date du
 * dernier essai. À `BACKFILL_FAILURE_LIMIT` échecs, il n'est plus soumis au
 * modèle par un passage programmé ni par un passage manuel ordinaire ; seul un
 * passage lancé avec « Réessayer aussi les éléments en échec » le reprend.
 * Un succès remet le compteur à zéro.
 *
 * Les champs, par traitement (voir `TechnicalRequirements.md`, §3) :
 *
 * | Traitement | Document | Compteur | Date du dernier essai |
 * |---|---|---|---|
 * | poids des unités | `nutrition_units` | `ai_weight_failure_count` | `ai_weight_attempt_at` |
 * | valeurs pour 100 g | `nutrition_ingredients` | `enrichment_failure_count` | `last_enrichment_attempt_at` |
 * | allergènes | `nutrition_ingredients` | `allergens_failure_count` | `allergens_attempt_at` |
 * | rôle dans un repas | `recipes` | `meal_role_failure_count` | `meal_role_attempt_at` |
 *
 * Les déclencheurs d'écriture d'une recette ne lisent pas ce compteur : ils
 * gardent leur propre garde de vingt heures (`ENRICHMENT_RETRY_AFTER_MS`).
 */

/** Échecs au-delà desquels un élément n'est plus redemandé au modèle. */
export const BACKFILL_FAILURE_LIMIT = 3;

/** Raison « à revoir » d'un élément sauté parce qu'il a atteint la limite. */
export const EXCLUDED_AFTER_FAILURES_REASON = `Exclu après ${BACKFILL_FAILURE_LIMIT} échecs`;

/**
 * Compteur stocké, lu prudemment : un entier positif, sinon zéro. Une valeur
 * illisible ne doit pas exclure un élément qui n'a jamais échoué.
 */
export function readFailureCount(value: unknown): number {
  return typeof value === "number" && Number.isInteger(value) && value > 0 ? value : 0;
}

/**
 * L'élément est-il exclu de ce passage ? Oui s'il a atteint la limite, sauf
 * quand l'administrateur a demandé de réessayer les éléments en échec.
 */
export function isExcludedAfterFailures(storedCount: unknown, retryExcluded: boolean): boolean {
  return !retryExcluded && readFailureCount(storedCount) >= BACKFILL_FAILURE_LIMIT;
}

/** Ce qu'un nouvel échec laisse : le compteur à écrire, et s'il exclut l'élément. */
export interface FailureOutcome {
  count: number;
  /** Vrai quand ce nouvel échec atteint (ou dépasse) la limite. */
  excluded: boolean;
}

/** Compte un échec de plus sur un élément qui en portait [storedCount]. */
export function nextFailure(storedCount: unknown): FailureOutcome {
  const count = readFailureCount(storedCount) + 1;
  return { count, excluded: count >= BACKFILL_FAILURE_LIMIT };
}

/**
 * Raison « à revoir » d'un élément qui vient d'échouer : la cause, suivie de
 * l'exclusion quand cet échec l'a déclenchée.
 */
export function failureReason(cause: string, outcome: FailureOutcome): string {
  return outcome.excluded ? `${cause} — ${EXCLUDED_AFTER_FAILURES_REASON.toLowerCase()}` : cause;
}
