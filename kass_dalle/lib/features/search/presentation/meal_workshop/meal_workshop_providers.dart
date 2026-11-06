import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/gemini_providers.dart';
import '../../../admin/presentation/admin_providers.dart'
    show errorReportServiceProvider;
import '../../../auth/presentation/auth_providers.dart';
import '../../../groups/presentation/group_providers.dart';
import '../../../planning/domain/meal_staple.dart';
import '../../../planning/presentation/meal_staples_providers.dart';
import '../../../planning/presentation/planning_providers.dart';
import '../../../recipes/domain/recipe.dart';
import '../../../recipes/domain/recipe_filter.dart';
import '../../../recipes/presentation/recipe_providers.dart';
import '../../data/meal_workshop_daily_repository.dart';
import '../../data/meal_workshop_draft_repository.dart';
import '../../data/meal_workshop_functions.dart';
import '../../domain/meal_workshop_menu.dart';
import '../../domain/meal_workshop_summary.dart';
import '../search_providers.dart';

final mealWorkshopFunctionsProvider = Provider<MealWorkshopFunctions>(
  (ref) => MealWorkshopFunctions(ref.watch(geminiServiceProvider)),
);

final mealWorkshopDailyRepositoryProvider =
    Provider<MealWorkshopDailyRepository>(
      (ref) => MealWorkshopDailyRepository(
        errorReportService: ref.watch(errorReportServiceProvider),
      ),
    );

final mealWorkshopDraftRepositoryProvider =
    Provider<MealWorkshopDraftRepository>(
      (ref) => MealWorkshopDraftRepository(
        recipes: ref.watch(recipeRepositoryProvider),
        errorReportService: ref.watch(errorReportServiceProvider),
      ),
    );

/// Ce que l'atelier repas envoie au modèle à chaque tour, lu une fois à
/// l'ouverture et figé en mémoire : les résumés des recettes du périmètre
/// (les filtres d'Explorer, sans le texte, comme « Chercher avec l'IA »),
/// les garnitures de l'utilisateur, les préférences générales du planning,
/// les parts par défaut et le compteur du jour.
///
/// Rien n'est écrit. Un changement de filtres dans Explorer pendant la
/// conversation n'a pas d'effet : pour un autre périmètre, quitter l'atelier
/// et le rouvrir.
class MealWorkshopContext {
  final String myUid;
  final String displayName;

  /// Les résumés de l'atelier : 6 ingrédients, durée, sans livre ni statut.
  final List<Map<String, String>> summaries;

  /// Les recettes du périmètre, pour afficher livre et parts d'une recette
  /// liée, et détecter un doublon de titre. Rien n'y est écrit.
  final Map<String, Recipe> recipesById;

  /// Les garnitures visibles de l'utilisateur (masquées exclues).
  final List<UserStaple> staples;

  final String globalConstraints;

  /// Les parts du menu à l'ouverture ([defaultMealWorkshopPortions]).
  final int defaultPortions;

  /// Le compteur du jour ; `null` quand il est inconnu (lecture en échec).
  final WorkshopQuota? quota;

  const MealWorkshopContext({
    required this.myUid,
    required this.displayName,
    required this.summaries,
    required this.recipesById,
    required this.staples,
    required this.globalConstraints,
    required this.defaultPortions,
    required this.quota,
  });

  /// Les garnitures telles que le serveur les attend.
  List<Map<String, String>> get staplePayload => [
    for (final s in staples)
      {
        'id': s.staple.id,
        'name': s.staple.name,
        'category': s.staple.category.name,
      },
  ];

  MealStaple? stapleById(String id) {
    for (final s in staples) {
      if (s.staple.id == id) return s.staple;
    }
    return null;
  }
}

/// Le contexte de l'atelier, chargé une fois. `autoDispose` : il disparaît
/// avec l'écran. L'écran fige la première valeur reçue.
final mealWorkshopContextProvider =
    FutureProvider.autoDispose<MealWorkshopContext>((ref) async {
      final user = await ref.watch(appUserProvider.future);
      if (user == null) throw StateError('Utilisateur non connecté.');
      final saved = await ref.watch(explorePreferencesProvider.future);
      // Le lecteur ne voit pas « Mes brouillons » : même règle qu'Explorer.
      final prefs = user.canEdit
          ? saved
          : saved.copyWith(
              sources: saved.sources.copyWith(includeDrafts: false),
            );
      final corpus = await ref.watch(
        exploreCorpusProvider(prefs.sources).future,
      );
      // Le corpus de « Chercher avec l'IA » : les filtres, sans le texte.
      final scoped = applyRecipeFilter(
        corpus.recipes,
        filter: prefs.filter,
        context: RecipeFilterContext.forFilter(
          prefs.filter,
          myRatings: corpus.myRatings,
        ),
        sort: prefs.sort,
      ).recipes;
      final preferences = await ref.watch(
        planningPreferencesOnceProvider.future,
      );
      final staples = await ref
          .read(mealStaplesRepositoryProvider)
          .loadMyStaples(corpus.myUid);
      final groups = await ref.watch(myGroupsProvider.future);
      final paused = await ref.watch(maskedGroupIdsProvider.future);
      final quota = await ref
          .read(mealWorkshopDailyRepositoryProvider)
          .remainingFor(corpus.myUid);

      return MealWorkshopContext(
        myUid: corpus.myUid,
        displayName: user.displayName,
        summaries: [
          for (final recipe in scoped)
            buildMealWorkshopSummary(
              recipe,
              myRating: corpus.myRatings[recipe.id],
            ),
        ],
        recipesById: {for (final recipe in scoped) recipe.id: recipe},
        staples: [
          for (final s in staples)
            if (!s.hidden) s,
        ],
        globalConstraints: preferences.globalConstraints,
        defaultPortions: defaultMealWorkshopPortions(
          groups: groups,
          pausedGroupIds: paused,
          groupPortions: preferences.groupPortions,
        ),
        quota: quota,
      );
    });
