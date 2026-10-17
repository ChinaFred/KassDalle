import '../../processing/domain/processing_job.dart';
import 'recipe.dart';

// Ce que devient la référence d'un doublon possible, relue à l'affichage.
//
// Le serveur écrit la référence une fois (`duplicates[].recipe_id` / `job_id`
// d'un job, `duplicate_of` d'un brouillon) et ne la réécrit jamais. Une
// référence à un import plus ancien (`job_id`) vieillit donc : l'import finit,
// échoue ou disparaît. Le client la résout à chaque affichage.

/// L'état d'une référence de doublon possible.
sealed class DuplicateReference {
  const DuplicateReference();
}

/// L'import plus ancien est encore en file ou en cours : sa recette n'existe
/// pas encore.
final class DuplicateReferencePending extends DuplicateReference {
  const DuplicateReferencePending();
}

/// La recette existante se lit : elle s'ouvre.
final class DuplicateReferenceFound extends DuplicateReference {
  const DuplicateReferenceFound(this.recipe);
  final Recipe recipe;
}

/// La recette existe mais ne se lit pas. [denied] : refus des règles (livre
/// privé ou brouillon d'un autre membre), un refus attendu. Sinon, une autre
/// erreur de lecture, déjà signalée.
final class DuplicateReferenceUnreadable extends DuplicateReference {
  const DuplicateReferenceUnreadable({required this.denied});
  final bool denied;
}

/// La référence ne mène plus à rien : recette supprimée, import en erreur,
/// rejeté, lui-même arrêté en doublon, supprimé ou illisible.
final class DuplicateReferenceGone extends DuplicateReference {
  const DuplicateReferenceGone();
}

/// Ce qu'un import plus ancien dit de sa recette : en attente, à chercher
/// parmi [ProcessingJob.createdRecipeIds], ou perdue.
///
/// Retourne la liste des recettes candidates (non vide) quand l'import est
/// terminé, `null` sinon ; [pending] dit si l'import tourne encore.
({bool pending, List<String> candidates}) duplicateJobOutcome(
  ProcessingJob? job,
) {
  if (job == null) return (pending: false, candidates: const []);
  switch (job.status) {
    case ProcessingJobStatus.queued:
    case ProcessingJobStatus.processing:
      return (pending: true, candidates: const []);
    case ProcessingJobStatus.done:
      return (pending: false, candidates: job.createdRecipeIds);
    case ProcessingJobStatus.error:
    case ProcessingJobStatus.rejected:
    case ProcessingJobStatus.duplicate:
      return (pending: false, candidates: const []);
  }
}

/// La recette d'un import terminé qui sert de référence : celle dont le titre
/// égale [existingTitre] (casse et espaces ignorés), sinon la première lue.
/// `null` quand aucune ne se lit.
Recipe? pickDuplicateReferenceRecipe(
  Iterable<Recipe> recipes,
  String existingTitre,
) {
  final wanted = existingTitre.trim().toLowerCase();
  Recipe? first;
  for (final recipe in recipes) {
    first ??= recipe;
    if (wanted.isNotEmpty && recipe.titre.trim().toLowerCase() == wanted) {
      return recipe;
    }
  }
  return first;
}

/// « Déjà dans le livre : Tarte aux pommes, p. 42 », d'après la recette
/// trouvée.
String duplicateFoundLabel(Recipe recipe) {
  final page = recipe.pageNumber;
  return page == null
      ? 'Déjà dans le livre : ${recipe.titre}'
      : 'Déjà dans le livre : ${recipe.titre}, p. $page';
}
