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
class DraftValidationPlan {
  const DraftValidationPlan({
    required this.toValidate,
    required this.withFidelityReserve,
    required this.emptyContent,
  });

  final List<Recipe> toValidate;
  final List<Recipe> withFidelityReserve;
  final List<Recipe> emptyContent;

  int get skipped => withFidelityReserve.length + emptyContent.length;

  /// Ce qu'une validation EN LOT valide réellement, réserve de fidélité
  /// comprise — après avertissement, jamais silencieusement.
  int get validatableInBatch => toValidate.length + withFidelityReserve.length;
}

DraftValidationPlan planDraftValidation(Iterable<Recipe> drafts) {
  final toValidate = <Recipe>[];
  final withReserve = <Recipe>[];
  final empty = <Recipe>[];
  for (final draft in drafts) {
    if (draftContent(draft).trim().isEmpty) {
      empty.add(draft);
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
  );
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
