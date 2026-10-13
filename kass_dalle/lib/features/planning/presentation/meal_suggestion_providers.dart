import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/error_reporting.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../groups/domain/family_group.dart';
import '../../groups/presentation/group_providers.dart';
import '../../recipes/domain/recipe.dart';
import '../data/meal_suggestion_repository.dart';
import '../domain/meal_suggestion.dart';
import 'planning_providers.dart';

final mealSuggestionRepositoryProvider = Provider<MealSuggestionRepository>(
  (ref) => MealSuggestionRepository(),
);

/// Les groupes actifs où l'utilisateur suggère un plat : il en est membre,
/// pas propriétaire. Vide tant que groupes et portée ne sont pas lus.
final suggestableGroupsProvider = Provider.autoDispose<List<FamilyGroup>>((
  ref,
) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const [];
  final groups = ref.watch(myGroupsProvider).value;
  final reach = ref.watch(planningReachProvider).value;
  if (groups == null || reach == null) return const [];
  return suggestableGroups(groups: groups, myUid: uid, reach: reach);
});

/// Les groupes actifs dont l'utilisateur est propriétaire et qui comptent un
/// autre membre : ceux où il reçoit des suggestions.
final suggestionOwnerGroupsProvider = Provider.autoDispose<List<FamilyGroup>>((
  ref,
) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const [];
  final groups = ref.watch(myGroupsProvider).value;
  final reach = ref.watch(planningReachProvider).value;
  if (groups == null || reach == null) return const [];
  return suggestionOwnerGroups(groups: groups, myUid: uid, reach: reach);
});

/// Les suggestions reçues, en continu depuis [kSuggestionHistoryDays] jours.
/// Aucune lecture pour qui ne possède aucun groupe qui en reçoive.
final receivedSuggestionsProvider =
    StreamProvider.autoDispose<List<MealSuggestion>>((ref) {
      final uid = ref.watch(appUserProvider).value?.uid;
      if (uid == null) return Stream.value(const []);
      final owns = ref.watch(
        suggestionOwnerGroupsProvider.select((g) => g.isNotEmpty),
      );
      if (!owns) return Stream.value(const []);
      return ref.watch(mealSuggestionRepositoryProvider).watchReceived(uid);
    });

/// Les suggestions envoyées, en continu depuis [kSuggestionHistoryDays]
/// jours. Aucune lecture pour qui n'est membre d'aucun groupe d'un autre.
final sentSuggestionsProvider =
    StreamProvider.autoDispose<List<MealSuggestion>>((ref) {
      final uid = ref.watch(appUserProvider).value?.uid;
      if (uid == null) return Stream.value(const []);
      final member = ref.watch(
        suggestableGroupsProvider.select((g) => g.isNotEmpty),
      );
      if (!member) return Stream.value(const []);
      return ref.watch(mealSuggestionRepositoryProvider).watchSent(uid);
    });

/// Le badge du propriétaire : les suggestions reçues des jours à venir,
/// aujourd'hui compris, pour ses groupes actifs.
final upcomingReceivedCountProvider = Provider.autoDispose<int>((ref) {
  final groups = {
    for (final g in ref.watch(suggestionOwnerGroupsProvider)) g.id,
  };
  final received = ref.watch(receivedSuggestionsProvider).value ?? const [];
  return upcomingSuggestionCount(
    received.where((s) => groups.contains(s.groupId)),
    DateTime.now(),
  );
});

/// Les recettes qu'un membre peut suggérer : les siennes validées et celles,
/// validées et non privées, des membres de ses groupes. Triées par titre,
/// sans doublon. Lues une fois par ouverture de la feuille.
final suggestableRecipesProvider = FutureProvider.autoDispose<List<Recipe>>((
  ref,
) async {
  final repo = ref.watch(planningRepositoryProvider);
  if (repo == null) return const [];
  final family = (await ref.watch(
    groupReachProvider.future,
  )).where((id) => id != repo.uid).toList();
  try {
    final results = await Future.wait([
      repo.getValidatedRecipes(),
      repo.getFamilyValidatedRecipes(family),
    ]);
    final byId = <String, Recipe>{
      for (final list in results)
        for (final r in list) r.id: r,
    };
    return byId.values.toList()
      ..sort((a, b) => a.titre.toLowerCase().compareTo(b.titre.toLowerCase()));
  } catch (e, stackTrace) {
    reportUnexpectedError(
      feature: 'meal_suggestions.load_recipes',
      error: e,
      stackTrace: stackTrace,
      userId: repo.uid,
    );
    rethrow;
  }
});
