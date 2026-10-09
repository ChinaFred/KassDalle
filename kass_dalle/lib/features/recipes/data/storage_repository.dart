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
    return (await _readStored(recipeId)).advice;
  }

  /// Le conseil stocké et le créateur de la recette, en une seule lecture.
  Future<({bool exists, StorageAdvice? advice, String createdBy})> _readStored(
    String recipeId,
  ) async {
    try {
      final snap = await _col.doc(recipeId).get();
      final data = snap.data();
      final raw = data?['storage_advice'];
      final createdBy = data?['created_by'];
      return (
        exists: snap.exists,
        advice: raw is Map
            ? StorageAdvice.fromMap(Map<String, dynamic>.from(raw))
            : null,
        createdBy: createdBy is String ? createdBy : '',
      );
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

  /// Le conseil de la recette, produit s'il manque et si l'appelant en a le
  /// droit.
  ///
  /// Un conseil déjà produit ne se repaie pas : il décrit le plat, pas un
  /// repas, et sert donc à toutes ses planifications comme à toutes ses
  /// lectures. Il n'est écrit qu'à un seul endroit, le champ `storage_advice`
  /// de la recette, et lu là où la question se pose.
  ///
  /// [canGenerate] reçoit le `created_by` de la recette : seuls son créateur
  /// et un administrateur produisent un conseil (`suggestStorageAdviceFn`
  /// refuse les autres). Quand le conseil manque et que l'appelant ne peut
  /// pas le produire, rend [StorageAdviceReserved] : l'écran le dit, sans
  /// appel refusé. Une recette absente rend [StorageAdviceRecipeMissing].
  Future<StorageAdviceLookup> ensure({
    required String recipeId,
    required bool Function(String createdBy) canGenerate,
  }) async {
    final stored = await _readStored(recipeId);
    if (!stored.exists) return const StorageAdviceRecipeMissing();
    final advice = stored.advice;
    if (advice != null) return StorageAdviceAvailable(advice);
    if (!canGenerate(stored.createdBy)) return const StorageAdviceReserved();
    return StorageAdviceAvailable(await generate(recipeId: recipeId));
  }

  /// Retire du texte la section de conservation héritée, si elle s'y trouve.
  ///
  /// Le conseil a été un temps recopié en fin de recette. Il y faisait doublon
  /// avec le bandeau, et le rendu CookLang numérotait son titre comme une étape
  /// de préparation. Rien ne l'écrit plus ; ceci nettoie ce qui reste.
  ///
  /// Rend vrai quand la recette a effectivement été nettoyée.
  Future<bool> stripSection({
    required String recipeId,
    required String rawCooklang,
  }) async {
    if (!hasStorageSection(rawCooklang)) return false;
    try {
      // `updated_at` reste intact : retirer un doublon ne change pas la recette
      // aux yeux des tris « récemment modifiées ».
      await _col.doc(recipeId).update({
        'raw_cooklang': removeStorageSection(rawCooklang),
      });
      return true;
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'storage_advice_strip_section',
        error: error,
        stackTrace: stackTrace,
        context: {'recipe_id': recipeId},
      );
      rethrow;
    }
  }
}
