/**
 * Le message qu'un job d'import en échec (`processing_jobs.error_message`)
 * montre au membre, sur la tuile et dans « Détail de l'erreur ».
 *
 * Liste blanche : seuls les échecs dont l'exception porte une phrase écrite
 * pour le membre la recopient. Tous les autres reçoivent un texte fixe, parce
 * que leur message est un texte de bibliothèque, de SDK ou de fournisseur
 * (gRPC, Gemini, JSZip). Le texte brut reste dans `logError` et dans
 * `last_error` de la dead letter, lus par l'administrateur.
 *
 * L'import par lien (`url_*`) et le propriétaire refusé (`owner_not_editor`)
 * ont leurs propres messages, posés par `recipeProcessor` avec leur
 * `error_code`.
 *
 * Module pur, testé seul (`tests/jobErrorMessage.test.ts`).
 */

/** Échec générique (`pipeline_error`) : dernière tentative épuisée. */
export const PIPELINE_ERROR_MESSAGE =
  "L'import n'a pas abouti après plusieurs essais. Relancez-le, ou supprimez-le s'il échoue de nouveau.";

/** Fournisseur d'IA saturé à la dernière tentative (`quota_exceeded`). */
export const PROVIDER_QUOTA_MESSAGE =
  "Le service d'IA est saturé. Relancez l'import dans quelques heures.";

/** Balisage coupé à tous les efforts (`tagging_truncated`). */
export const TAGGING_TRUNCATED_MESSAGE =
  "Cette recette est trop longue pour être mise en forme par l'IA. " +
  "Créez-la à la main avec « Saisie manuelle », ou découpez-la avant de l'importer de nouveau.";

/** Fichier source hors des dossiers du propriétaire (`forbidden_source_path`). */
export const SOURCE_REFUSED_MESSAGE =
  "Le fichier de cet import n'est pas accessible. Supprimez l'import, puis envoyez le fichier de nouveau.";

/** Document Word au-delà des bornes de lecture (`archive_limit_exceeded`). */
export const ARCHIVE_LIMIT_MESSAGE =
  "Ce document est trop volumineux pour être lu. Retirez ses images ou découpez-le en " +
  "plusieurs fichiers, puis importez-le de nouveau.";

/** Mise en file Cloud Tasks en échec (`jobDispatcher`). */
export const DISPATCH_ERROR_MESSAGE =
  "L'import n'a pas pu démarrer. Relancez-le, ou supprimez-le s'il échoue de nouveau.";

/**
 * Échecs dont l'exception porte une phrase écrite pour le membre :
 * plafond d'IA du compte ou du livre (`BudgetExceededError`), livre illisible
 * (`BookFileError`), livre d'un autre (`TargetBookNotOwned`), trop de pages
 * (`TooManyPagesError`), import trop lourd (`ImportTooLargeError`).
 */
export const MEMBER_WRITTEN_FAILURES: ReadonlySet<string> = new Set([
  "budget_exceeded",
  "book_file_unreadable",
  "foreign_book",
  "too_many_pages",
  "too_large",
]);

const FIXED_MESSAGES: Readonly<Record<string, string>> = {
  quota_exceeded: PROVIDER_QUOTA_MESSAGE,
  tagging_truncated: TAGGING_TRUNCATED_MESSAGE,
  forbidden_source_path: SOURCE_REFUSED_MESSAGE,
  archive_limit_exceeded: ARCHIVE_LIMIT_MESSAGE,
};

/**
 * Le message du job pour `failureReason`. `errorMessage` est le message de
 * l'exception : il n'est recopié que pour un échec de
 * `MEMBER_WRITTEN_FAILURES`, et seulement s'il n'est pas vide.
 */
export function jobErrorMessage(failureReason: string, errorMessage: string): string {
  if (MEMBER_WRITTEN_FAILURES.has(failureReason) && errorMessage.trim().length > 0) {
    return errorMessage;
  }
  return FIXED_MESSAGES[failureReason] ?? PIPELINE_ERROR_MESSAGE;
}
