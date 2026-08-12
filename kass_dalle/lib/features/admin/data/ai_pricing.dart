/// Tarifs des modèles d'IA par identifiant (USD par million de tokens), tous
/// fournisseurs confondus.
///
/// Sources, à mettre à jour manuellement quand un fournisseur change ses prix :
///   - Google  : https://ai.google.dev/gemini-api/docs/pricing
///   - Anthropic : https://platform.claude.com/docs/en/pricing
///
/// Jumeau TypeScript : `functions/src/ai/pricing.ts`. Le fichier s'appelait
/// `gemini_pricing.dart` tant qu'il n'y avait qu'un moteur ; une table nommée
/// « Gemini » contenant les tarifs Claude aurait fini par tromper son lecteur.
///
/// On ignore volontairement la tarification "context > 128k" pour gemini-2.5-pro
/// (à ajouter si on a beaucoup d'appels long contexte).
class AiModelPricing {
  final double inputPerMillion;
  final double outputPerMillion;

  /// Coût par image générée (USD). Non nul uniquement pour les modèles
  /// d'édition/génération d'images (ex : gemini-2.5-flash-image).
  final double imageOutputPerUnit;

  const AiModelPricing({
    required this.inputPerMillion,
    required this.outputPerMillion,
    this.imageOutputPerUnit = 0.0,
  });
}

class AiPricing {
  /// Tarif par défaut si le modèle n'est pas connu — équivalent flash.
  static const _defaultPricing = AiModelPricing(
    inputPerMillion: 0.30,
    outputPerMillion: 2.50,
  );

  /// Table des tarifs en USD / 1M tokens.
  static const _table = <String, AiModelPricing>{
    // ── Google Gemini ──────────────────────────────────────────────────────
    'gemini-2.5-flash': AiModelPricing(
      inputPerMillion: 0.30,
      outputPerMillion: 2.50,
    ),
    'gemini-2.5-flash-image': AiModelPricing(
      inputPerMillion: 0.30,
      outputPerMillion: 2.50,
      imageOutputPerUnit: 0.04, // $0.04 par image générée/éditée
    ),
    'gemini-2.5-pro': AiModelPricing(
      inputPerMillion: 1.25,
      outputPerMillion: 10.00,
    ),
    'gemini-2.0-flash': AiModelPricing(
      inputPerMillion: 0.10,
      outputPerMillion: 0.40,
    ),
    'gemini-1.5-flash': AiModelPricing(
      inputPerMillion: 0.075,
      outputPerMillion: 0.30,
    ),
    'gemini-1.5-pro': AiModelPricing(
      inputPerMillion: 1.25,
      outputPerMillion: 5.00,
    ),

    // ── Anthropic Claude ───────────────────────────────────────────────────
    // Tarifs catalogue au 12 août 2026. Claude Sonnet 5 bénéficie d'un tarif
    // d'introduction (2,00 / 10,00) jusqu'au 31 août 2026 : on facture au tarif
    // plein, pour que le reporting ne sous-estime jamais le coût réel.
    'claude-opus-5': AiModelPricing(
      inputPerMillion: 5.00,
      outputPerMillion: 25.00,
    ),
    'claude-opus-4-8': AiModelPricing(
      inputPerMillion: 5.00,
      outputPerMillion: 25.00,
    ),
    'claude-sonnet-5': AiModelPricing(
      inputPerMillion: 3.00,
      outputPerMillion: 15.00,
    ),
    'claude-sonnet-4-6': AiModelPricing(
      inputPerMillion: 3.00,
      outputPerMillion: 15.00,
    ),
    'claude-haiku-4-5': AiModelPricing(
      inputPerMillion: 1.00,
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
  /// `test-fixtures/ai_pricing.json`.
  static AiModelPricing forModel(String model) {
    final exact = _table[model];
    if (exact != null) return exact;

    AiModelPricing? best;
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
