/// « Figer le repas » : ce que la boîte annonce, les doublons de titre à
/// trancher avant tout appel, et l'état de chaque ligne pendant et après le
/// figement.
///
/// Fonctions pures, sans Firebase, testées dans
/// `test/meal_workshop_freeze_test.dart`. L'écran enchaîne les appels ; ce
/// fichier dit quoi afficher.
library;

import '../../recipes/domain/recipe.dart';
import '../../recipes/domain/recipe_filter.dart';
import 'meal_workshop_menu.dart';

// ── Le livre des brouillons ──────────────────────────────────────────────────

/// Le livre qui reçoit les brouillons d'un figement : les deux livres
/// système du compte, trouvés ou créés (`findOrCreateKassDalleBook`,
/// `findOrCreateLibresBook`).
enum MealWorkshopBook {
  kassDalle,
  libres;

  String get label => switch (this) {
    MealWorkshopBook.kassDalle => 'Mes créations Kass\'Dalle ✨',
    MealWorkshopBook.libres => 'Mes recettes libres',
  };
}

// ── Doublons de titre ────────────────────────────────────────────────────────

/// Ce que l'utilisateur décide d'un plat à rédiger qui porte le titre d'une
/// recette du périmètre.
enum DuplicateDecision { link, write }

/// Un plat à rédiger ([courseIndex]) dont le titre est déjà celui d'une
/// recette du périmètre ([recipe]).
class WorkshopTitleDuplicate {
  final int courseIndex;
  final Recipe recipe;

  const WorkshopTitleDuplicate({
    required this.courseIndex,
    required this.recipe,
  });

  /// « « Blanquette de veau » existe dans Le Grand Livre ».
  String get line =>
      '« ${recipe.titre} » existe dans ${recipe.bookTitre ?? 'Sans livre'}';
}

/// La clé de comparaison de deux titres : minuscules, sans accents ni
/// ponctuation ([foldSearchText]).
String workshopTitleKey(String title) => foldSearchText(title);

/// Les plats à rédiger de [menu] dont le titre égale, sans casse ni accents,
/// celui d'une recette de [recipes] : la première recette qui correspond,
/// dans l'ordre reçu. Une recette liée n'est pas un doublon : elle est déjà
/// la recette.
List<WorkshopTitleDuplicate> workshopTitleDuplicates(
  WorkshopMenu menu,
  Iterable<Recipe> recipes,
) {
  final byKey = <String, Recipe>{};
  for (final recipe in recipes) {
    final key = workshopTitleKey(recipe.titre);
    if (key.isEmpty) continue;
    byKey.putIfAbsent(key, () => recipe);
  }
  return [
    for (final (index, course) in menu.courses.indexed)
      if (course.isToWrite)
        if (byKey[workshopTitleKey(course.title)] case final recipe?)
          WorkshopTitleDuplicate(courseIndex: index, recipe: recipe),
  ];
}

// ── Le texte de la boîte ─────────────────────────────────────────────────────

/// La première phrase de la boîte « Figer le repas » : « 3 plats seront
/// rédigés par l'IA, pour 6 parts : un appel chacun. 1 recette existante
/// reste liée telle quelle, avec ses propres parts. » La seconde phrase
/// manque sans recette liée. Sans plat à rédiger — tous les doublons liés —
/// : « Aucun plat ne sera rédigé : 2 recettes existantes seront liées. »
String freezeDialogSummary({
  required int toWrite,
  required int linked,
  required int portions,
}) {
  if (toWrite == 0) {
    return linked == 1
        ? 'Aucun plat ne sera rédigé : 1 recette existante sera liée.'
        : 'Aucun plat ne sera rédigé : $linked recettes existantes seront '
              'liées.';
  }
  final parts = workshopPortionsLabel(portions);
  final first = toWrite == 1
      ? '1 plat sera rédigé par l\'IA, pour $parts : un appel.'
      : '$toWrite plats seront rédigés par l\'IA, pour $parts : un appel '
            'chacun.';
  if (linked == 0) return first;
  final second = linked == 1
      ? '1 recette existante reste liée telle quelle, avec ses propres parts.'
      : '$linked recettes existantes restent liées telles quelles, avec '
            'leurs propres parts.';
  return '$first $second';
}

/// Une ligne par plat à rédiger qui a des accompagnements : ils sont cités
/// dans la recette du plat, sans recette à part. Avec un seul plat concerné,
/// la phrase ne le nomme pas.
List<String> freezeSidesLines(WorkshopMenu menu) {
  final dishes = [
    for (final course in menu.courses)
      if (course.isToWrite && course.sides.isNotEmpty) course,
  ];
  if (dishes.isEmpty) return const [];
  String sides(WorkshopCourse c) => c.sides.map((s) => s.label).join(', ');
  if (dishes.length == 1) {
    return [
      'Accompagnements cités dans la recette du plat, sans recette à part : '
          '${sides(dishes.single)}.',
    ];
  }
  return [
    for (final c in dishes)
      'Accompagnements cités dans la recette de « ${c.title} », sans recette '
          'à part : ${sides(c)}.',
  ];
}

// ── L'état d'une ligne ───────────────────────────────────────────────────────

/// L'état d'un service pendant et après le figement.
sealed class FreezeLineState {
  const FreezeLineState();
}

/// « En attente » : pas encore traité.
class FreezeWaiting extends FreezeLineState {
  const FreezeWaiting();
}

/// « Rédaction… » : l'appel est en cours.
class FreezeWriting extends FreezeLineState {
  const FreezeWriting();
}

/// « Brouillon créé · Ouvrir ».
class FreezeDraftCreated extends FreezeLineState {
  final String draftId;
  const FreezeDraftCreated(this.draftId);
}

/// « Recette liée · Ouvrir » : la recette existante, relue, est lisible.
class FreezeLinked extends FreezeLineState {
  final String recipeId;
  const FreezeLinked(this.recipeId);
}

/// « Recette plus accessible » : supprimée ou devenue privée pendant la
/// conversation. « Rédiger à la place » ou « Retirer du repas ».
class FreezeLinkedUnreadable extends FreezeLineState {
  const FreezeLinkedUnreadable();
}

/// « Non rédigée — Réessayer » : réseau ou serveur.
class FreezeFailed extends FreezeLineState {
  final Object error;
  const FreezeFailed(this.error);
}

/// « Non rédigée. L'IA n'a pas rendu de recette. » + « Réessayer ».
class FreezeNoRecipe extends FreezeLineState {
  const FreezeNoRecipe();
}

/// « Non rédigée — plafond atteint » : le budget d'IA du jour, sans
/// « Réessayer » ; les services suivants ne sont pas tentés.
class FreezeBudgetStopped extends FreezeLineState {
  /// Le message du serveur, qui dit quand l'IA revient.
  final String message;
  const FreezeBudgetStopped(this.message);
}

/// « Non rédigée. L'IA est réservée aux éditeurs. » : le rôle a été retiré
/// en cours de session.
class FreezePermissionDenied extends FreezeLineState {
  const FreezePermissionDenied();
}

/// « Brouillon non enregistré — Réessayer » : la recette est rédigée et
/// gardée en mémoire ; « Réessayer » ne refait pas d'appel.
class FreezeSaveFailed extends FreezeLineState {
  final Recipe recipe;
  final Object error;
  const FreezeSaveFailed(this.recipe, this.error);
}

/// Brouillons créés par le figement.
int freezeCreatedCount(List<FreezeLineState> lines) =>
    lines.whereType<FreezeDraftCreated>().length;

/// Recettes existantes relues et toujours liées.
int freezeLinkedCount(List<FreezeLineState> lines) =>
    lines.whereType<FreezeLinked>().length;

/// Plats à rédiger qui n'ont pas de brouillon : en attente, en cours,
/// échoués, arrêtés par le plafond, ou rédigés sans être enregistrés. Une
/// recette liée, lisible ou non, n'est pas un plat à rédiger.
int freezeNotWrittenCount(WorkshopMenu menu, List<FreezeLineState> lines) {
  var count = 0;
  for (final (index, course) in menu.courses.indexed) {
    if (index >= lines.length) continue;
    final state = lines[index];
    if (state is FreezeLinked || state is FreezeLinkedUnreadable) continue;
    if (course.isLinked && state is FreezeWaiting) continue;
    if (state is! FreezeDraftCreated) count++;
  }
  return count;
}

/// Vrai quand une ligne attend une action de l'utilisateur ou peut être
/// rejouée : « Réessayer », « Rédiger à la place », « Retirer du repas ».
bool freezeLineRetryable(FreezeLineState state) => switch (state) {
  FreezeFailed() ||
  FreezeNoRecipe() ||
  FreezeSaveFailed() ||
  FreezeLinkedUnreadable() => true,
  _ => false,
};

// ── Libellés ─────────────────────────────────────────────────────────────────

/// « 3 brouillons créés · 1 recette liée », le pied du panneau après un
/// figement.
String freezeFooterLine({required int created, required int linked}) =>
    '$created ${created > 1 ? 'brouillons créés' : 'brouillon créé'} · '
    '$linked ${linked > 1 ? 'recettes liées' : 'recette liée'}';

/// « 2 plats à rédiger · 1 recette liée », le pied du panneau avant.
String menuFooterLine({required int toWrite, required int linked}) =>
    '$toWrite ${toWrite > 1 ? 'plats' : 'plat'} à rédiger · '
    '$linked ${linked > 1 ? 'recettes liées' : 'recette liée'}';

/// « 2 recettes liées », « 1 recette liée » : le pied du panneau d'un
/// figement sans plat à rédiger.
String linkedOnlyLine(int linked) =>
    '$linked ${linked > 1 ? 'recettes liées' : 'recette liée'}';

/// « Repas figé : 2 recettes liées. » — un figement sans plat à rédiger,
/// donc sans appel d'IA ni livre créé.
String freezeLinkedOnlyMessage(int linked) =>
    'Repas figé : ${linkedOnlyLine(linked)}.';

/// « 3 brouillons créés dans « Mes créations Kass'Dalle ✨ ». »
String freezeDoneMessage({required int created, required String bookTitle}) =>
    '$created ${created > 1 ? 'brouillons créés' : 'brouillon créé'} dans '
    '« $bookTitle ».';

/// « 1 plat non rédigé. 2 brouillons créés. »
String freezePartialMessage({required int notWritten, required int created}) =>
    '$notWritten ${notWritten > 1 ? 'plats non rédigés' : 'plat non rédigé'}. '
    '$created ${created > 1 ? 'brouillons créés' : 'brouillon créé'}.';

/// « 1 plat n'est pas rédigé. » / « 2 plats ne sont pas rédigés. »
String notWrittenSentence(int notWritten) => notWritten == 1
    ? '1 plat n\'est pas rédigé.'
    : '$notWritten plats ne sont pas rédigés.';

/// « 2 plats ne sont pas rédigés. Quitter sans enregistrer ? »
String leaveAfterPartialFreezeTitle(int notWritten) =>
    '${notWrittenSentence(notWritten)} Quitter sans enregistrer ?';

/// « 1 plat n'est pas rédigé. Nouvelle conversation ? »
String newConversationAfterPartialFreezeTitle(int notWritten) =>
    '${notWrittenSentence(notWritten)} Nouvelle conversation ?';
