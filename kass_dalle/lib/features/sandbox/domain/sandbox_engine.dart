import 'package:flutter/foundation.dart';

/// Ce qui a **réellement** fait le travail à une étape.
///
/// Relevé sur la réponse, jamais sur la configuration. Les deux diffèrent plus
/// souvent qu'on ne croit : le repli automatique change de fournisseur en cours
/// de route, un modèle inconnu se solde par une erreur, et un poste sans choix
/// explicite suit un défaut qu'on a oublié avoir posé. Un écran qui affiche la
/// configuration affiche une intention, pas un fait.
@immutable
class SandboxEngine {
  /// La passe concernée, telle que le serveur la nomme.
  final String stage;

  /// `gemini`, `anthropic`, ou le nom de la boîte à outils locale.
  final String provider;

  /// L'identifiant du modèle, ou l'algorithme employé.
  final String model;

  /// Ce que la politique demandait, quand un repli a servi autre chose.
  final String? requested;

  const SandboxEngine({
    required this.stage,
    required this.provider,
    required this.model,
    this.requested,
  });

  /// Un travail fait sur l'appareil, sans réseau ni modèle.
  const SandboxEngine.local({required this.stage, required this.model})
    : provider = 'local',
      requested = null;

  bool get isLocal => provider == 'local';

  static SandboxEngine? fromJson(Map<String, dynamic> json) {
    final provider = (json['provider'] as String?)?.trim() ?? '';
    final model = (json['model'] as String?)?.trim() ?? '';
    if (provider.isEmpty || model.isEmpty) return null;
    return SandboxEngine(
      stage: (json['stage'] as String?)?.trim() ?? '',
      provider: provider,
      model: model,
      requested: (json['requested'] as String?)?.trim(),
    );
  }

  static List<SandboxEngine> listFrom(dynamic raw) {
    if (raw is! List) return const [];
    final engines = <SandboxEngine>[];
    for (final entry in raw) {
      if (entry is! Map) continue;
      final engine = SandboxEngine.fromJson(Map<String, dynamic>.from(entry));
      if (engine != null) engines.add(engine);
    }
    return engines;
  }

  /// Le libellé de la passe, en français.
  String get stageLabel => switch (stage) {
    'sandbox_detect_page_box' => 'boîte',
    'sandbox_detect_page_corners' => 'coins',
    'sandbox_detect_regions' => 'zones',
    _ => stage,
  };

  String get providerLabel => switch (provider) {
    'anthropic' => 'Claude',
    'gemini' => 'Gemini',
    'local' => 'Sur l\'appareil',
    _ => provider,
  };
}
