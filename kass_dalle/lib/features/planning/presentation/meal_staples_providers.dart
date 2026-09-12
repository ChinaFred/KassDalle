import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/presentation/auth_providers.dart';
import '../data/meal_staples_repository.dart';
import '../domain/meal_staple.dart';

final mealStaplesRepositoryProvider = Provider<MealStaplesRepository>(
  (_) => MealStaplesRepository(),
);

/// Le référentiel partagé, en direct.
final baseMealStaplesProvider = StreamProvider.autoDispose<List<MealStaple>>(
  (ref) => ref.watch(mealStaplesRepositoryProvider).watchBase(),
);

/// Les retouches du compte connecté.
final myStapleOverridesProvider =
    StreamProvider.autoDispose<Map<String, StapleOverride>>((ref) {
      final uid = ref.watch(appUserProvider).value?.uid;
      if (uid == null) return Stream.value(const {});
      return ref.watch(mealStaplesRepositoryProvider).watchOverrides(uid);
    });

/// Les garnitures telles que le compte connecté les voit : la base, ses
/// retouches, les siennes — masquées comprises, c'est l'écran qui décide de
/// les montrer.
final myStaplesProvider = Provider.autoDispose<AsyncValue<List<UserStaple>>>((
  ref,
) {
  final base = ref.watch(baseMealStaplesProvider);
  final overrides = ref.watch(myStapleOverridesProvider);
  if (base.hasError) {
    return AsyncValue.error(base.error!, base.stackTrace ?? StackTrace.empty);
  }
  if (overrides.hasError) {
    return AsyncValue.error(
      overrides.error!,
      overrides.stackTrace ?? StackTrace.empty,
    );
  }
  final b = base.value;
  final o = overrides.value;
  if (b == null || o == null) return const AsyncValue.loading();
  return AsyncValue.data(mergeStaples(b, o));
});
