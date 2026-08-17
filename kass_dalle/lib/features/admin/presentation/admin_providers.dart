import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/admin_repository.dart';
import '../data/app_check_repository.dart';
import '../data/nutrition_ingredients_repository.dart';
import '../data/nutrition_units_repository.dart';
import '../../auth/domain/app_user.dart';
import '../../../core/services/error_report_service.dart';

final adminRepositoryProvider = Provider<AdminRepository>((ref) {
  return AdminRepository();
});

final allUsersProvider = StreamProvider.autoDispose<List<AppUser>>((ref) {
  return ref.watch(adminRepositoryProvider).watchAllUsers();
});

final appCheckRepositoryProvider = Provider<AppCheckRepository>((_) {
  return AppCheckRepository();
});

final nutritionIngredientsRepositoryProvider =
    Provider<NutritionIngredientsRepository>((_) {
      return NutritionIngredientsRepository();
    });

final allNutritionIngredientsProvider =
    StreamProvider.autoDispose<List<NutritionIngredientDoc>>((ref) {
      return ref.watch(nutritionIngredientsRepositoryProvider).watchAll();
    });

final nutritionUnitsRepositoryProvider = Provider<NutritionUnitsRepository>((
  _,
) {
  return NutritionUnitsRepository();
});

final allNutritionUnitsProvider = StreamProvider<List<NutritionUnitDoc>>((ref) {
  return ref.watch(nutritionUnitsRepositoryProvider).watchAll();
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
