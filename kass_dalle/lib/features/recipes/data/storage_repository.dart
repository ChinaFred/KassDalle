import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/error_report_service.dart';
import '../../../core/services/gemini_service.dart';
import '../domain/storage_advice.dart';
import '../domain/storage_text.dart';

/// Accès au conseil de conservation et de réchauffage d'une recette.
///
/// Le conseil est produit par une Cloud Function qui l'écrit elle-même sur le
/// document : ce repository déclenche, relit, et — quand l'utilisateur le
/// décide — recopie le résultat en fin de CookLang.
class StorageRepository {
  final FirebaseFirestore _firestore;
  final GeminiService _gemini;
  final ErrorReportService _errorReportService;

  StorageRepository({
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
  Future<StorageAdvice?> read(String recipeId) async {
    try {
      final snap = await _col.doc(recipeId).get();
      final raw = snap.data()?['storage_advice'];
      if (raw is! Map) return null;
      return StorageAdvice.fromMap(Map<String, dynamic>.from(raw));
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'storage_advice_read',
        error: error,
        stackTrace: stackTrace,
        context: {'recipe_id': recipeId},
      );
      rethrow;
    }
  }

  /// Demande un nouveau conseil au moteur d'IA. Écrase le précédent.
  Future<StorageAdvice> generate({required String recipeId}) async {
    try {
      final payload = await _gemini.suggestStorageAdvice(recipeId: recipeId);
      return StorageAdvice.fromMap(payload);
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'storage_advice_generate',
        error: error,
        stackTrace: stackTrace,
        context: {'recipe_id': recipeId},
      );
      rethrow;
    }
  }

  /// Le conseil de la recette, produit s'il manque et recopié en fin de texte.
  ///
  /// Un conseil déjà produit ne se repaie pas : il décrit le plat, pas un
  /// repas, et sert donc à toutes ses planifications comme à toutes ses
  /// lectures.
  ///
  /// [loadRawCooklang] n'est appelé que lorsqu'il y a vraiment quelque chose à
  /// recopier : relire la recette pour un conseil déjà stocké serait une
  /// lecture Firestore pour rien.
  Future<StorageAdvice> ensure({
    required String recipeId,
    required Future<String?> Function() loadRawCooklang,
  }) async {
    final existing = await read(recipeId);
    if (existing != null) return existing;

    final advice = await generate(recipeId: recipeId);
    // Recopie tentée à part : un lecteur d'une recette de la famille n'a pas le
    // droit d'écrire, et le conseil vaut malgré tout d'être montré.
    try {
      final rawCooklang = await loadRawCooklang();
      if (rawCooklang != null) {
        await applyToRecipe(
          recipeId: recipeId,
          rawCooklang: rawCooklang,
          advice: advice,
        );
      }
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'storage_advice_ensure_apply',
        error: error,
        stackTrace: stackTrace,
        context: {'recipe_id': recipeId},
      );
    }
    return advice;
  }

  /// Recopie le conseil en fin de recette, sous sa section dédiée.
  ///
  /// Une insertion répétée remplace la précédente : régénérer trois fois ne
  /// doit pas laisser trois consignes de conservation contradictoires.
  Future<String> applyToRecipe({
    required String recipeId,
    required String rawCooklang,
    required StorageAdvice advice,
  }) async {
    try {
      final updated = applyStorageSection(rawCooklang, advice);
      // `updated_at` reste intact : recopier un conseil déjà produit ne change
      // pas la recette aux yeux des tris « récemment modifiées ».
      await _col.doc(recipeId).update({'raw_cooklang': updated});
      return updated;
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'storage_advice_apply',
        error: error,
        stackTrace: stackTrace,
        context: {'recipe_id': recipeId},
      );
      rethrow;
    }
  }
}
