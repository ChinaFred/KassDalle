import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/error_report_service.dart';
import '../../../core/services/gemini_service.dart';
import '../domain/plating_advice.dart';
import '../domain/plating_cooklang.dart';

/// Accès au conseil de dressage d'une recette.
///
/// Le conseil est produit par une Cloud Function qui l'écrit elle-même sur le
/// document : ce repository ne fait que déclencher, relire et — quand
/// l'utilisateur le décide — recopier le résultat dans le CookLang.
class PlatingRepository {
  final FirebaseFirestore _firestore;
  final GeminiService _gemini;
  final ErrorReportService _errorReportService;

  PlatingRepository({
    FirebaseFirestore? firestore,
    GeminiService? geminiService,
    ErrorReportService? errorReportService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _gemini = geminiService ?? GeminiService(),
       _errorReportService =
           errorReportService ?? ErrorReportService(firestore: firestore);

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('recipes');

  /// Conseil déjà stocké, ou null si la recette n'en a jamais reçu.
  Future<PlatingAdvice?> read(String recipeId) async {
    try {
      final snap = await _col.doc(recipeId).get();
      final raw = snap.data()?['plating_advice'];
      if (raw is! Map) return null;
      return PlatingAdvice.fromMap(Map<String, dynamic>.from(raw));
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'plating_read',
        error: error,
        stackTrace: stackTrace,
        context: {'recipe_id': recipeId},
      );
      rethrow;
    }
  }

  /// Demande un nouveau conseil au moteur d'IA. Écrase le précédent.
  Future<PlatingAdvice> generate({
    required String recipeId,
    String? userInstruction,
  }) async {
    try {
      final payload = await _gemini.suggestPlating(
        recipeId: recipeId,
        userInstruction: userInstruction,
      );
      return PlatingAdvice.fromMap(payload);
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'plating_generate',
        error: error,
        stackTrace: stackTrace,
        context: {
          'recipe_id': recipeId,
          'has_instruction': userInstruction?.isNotEmpty ?? false,
        },
      );
      rethrow;
    }
  }

  /// Génère le visuel de montage d'une étape et retourne son URL.
  Future<String> generateStepImage({
    required String recipeId,
    required int stepIndex,
  }) async {
    try {
      return await _gemini.generatePlatingImage(
        recipeId: recipeId,
        stepIndex: stepIndex,
      );
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'plating_image',
        error: error,
        stackTrace: stackTrace,
        context: {'recipe_id': recipeId, 'step_index': stepIndex},
      );
      rethrow;
    }
  }

  /// Génère le visuel du dressage terminé et retourne son URL.
  Future<String> generateFinalImage({required String recipeId}) async {
    try {
      return await _gemini.generatePlatingImage(recipeId: recipeId, finalImage: true);
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'plating_image_final',
        error: error,
        stackTrace: stackTrace,
        context: {'recipe_id': recipeId},
      );
      rethrow;
    }
  }

  /// Écrit la section « Dressage » dans le CookLang de la recette.
  ///
  /// Retourne le CookLang enregistré, pour que l'appelant affiche ce qui a
  /// réellement été écrit plutôt que ce qu'il croyait envoyer.
  Future<String> writeSectionToRecipe({
    required String recipeId,
    required String currentCooklang,
    required PlatingAdvice advice,
  }) async {
    final updated = applyPlatingSection(currentCooklang, advice);
    try {
      await _col.doc(recipeId).update({
        'raw_cooklang': updated,
        'updated_at': DateTime.now(),
      });
      return updated;
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'plating_write_section',
        error: error,
        stackTrace: stackTrace,
        context: {'recipe_id': recipeId},
      );
      rethrow;
    }
  }
}
