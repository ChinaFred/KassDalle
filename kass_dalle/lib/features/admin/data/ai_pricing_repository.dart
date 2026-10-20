import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/error_report_service.dart';
import '../../../core/services/gemini_service.dart';
import 'ai_pricing.dart';

/// Une ligne de la grille, telle que l'écran d'administration la montre.
typedef AiPricingRow = ({
  String model,
  AiModelPricing pricing,

  /// Vrai quand le tarif a été saisi, et ne vient donc pas de l'amorçage.
  bool overridden,
});

/// La grille n'a pas pu être lue : aucun prix n'est connu, aucun n'est inventé.
class AiPricingUnavailable implements Exception {
  final String cause;

  /// L'exception d'origine quand la lecture elle-même a échoué (réseau,
  /// droits) ; null quand la grille a été lue mais n'est pas exploitable.
  /// L'écran en tire un message lisible sans recopier [toString].
  final Object? source;

  const AiPricingUnavailable(this.cause, {this.source});

  @override
  String toString() => 'Grille tarifaire indisponible ($cause)';
}

/// Grille tarifaire en vigueur, lue là où le serveur la lit.
///
/// Le client ne porte plus aucun prix : il lit `app_config/ai_pricing`, le même
/// document que le serveur. Il en a besoin pour une raison précise — annoncer
/// un coût **avant** de le dépenser. Le montant réellement imputé, lui, est
/// figé côté serveur au moment de l'appel et n'est jamais recalculé ici.
///
/// **Aucun repli.** Une grille illisible lève [AiPricingUnavailable], et
/// l'écran dit la panne. Afficher un tarif de secours reviendrait à présenter
/// un prix périmé comme exact.
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
  /// Une entrée dont les tarifs de jetons sont illisibles est rejetée : ce
  /// modèle n'a alors plus de prix du tout, ce qui est vrai, plutôt qu'un prix
  /// à zéro parce qu'une saisie a mis du texte là où on attendait un nombre.
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
      analyzedImagePerUnit: readNum(data['analyzed_image_per_unit']) ?? 0,
      freeUnitsPerMonth: (readNum(data['free_units_per_month']) ?? 0).round(),
      groundedSearchPerUnit: readNum(data['grounded_search_per_unit']) ?? 0,
      introductory: promo,
    );
  }

  /// Rend une entrée sous sa forme Firestore.
  static Map<String, dynamic> entryToMap(AiModelPricing entry) => {
    'input_per_million': entry.inputPerMillion,
    'output_per_million': entry.outputPerMillion,
    'image_output_per_unit': entry.imageOutputPerUnit,
    'analyzed_image_per_unit': entry.analyzedImagePerUnit,
    'free_units_per_month': entry.freeUnitsPerMonth,
    'grounded_search_per_unit': entry.groundedSearchPerUnit,
    'introductory': entry.introductory == null
        ? null
        : {
            'input_per_million': entry.introductory!.inputPerMillion,
            'output_per_million': entry.introductory!.outputPerMillion,
            'until_iso': entry.introductory!.untilIso,
          },
  };

  /// Grille en vigueur, telle qu'elle vit dans Firestore.
  ///
  /// **Aucun repli.** Afficher les tarifs du code à la place des vrais donnerait
  /// des prix périmés présentés comme exacts — un écran crédible et faux, ce que
  /// tout ce module existe pour empêcher. Une grille illisible lève une
  /// [AiPricingUnavailable] ; à l'appelant de dire la panne.
  Future<Map<String, AiModelPricing>> load() async {
    final Map<String, dynamic>? data;
    try {
      data = (await _doc.get()).data();
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'ai_pricing_load',
        error: error,
        stackTrace: stackTrace,
      );
      throw AiPricingUnavailable('lecture impossible : $error', source: error);
    }

    final raw = data?['models'];
    if (raw is! Map) {
      throw const AiPricingUnavailable('grille absente');
    }

    final table = <String, AiModelPricing>{};
    for (final e in raw.entries) {
      final value = e.value;
      if (value is! Map) continue;
      final parsed = parseEntry(Map<String, dynamic>.from(value));
      if (parsed != null) table['${e.key}'] = parsed;
    }
    if (table.isEmpty) {
      throw const AiPricingUnavailable('aucun modèle exploitable');
    }
    return table;
  }

  /// Grille en vigueur pour l'écran d'administration, avec la mention des
  /// tarifs modifiés depuis l'amorçage.
  ///
  /// Passe par la Cloud Function : elle seule connaît la table d'amorçage, et
  /// peut donc distinguer un tarif saisi d'un tarif d'origine. C'est ce qui
  /// permet au client de ne plus porter aucun prix.
  Future<List<AiPricingRow>> fetchForAdmin() async {
    final List<Map<String, dynamic>> models;
    try {
      models = await _gemini.getAiPricing();
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'ai_pricing_fetch_admin',
        error: error,
        stackTrace: stackTrace,
      );
      throw AiPricingUnavailable('lecture impossible : $error', source: error);
    }

    final rows = <AiPricingRow>[];
    for (final m in models) {
      final parsed = parseEntry(m);
      if (parsed == null) continue;
      rows.add((
        model: m['model'] as String? ?? '',
        pricing: parsed,
        overridden: m['overridden'] == true,
      ));
    }
    if (rows.isEmpty) {
      throw const AiPricingUnavailable('aucun modèle exploitable');
    }
    rows.sort((a, b) => a.model.compareTo(b.model));
    return rows;
  }

  /// Enregistre le tarif d'un modèle. [pricing] à `null` rend la main au tarif
  /// d'amorçage livré avec le serveur.
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
