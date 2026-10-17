import '../../../processing/domain/processing_job.dart';
import '../../domain/recipe.dart';

// Logique des actions en lot de la file « Brouillons & Traitements ».
//
// Rien ici ne touche à Firestore ni à un widget : l'écran décide quoi faire de
// chaque brouillon, ce fichier dit lesquels sont admissibles et comment le
// dire à l'utilisateur.

/// Le CookLang que la file valide pour [recipe] : la copie de travail quand
/// elle porte du texte, sinon l'import.
///
/// Une copie de travail vide ne remplace pas l'import. Valider écrit ce texte
/// dans `raw_cooklang` : partir d'une chaîne vide effacerait la recette.
String draftContent(Recipe recipe) {
  final draft = recipe.draftCooklang;
  if (draft != null && draft.trim().isNotEmpty) return draft;
  return recipe.rawCooklang;
}

/// Ce qu'une validation fait de chaque brouillon sélectionné.
///
/// Valider écrit `review_status = validated` et **supprime** la réserve de
/// fidélité (`RecipeRepository.validateDraft`) : la validation dit que
/// quelqu'un a relu la page, et un lot ne relit rien. Sur une ligne seule,
/// un brouillon à réserve reste donc à valider depuis l'écran de relecture,
/// où le bandeau la montre. En lot, la réserve avertit sans bloquer — cliquer
/// cinquante fois pour des recettes qu'on ne relira pas ne protège personne
/// — voir [validatableInBatch] et le dialogue de confirmation de l'écran.
/// Un brouillon sans contenu, lui, reste de côté dans tous les cas : il n'y a
/// rien à publier, avertir ne changerait rien.
///
/// Un brouillon marqué « Doublon possible » (`duplicate_of`) reste de côté
/// lui aussi, en lot comme sur une ligne : valider publierait une deuxième
/// fois la même recette. Il se valide depuis l'écran de relecture, où le
/// bandeau montre la recette existante. La marque est revérifiée avant le
/// plan (voir [staleDuplicateMarks]) : un brouillon dont la référence a
/// disparu n'est plus un doublon.
class DraftValidationPlan {
  const DraftValidationPlan({
    required this.toValidate,
    required this.withFidelityReserve,
    required this.emptyContent,
    this.duplicates = const [],
  });

  final List<Recipe> toValidate;
  final List<Recipe> withFidelityReserve;
  final List<Recipe> emptyContent;

  /// Brouillons marqués « Doublon possible » dont la référence existe encore.
  final List<Recipe> duplicates;

  int get skipped =>
      withFidelityReserve.length + emptyContent.length + duplicates.length;

  /// Ce qu'une validation EN LOT valide réellement, réserve de fidélité
  /// comprise — après avertissement, jamais silencieusement.
  int get validatableInBatch => toValidate.length + withFidelityReserve.length;
}

/// [staleDuplicates] : identifiants des brouillons dont la marque
/// `duplicate_of` ne tient plus (référence supprimée, import en échec). Ils
/// sont traités comme des brouillons ordinaires.
DraftValidationPlan planDraftValidation(
  Iterable<Recipe> drafts, {
  Set<String> staleDuplicates = const {},
}) {
  final toValidate = <Recipe>[];
  final withReserve = <Recipe>[];
  final empty = <Recipe>[];
  final duplicates = <Recipe>[];
  for (final draft in drafts) {
    if (draftContent(draft).trim().isEmpty) {
      empty.add(draft);
    } else if (draft.duplicateOf != null &&
        !staleDuplicates.contains(draft.id)) {
      duplicates.add(draft);
    } else if ((draft.fidelityLevel ?? '').isNotEmpty) {
      withReserve.add(draft);
    } else {
      toValidate.add(draft);
    }
  }
  return DraftValidationPlan(
    toValidate: toValidate,
    withFidelityReserve: withReserve,
    emptyContent: empty,
    duplicates: duplicates,
  );
}

/// Les brouillons de [drafts] dont la marque « Doublon possible » ne tient
/// plus, relue au moment de valider.
///
/// - Référence `recipe_id` : la marque tombe quand [readRecipe] ne renvoie
///   rien (recette supprimée).
/// - Référence `job_id` : la marque tombe quand [readJob] ne renvoie rien
///   (import supprimé) ou que l'import est en erreur ou rejeté : sa recette
///   n'existera pas.
///
/// Une lecture qui échoue (permission refusée sur la recette d'un autre
/// membre, réseau) garde la marque : on ne publie pas sur un doute. L'erreur
/// est remise à [onReadError], qui la signale.
Future<Set<String>> staleDuplicateMarks(
  Iterable<Recipe> drafts, {
  required Future<Object?> Function(String recipeId) readRecipe,
  required Future<ProcessingJob?> Function(String jobId) readJob,
  required void Function(Object error, StackTrace stackTrace, Recipe draft)
  onReadError,
}) async {
  final stale = <String>{};
  for (final draft in drafts) {
    final mark = draft.duplicateOf;
    if (mark == null) continue;
    try {
      final recipeId = mark.recipeId;
      final jobId = mark.jobId;
      if (recipeId != null) {
        if (await readRecipe(recipeId) == null) stale.add(draft.id);
      } else if (jobId != null) {
        final job = await readJob(jobId);
        if (job == null ||
            job.status == ProcessingJobStatus.error ||
            job.status == ProcessingJobStatus.rejected) {
          stale.add(draft.id);
        }
      }
    } catch (error, stackTrace) {
      onReadError(error, stackTrace, draft);
    }
  }
  return stale;
}

/// « 1 brouillon », « 3 brouillons ». Zéro et un prennent le singulier.
String countOf(int n, String singular, String plural) =>
    '$n ${n >= 2 ? plural : singular}';

/// « 5 brouillons et 2 traitements » : ce que contient une sélection.
String selectionLabel({required int drafts, required int jobs}) {
  final parts = [
    if (drafts > 0) countOf(drafts, 'brouillon', 'brouillons'),
    if (jobs > 0) countOf(jobs, 'traitement', 'traitements'),
  ];
  return parts.join(' et ');
}

/// Ce qui reste de côté dans une validation, et pourquoi. Null quand tout est
/// admis.
///
/// [reserveIncluded] dit si la réserve de fidélité a été validée quand même
/// (lot, après avertissement) : la note ne la nomme alors plus comme un
/// reste, elle a été traitée.
String? notValidatedNote(
  DraftValidationPlan plan, {
  bool reserveIncluded = false,
}) {
  final left = <String>[
    if (!reserveIncluded && plan.withFidelityReserve.isNotEmpty)
      '${plan.withFidelityReserve.length} avec réserve de fidélité, '
          'à relire un par un',
    if (plan.emptyContent.isNotEmpty)
      '${plan.emptyContent.length} sans contenu',
    if (plan.duplicates.isNotEmpty)
      countOf(plan.duplicates.length, 'doublon possible', 'doublons possibles'),
  ];
  return left.isEmpty ? null : 'Non validés : ${left.join(', ')}.';
}

/// Le compte rendu d'une validation. [failed] compte les écritures refusées
/// ou tombées en erreur ; [reserveIncluded] doit valoir ce que l'appelant a
/// réellement tenté (voir [DraftValidationPlan.validatableInBatch]), sans
/// quoi le compte de brouillons validés mentirait.
String validationSummary(
  DraftValidationPlan plan, {
  bool reserveIncluded = false,
  required int failed,
}) {
  final attempted =
      plan.toValidate.length +
      (reserveIncluded ? plan.withFidelityReserve.length : 0);
  final validated = attempted - failed;
  final first = <String>[
    if (validated > 0)
      countOf(validated, 'brouillon validé', 'brouillons validés')
    else
      'Aucun brouillon validé',
    if (failed > 0) '$failed en échec',
  ].join(', ');
  final note = notValidatedNote(plan, reserveIncluded: reserveIncluded);
  return note == null ? '$first.' : '$first. $note';
}

/// Le compte rendu d'une suppression ou d'une relance en lot.
///
/// [verb] est le participe au masculin singulier (« Supprimé », « Relancé »).
/// [drafts] et [jobs] comptent les éléments réussis, [failed] les échecs.
String actionSummary({
  required String verb,
  required int drafts,
  required int jobs,
  required int failed,
}) {
  final done = drafts + jobs;
  if (done == 0) {
    return 'Aucun élément ${verb.toLowerCase()}, $failed en échec.';
  }
  final head =
      '$verb${done >= 2 ? 's' : ''} : '
      '${selectionLabel(drafts: drafts, jobs: jobs)}';
  return failed > 0 ? '$head. $failed en échec.' : '$head.';
}

/// « 2 doublons possibles à trancher » : le compteur de la file. Null quand
/// rien n'attend de décision.
String? pendingDuplicatesLabel(int count) => count <= 0
    ? null
    : '${countOf(count, 'doublon possible', 'doublons possibles')} à trancher';
