import 'package:cloud_functions/cloud_functions.dart';

import '../../../core/services/error_report_service.dart';

/// Fournisseurs d'inférence connus de l'application.
enum AiProvider {
  gemini,
  anthropic;

  String get wireName => name;

  String get label => switch (this) {
    AiProvider.gemini => 'Gemini',
    AiProvider.anthropic => 'Claude',
  };

  static AiProvider fromWire(String? value) => switch (value) {
    'anthropic' => AiProvider.anthropic,
    _ => AiProvider.gemini,
  };
}

/// Poste fonctionnel routable, tel que le backend le déclare.
///
/// La liste vient du serveur et n'est pas dupliquée ici : deux listes de postes
/// finiraient par diverger, et une bascule sur un poste que le backend ignore
/// ne produit aucune erreur — elle ne route simplement rien.
class RoutableFeature {
  final String id;
  final String label;

  /// Famille du poste (Import, Nutrition, Rédaction…).
  ///
  /// Sert uniquement à regrouper l'écran : une trentaine de postes en liste
  /// plate se bascule mal, et un poste qu'on ne retrouve pas est un poste qu'on
  /// ne bascule pas.
  final String group;

  const RoutableFeature({
    required this.id,
    required this.label,
    this.group = 'Autres',
  });
}

class AiRoutingPolicy {
  final AiProvider defaultProvider;
  final Map<String, AiProvider> features;
  final String anthropicModel;
  final bool fallbackEnabled;

  /// Plafond de jetons de raisonnement pour Gemini, `null` = le modèle décide.
  ///
  /// Le raisonnement est facturé au tarif de sortie sans jamais apparaître
  /// dans une réponse. Sur un mois observé, il pesait 2,1 millions de jetons
  /// sur les 2,4 millions de sortie facturés : c'est le seul réglage qui agit
  /// sur la ligne la plus chère de la facture Gemini.
  final int? thinkingBudget;

  /// Plafond par poste — l'emporte sur le plafond global.
  final Map<String, int> thinkingBudgets;

  const AiRoutingPolicy({
    required this.defaultProvider,
    required this.features,
    required this.anthropicModel,
    required this.fallbackEnabled,
    this.thinkingBudget,
    this.thinkingBudgets = const {},
  });

  AiProvider providerFor(String featureId) =>
      features[featureId] ?? defaultProvider;

  /// Plafond effectif d'un poste : le sien, à défaut le global.
  int? thinkingBudgetFor(String featureId) =>
      thinkingBudgets[featureId] ?? thinkingBudget;

  AiRoutingPolicy copyWith({
    AiProvider? defaultProvider,
    Map<String, AiProvider>? features,
    String? anthropicModel,
    bool? fallbackEnabled,
    // `null` est une valeur signifiante pour un plafond : un booléen dit
    // explicitement qu'on veut l'effacer, sinon « ne pas toucher » et
    // « remettre à zéro » seraient indistinguables.
    int? thinkingBudget,
    bool clearThinkingBudget = false,
    Map<String, int>? thinkingBudgets,
  }) {
    return AiRoutingPolicy(
      defaultProvider: defaultProvider ?? this.defaultProvider,
      features: features ?? this.features,
      anthropicModel: anthropicModel ?? this.anthropicModel,
      fallbackEnabled: fallbackEnabled ?? this.fallbackEnabled,
      thinkingBudget: clearThinkingBudget
          ? null
          : (thinkingBudget ?? this.thinkingBudget),
      thinkingBudgets: thinkingBudgets ?? this.thinkingBudgets,
    );
  }

  Map<String, dynamic> toMap() => {
    'defaultProvider': defaultProvider.wireName,
    'features': {
      for (final entry in features.entries) entry.key: entry.value.wireName,
    },
    'anthropicModel': anthropicModel,
    'fallbackEnabled': fallbackEnabled,
    'thinkingBudget': thinkingBudget,
    'thinkingBudgets': thinkingBudgets,
  };
}

/// Politique de routage accompagnée de ce qu'il faut pour la lire sans se
/// tromper : les postes disponibles, et la présence effective de la clé Claude.
class AiRoutingSnapshot {
  final AiRoutingPolicy policy;
  final bool anthropicKeyPresent;
  final List<RoutableFeature> routableFeatures;

  const AiRoutingSnapshot({
    required this.policy,
    required this.anthropicKeyPresent,
    required this.routableFeatures,
  });
}

class AiRoutingRepository {
  final FirebaseFunctions _functions;
  final ErrorReportService _errorReportService;

  AiRoutingRepository({
    FirebaseFunctions? functions,
    ErrorReportService? errorReportService,
  }) : _functions =
           functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1'),
       _errorReportService = errorReportService ?? ErrorReportService();

  Future<AiRoutingSnapshot> fetch() async {
    try {
      final raw = await _functions
          .httpsCallable('getAiRoutingPolicyFn')
          .call<Map<String, dynamic>>();
      return _parse(Map<String, dynamic>.from(raw.data));
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'aiRouting.fetch',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  Future<AiRoutingSnapshot> save(AiRoutingPolicy policy) async {
    try {
      final raw = await _functions
          .httpsCallable('setAiRoutingPolicyFn')
          .call<Map<String, dynamic>>({'policy': policy.toMap()});
      final data = Map<String, dynamic>.from(raw.data);
      // L'écriture ne renvoie pas la liste des postes : on conserve celle que
      // l'écran affiche déjà plutôt que d'inventer une liste vide.
      return AiRoutingSnapshot(
        policy: _parsePolicy(
          Map<String, dynamic>.from(data['policy'] as Map? ?? const {}),
        ),
        anthropicKeyPresent: data['anthropicKeyPresent'] == true,
        routableFeatures: const [],
      );
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'aiRouting.save',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  AiRoutingSnapshot _parse(Map<String, dynamic> data) {
    final features = (data['routableFeatures'] as List? ?? const [])
        .whereType<Map>()
        .map(
          (m) => RoutableFeature(
            id: m['id'] as String? ?? '',
            label: m['label'] as String? ?? '',
            group: m['group'] as String? ?? 'Autres',
          ),
        )
        .where((f) => f.id.isNotEmpty)
        .toList(growable: false);

    return AiRoutingSnapshot(
      policy: _parsePolicy(
        Map<String, dynamic>.from(data['policy'] as Map? ?? const {}),
      ),
      anthropicKeyPresent: data['anthropicKeyPresent'] == true,
      routableFeatures: features,
    );
  }

  AiRoutingPolicy _parsePolicy(Map<String, dynamic> data) {
    final rawFeatures = Map<String, dynamic>.from(
      data['features'] as Map? ?? const {},
    );
    return AiRoutingPolicy(
      defaultProvider: AiProvider.fromWire(data['defaultProvider'] as String?),
      features: {
        for (final entry in rawFeatures.entries)
          entry.key: AiProvider.fromWire(entry.value as String?),
      },
      anthropicModel: data['anthropicModel'] as String? ?? 'claude-sonnet-5',
      fallbackEnabled: data['fallbackEnabled'] != false,
      thinkingBudget: (data['thinkingBudget'] as num?)?.toInt(),
      thinkingBudgets: {
        for (final entry
            in Map<String, dynamic>.from(
              data['thinkingBudgets'] as Map? ?? const {},
            ).entries)
          if (entry.value is num) entry.key: (entry.value as num).toInt(),
      },
    );
  }
}
