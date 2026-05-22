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

  /// Taux de change USD → EUR (approximatif, à ajuster).
  static const usdToEur = 0.92;

  static GeminiModelPricing forModel(String model) {
    if (_table.containsKey(model)) return _table[model]!;
    // Fallback : essayer de matcher par préfixe (ex : "gemini-2.5-flash-002").
    for (final entry in _table.entries) {
      if (model.startsWith(entry.key)) return entry.value;
    }
    return _defaultPricing;
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

  /// Coût en EUR (approximatif).
  static double costEur({
    required String model,
    required int inputTokens,
    required int outputTokens,
  }) =>
      costUsd(model: model, inputTokens: inputTokens, outputTokens: outputTokens) *
      usdToEur;
}
