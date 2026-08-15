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
/// Tarif promotionnel d'un modèle, borné dans le temps.
///
/// [untilIso] est une borne **exclue** : au premier instant de cette date, le
/// tarif catalogue reprend. Sans date, une promotion devient un tarif permanent
/// le jour où elle expire, et le reporting se met à sous-estimer en silence.
class AiIntroductoryPricing {
  final double inputPerMillion;
  final double outputPerMillion;
  final String untilIso;

  const AiIntroductoryPricing({
    required this.inputPerMillion,
    required this.outputPerMillion,
    required this.untilIso,
  });
}

class AiModelPricing {
  final double inputPerMillion;
  final double outputPerMillion;

  /// Coût par image générée (USD). Non nul uniquement pour les modèles
  /// d'édition/génération d'images (ex : gemini-2.5-flash-image).
  final double imageOutputPerUnit;

  /// Promotion en cours, quand le fournisseur en accorde une.
  final AiIntroductoryPricing? introductory;

  const AiModelPricing({
    required this.inputPerMillion,
    required this.outputPerMillion,
    this.imageOutputPerUnit = 0.0,
    this.introductory,
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
    // Ancien modèle image du projet, conservé pour les mois déjà consommés :
    // leurs lignes portent cet identifiant, et sans l'entrée elles se
    // reliraient au tarif par défaut, images comprises — c'est-à-dire à zéro.
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
    // Nano Banana 2 Lite — modèle image courant (`GEMINI_IMAGE_MODEL` côté
    // Functions). 0,0336 $ l'image 1K : 1120 jetons de sortie à 30 $ le million.
    'gemini-3.1-flash-lite-image': AiModelPricing(
      inputPerMillion: 0.25,
      outputPerMillion: 1.50,
      imageOutputPerUnit: 0.0336,
    ),

    // ── Anthropic Claude ───────────────────────────────────────────────────
    // Tarifs catalogue au 12 août 2026.
    //
    // Le tarif d'introduction de Sonnet 5 était volontairement ignoré, au motif
    // qu'une surestimation valait mieux qu'une sous-estimation. La
    // confrontation à la facture d'août a montré l'erreur : 1,20 € estimés
    // contre 0,80 € facturés, soit 50 % d'écart — assez pour rendre le
    // rapprochement inexploitable, et pour masquer un vrai défaut de comptage
    // le jour où il s'en produirait un. Une marge de sécurité posée sur un
    // instrument de mesure ne le sécurise pas : elle le casse.
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
      introductory: AiIntroductoryPricing(
        inputPerMillion: 2.00,
        outputPerMillion: 10.00,
        untilIso: '2026-09-01T00:00:00Z',
      ),
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

  /// Tarif réellement en vigueur à une date donnée.
  ///
  /// [forModel] rend l'entrée de catalogue, promotion comprise ; c'est ici
  /// qu'on décide laquelle des deux s'applique.
  static AiModelPricing effectiveFor(String model, {DateTime? at}) {
    final pricing = forModel(model);
    final promo = pricing.introductory;
    if (promo == null) return pricing;

    final until = DateTime.tryParse(promo.untilIso);
    // Une date de fin illisible ne doit pas offrir une promotion perpétuelle :
    // dans le doute, on facture au tarif catalogue.
    if (until == null) return pricing;

    final moment = (at ?? DateTime.now()).toUtc();
    if (!moment.isBefore(until.toUtc())) return pricing;

    return AiModelPricing(
      inputPerMillion: promo.inputPerMillion,
      outputPerMillion: promo.outputPerMillion,
      imageOutputPerUnit: pricing.imageOutputPerUnit,
    );
  }

  /// Coût en USD pour un nombre de tokens et d'images donnés.
  ///
  /// [at] est l'instant de l'appel : il se facture au tarif en vigueur **quand
  /// il a eu lieu**, jamais au tarif du jour où on relit le rapport.
  static double costUsd({
    required String model,
    required int inputTokens,
    required int outputTokens,
    int imageOutputCount = 0,
    DateTime? at,
  }) {
    final p = effectiveFor(model, at: at);
    return (inputTokens / 1e6) * p.inputPerMillion +
        (outputTokens / 1e6) * p.outputPerMillion +
        imageOutputCount * p.imageOutputPerUnit;
  }
}
