/// Tarifs Gemini par modèle (USD par million de tokens).
///
/// Source : https://ai.google.dev/gemini-api/docs/pricing (à mettre à jour
/// manuellement si Google modifie ses prix).
///
/// On ignore volontairement la tarification "context > 128k" pour gemini-2.5-pro
/// (à ajouter si on a beaucoup d'appels long contexte).
class GeminiModelPricing {
  final double inputPerMillion;
  final double outputPerMillion;

  /// Coût par image générée (USD). Non nul uniquement pour les modèles
  /// d'édition/génération d'images (ex : gemini-2.5-flash-image).
  final double imageOutputPerUnit;

  const GeminiModelPricing({
    required this.inputPerMillion,
    required this.outputPerMillion,
    this.imageOutputPerUnit = 0.0,
  });
}

class GeminiPricing {
  /// Tarif par défaut si le modèle n'est pas connu — équivalent flash.
  static const _defaultPricing = GeminiModelPricing(
    inputPerMillion: 0.30,
    outputPerMillion: 2.50,
  );

  /// Table des tarifs en USD / 1M tokens.
  static const _table = <String, GeminiModelPricing>{
    'gemini-2.5-flash': GeminiModelPricing(
      inputPerMillion: 0.30,
      outputPerMillion: 2.50,
    ),
    'gemini-2.5-flash-image': GeminiModelPricing(
      inputPerMillion: 0.30,
      outputPerMillion: 2.50,
      imageOutputPerUnit: 0.04, // $0.04 par image générée/éditée
    ),
    'gemini-2.5-pro': GeminiModelPricing(
      inputPerMillion: 1.25,
      outputPerMillion: 10.00,
    ),
    'gemini-2.0-flash': GeminiModelPricing(
      inputPerMillion: 0.10,
      outputPerMillion: 0.40,
    ),
    'gemini-1.5-flash': GeminiModelPricing(
      inputPerMillion: 0.075,
      outputPerMillion: 0.30,
    ),
    'gemini-1.5-pro': GeminiModelPricing(
      inputPerMillion: 1.25,
      outputPerMillion: 5.00,
    ),
  };

  /// Taux USD → EUR de dernier recours, utilisé tant que la réconciliation
  /// mensuelle n'a jamais relevé le taux réel.
  ///
  /// Ce n'est plus le taux de conversion du projet : celui-ci vit dans
  /// `app_config/currency_rate`, relevé chaque mois sur la facturation elle-même
  /// (voir `CurrencyRateRepository`). Un taux figé dans le code se périme en
  /// silence, et des montants en euros faux restent parfaitement crédibles.
  static const usdToEurFallback = 0.92;

  /// Tarif d'un identifiant de modèle : correspondance exacte d'abord, puis
  /// repli sur le préfixe LE PLUS LONG.
  ///
  /// Le repli rendait autrefois le premier préfixe rencontré. Comme
  /// `gemini-2.5-flash` précède `gemini-2.5-flash-image` dans la table, une
  /// révision datée d'un modèle d'image (« …-image-preview ») était résolue
  /// vers le tarif texte : ses images étaient facturées zéro, et le reporting
  /// de coûts restait crédible tout en étant faux. Le jumeau TypeScript
  /// portait le même défaut ; les cas vivent dans
  /// `test-fixtures/gemini_pricing.json`.
  static GeminiModelPricing forModel(String model) {
    final exact = _table[model];
    if (exact != null) return exact;

    GeminiModelPricing? best;
    var bestLength = -1;
    for (final entry in _table.entries) {
      if (model.startsWith(entry.key) && entry.key.length > bestLength) {
        best = entry.value;
        bestLength = entry.key.length;
      }
    }
    return best ?? _defaultPricing;
  }

  /// Coût en USD pour un nombre de tokens et d'images donnés.
  static double costUsd({
    required String model,
    required int inputTokens,
    required int outputTokens,
    int imageOutputCount = 0,
  }) {
    final p = forModel(model);
    return (inputTokens / 1e6) * p.inputPerMillion +
        (outputTokens / 1e6) * p.outputPerMillion +
        imageOutputCount * p.imageOutputPerUnit;
  }
}
