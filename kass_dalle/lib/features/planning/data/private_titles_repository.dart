import 'package:cloud_functions/cloud_functions.dart';

import '../../../core/services/error_report_service.dart';
import '../domain/private_recipe_title.dart';

/// Lit les titres des recettes privées des membres de mes groupes
/// (`listFamilyPrivateTitlesFn`). Les règles Firestore interdisent la lecture
/// de ces recettes : seul le serveur les lit, et il ne rend que le titre.
class PrivateTitlesRepository {
  final FirebaseFunctions? _functionsOverride;
  final ErrorReportService _errorReportService;

  PrivateTitlesRepository({
    FirebaseFunctions? functions,
    ErrorReportService? errorReportService,
  }) : _functionsOverride = functions,
       _errorReportService = errorReportService ?? ErrorReportService();

  FirebaseFunctions get _functions =>
      _functionsOverride ??
      FirebaseFunctions.instanceFor(region: 'europe-west1');

  Future<List<PrivateRecipeTitle>> list() async {
    try {
      final raw = await _functions
          .httpsCallable('listFamilyPrivateTitlesFn')
          .call<Object?>();
      return parsePrivateRecipeTitles(raw.data);
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'meal_suggestions.load_private_titles',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }
}
