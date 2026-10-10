import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/error_report_service.dart';
import '../domain/original_text.dart';

/// Lecture du texte d'origine d'une recette traduite à l'import.
///
/// Le document est écrit par le serveur (`pipeline/originalText.ts`) et se lit
/// avec les droits de la recette. Le client ne l'écrit jamais.
class OriginalTextRepository {
  final FirebaseFirestore _firestore;
  final ErrorReportService _errorReportService;

  OriginalTextRepository({
    FirebaseFirestore? firestore,
    ErrorReportService? errorReportService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _errorReportService =
           errorReportService ?? ErrorReportService(firestore: firestore);

  /// Le texte d'origine, ou `null` si la recette n'en porte pas.
  Future<OriginalText?> read(String recipeId) async {
    try {
      final snap = await _firestore
          .collection('recipes')
          .doc(recipeId)
          .collection('origine')
          .doc('texte')
          .get();
      final data = snap.data();
      return data == null ? null : OriginalText.fromMap(data);
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'recipes.originalText.read',
        error: error,
        stackTrace: stackTrace,
        context: {'recipe_id': recipeId},
      );
      rethrow;
    }
  }
}
