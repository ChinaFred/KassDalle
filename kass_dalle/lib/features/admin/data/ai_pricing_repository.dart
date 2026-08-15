import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/error_report_service.dart';
import '../../../core/services/gemini_service.dart';
import 'ai_pricing.dart';

/// Grille tarifaire en vigueur, lue là où le serveur la lit.
///
/// Le client et le serveur ne portent plus deux tables : ils lisent le même
/// document `app_config/ai_pricing`. Ce qui reste dupliqué, c'est la grille de
/// **repli** — `ai_pricing.dart` ici, `ai/pricing.ts` là-bas — appliquée quand
/// le document est absent ou injoignable, et asservie par la fixture partagée.
///
/// Le client en a besoin pour une raison précise : annoncer un coût **avant**
/// de le dépenser. Le montant réellement imputé, lui, est figé côté serveur au
/// moment de l'appel et n'est jamais recalculé ici.
class AiPricingRepository {
  final FirebaseFirestore _firestore;
  final GeminiService _gemini;
  final ErrorReportService _errorReportService;

  AiPricingRepository({
    FirebaseFirestore? firestore,
    GeminiService? geminiService,
    ErrorReportService? errorReportService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _gemini = geminiService ?? GeminiService(),
       _errorReportService =
           errorReportService ?? ErrorReportService(firestore: firestore);

  DocumentReference<Map<String, dynamic>> get _doc =>
      _firestore.collection('app_config').doc('ai_pricing');

  /// Lit une entrée sous sa forme Firestore.
  ///
  /// Une entrée dont les tarifs de jetons sont illisibles est rejetée : mieux
  /// vaut le repli en dur qu'un modèle affiché à zéro parce qu'une saisie a mis
  /// du texte là où on attendait un nombre.
  static AiModelPricing? parseEntry(Map<String, dynamic> data) {
    double? readNum(Object? v) {
      final n = v is num ? v.toDouble() : null;
      return (n != null && n.isFinite && n >= 0) ? n : null;
    }

    final input = readNum(data['input_per_million']);
    final output = readNum(data['output_per_million']);
    if (input == null || output == null) return null;

    AiIntroductoryPricing? promo;
    final raw = data['introductory'];
    if (raw is Map) {
      final p = Map<String, dynamic>.from(raw);
      final pIn = readNum(p['input_per_million']);
      final pOut = readNum(p['output_per_million']);
      final until = p['until_iso'] as String? ?? '';
      // Une promotion sans date de fin lisible devient un tarif permanent le
      // jour où elle expire : on la refuse plutôt que de sous-estimer.
      if (pIn != null && pOut != null && DateTime.tryParse(until) != null) {
        promo = AiIntroductoryPricing(
          inputPerMillion: pIn,
          outputPerMillion: pOut,
          untilIso: until,
        );
      }
    }

    return AiModelPricing(
      inputPerMillion: input,
      outputPerMillion: output,
      imageOutputPerUnit: readNum(data['image_output_per_unit']) ?? 0,
      introductory: promo,
    );
  }

  /// Rend une entrée sous sa forme Firestore.
  static Map<String, dynamic> entryToMap(AiModelPricing entry) => {
    'input_per_million': entry.inputPerMillion,
    'output_per_million': entry.outputPerMillion,
    'image_output_per_unit': entry.imageOutputPerUnit,
    'introductory': entry.introductory == null
        ? null
        : {
            'input_per_million': entry.introductory!.inputPerMillion,
            'output_per_million': entry.introductory!.outputPerMillion,
            'until_iso': entry.introductory!.untilIso,
          },
  };

  /// Grille en vigueur : le repli en dur, recouvert par Firestore.
  ///
  /// Une lecture impossible rend le repli plutôt qu'une table vide — un écran
  /// de coûts à zéro serait pris pour une bonne nouvelle.
  Future<Map<String, AiModelPricing>> load() async {
    final merged = Map<String, AiModelPricing>.from(AiPricing.builtinTable);
    try {
      final snap = await _doc.get();
      final raw = snap.data()?['models'];
      if (raw is Map) {
        for (final e in raw.entries) {
          final value = e.value;
          if (value is! Map) continue;
          final parsed = parseEntry(Map<String, dynamic>.from(value));
          if (parsed != null) merged['${e.key}'] = parsed;
        }
      }
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'ai_pricing_load',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return merged;
  }

  /// Enregistre le tarif d'un modèle. [pricing] à `null` rend la main au tarif
  /// livré avec le code.
  Future<void> save({
    required String model,
    required AiModelPricing? pricing,
  }) async {
    try {
      await _gemini.setAiPricing(
        model: model,
        pricing: pricing == null ? null : entryToMap(pricing),
      );
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'ai_pricing_save',
        error: error,
        stackTrace: stackTrace,
        context: {'model': model, 'cleared': pricing == null},
      );
      rethrow;
    }
  }
}
