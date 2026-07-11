import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/admin_repository.dart';
import '../data/nutrition_ingredients_repository.dart';
import '../data/nutrition_units_repository.dart';
import '../data/token_usage_repository.dart';
import '../../auth/domain/app_user.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../../core/services/error_report_service.dart';

final adminRepositoryProvider = Provider<AdminRepository>((ref) {
  return AdminRepository();
});

final allUsersProvider = StreamProvider.autoDispose<List<AppUser>>((ref) {
  return ref.watch(adminRepositoryProvider).watchAllUsers();
});

final tokenUsageRepositoryProvider = Provider<TokenUsageRepository>((_) {
  return TokenUsageRepository();
});

/// Stream de tous les enregistrements (admin uniquement).
final allTokenUsageProvider = StreamProvider<List<TokenUsageRecord>>((ref) {
  return ref.watch(tokenUsageRepositoryProvider).watchAll();
});

final nutritionIngredientsRepositoryProvider =
    Provider<NutritionIngredientsRepository>((_) {
      return NutritionIngredientsRepository();
    });

final allNutritionIngredientsProvider =
    StreamProvider.autoDispose<List<NutritionIngredientDoc>>((ref) {
      return ref.watch(nutritionIngredientsRepositoryProvider).watchAll();
    });

final nutritionUnitsRepositoryProvider =
    Provider<NutritionUnitsRepository>((_) {
      return NutritionUnitsRepository();
    });

final allNutritionUnitsProvider =
    StreamProvider<List<NutritionUnitDoc>>((ref) {
      return ref.watch(nutritionUnitsRepositoryProvider).watchAll();
    });

/// Stream des enregistrements de l'utilisateur courant.
final myTokenUsageProvider = StreamProvider<List<TokenUsageRecord>>((ref) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(tokenUsageRepositoryProvider).watchByUser(uid);
});

final errorReportServiceProvider = Provider<ErrorReportService>(
  (_) => ErrorReportService(),
);

/// Stream de tous les rapports d'erreur (admin uniquement).
final allErrorReportsProvider = StreamProvider.autoDispose<List<ErrorReport>>((
  ref,
) {
  return ref.watch(errorReportServiceProvider).watchAll();
});
