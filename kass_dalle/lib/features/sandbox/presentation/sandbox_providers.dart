import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../planning/domain/meal_staple.dart';
import '../../planning/presentation/meal_staples_providers.dart';
import '../../planning/presentation/planning_providers.dart';
import '../../recipes/domain/recipe.dart';
import '../../search/domain/search_models.dart';
import '../../search/presentation/search_providers.dart';

/// Ce que l'atelier repas envoie au modèle à chaque tour, lu une fois à
/// l'ouverture de l'expérience et figé en mémoire : les résumés des recettes
/// du périmètre (« Mes recettes » + « Ma famille », sans filtres), les
/// garnitures de l'administrateur, les préférences générales du planning.
///
/// Rien n'est écrit. Le bac à sable lit le code de l'application
/// (`buildRecipeSummary`, `loadMyStaples`, `globalConstraints`) sans le
/// modifier.
class MealWorkshopContext {
  final String myUid;

  /// Les résumés tels que « Chercher avec l'IA » les envoie.
  final List<Map<String, String>> summaries;

  /// Les recettes du périmètre, pour afficher livre et parts d'une recette
  /// liée. Rien n'y est écrit.
  final Map<String, Recipe> recipesById;

  /// Les garnitures visibles de l'administrateur (masquées exclues).
  final List<UserStaple> staples;

  final String globalConstraints;

  MealWorkshopContext({
    required this.myUid,
    required this.summaries,
    required this.recipesById,
    required this.staples,
    required this.globalConstraints,
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

  /// Taille du contexte fixe envoyé à chaque tour, en caractères : recettes,
  /// garnitures et préférences, hors consignes et conversation. Affichée
  /// avant le premier tour ; ensuite le serveur rend la taille exacte du
  /// prompt.
  int get contextChars =>
      jsonEncode(summaries).length +
      jsonEncode(staplePayload).length +
      globalConstraints.length;
}

/// Le contexte de l'atelier, chargé une fois. `autoDispose` : il disparaît
/// avec l'écran. L'écran fige la première valeur reçue : un changement de
/// corpus pendant la conversation n'a pas d'effet, comme au palier 1.
final mealWorkshopContextProvider =
    FutureProvider.autoDispose<MealWorkshopContext>((ref) async {
      const params = SearchParams(
        myRecipes: true,
        familyRecipes: true,
        includeDrafts: false,
      );
      final corpus = await ref.watch(exploreCorpusProvider(params).future);
      final preferences = await ref.watch(
        planningPreferencesOnceProvider.future,
      );
      final staples = await ref
          .read(mealStaplesRepositoryProvider)
          .loadMyStaples(corpus.myUid);

      return MealWorkshopContext(
        myUid: corpus.myUid,
        summaries: [
          for (final recipe in corpus.recipes)
            buildRecipeSummary(recipe, myRating: corpus.myRatings[recipe.id]),
        ],
        recipesById: {for (final recipe in corpus.recipes) recipe.id: recipe},
        staples: [
          for (final s in staples)
            if (!s.hidden) s,
        ],
        globalConstraints: preferences.globalConstraints,
      );
    });
