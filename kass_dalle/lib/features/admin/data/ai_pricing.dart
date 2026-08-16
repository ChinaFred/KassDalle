/// Lecture d'une grille tarifaire : résolution d'un modèle et calcul d'un coût.
///
/// **Ce fichier ne contient plus aucun prix.** Ils vivaient ici en double du
/// serveur, et ce doublon était le défaut le plus sournois du projet : un écart
/// ne cassait aucun écran, il faisait seulement mentir le reporting. La grille
/// vit désormais dans Firestore (`app_config/ai_pricing`), lue par les deux
/// côtés — voir [AiPricingRepository], qui ne se rabat sur rien : une grille
/// illisible est une panne, et une panne se dit.
///
/// Ce qui reste ici est de la lecture, appliquée à une table reçue en argument :
/// retrouver le tarif d'un identifiant de modèle, décider si une promotion
/// court, multiplier des jetons par un prix. Ces règles sont dupliquées avec
/// `functions/src/ai/pricing.ts` et asservies par
/// `test-fixtures/ai_pricing.json`, qui fournit aussi la table aux deux tests.
library;

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

  /// Tarif d'un identifiant de modèle dans une grille : correspondance exacte
  /// d'abord, puis repli sur le préfixe LE PLUS LONG.
  ///
  /// Le repli rendait autrefois le premier préfixe rencontré. Comme
  /// `gemini-2.5-flash` précède `gemini-2.5-flash-image` dans la table, une
  /// révision datée d'un modèle d'image (« …-image-preview ») était résolue
  /// vers le tarif texte : ses images étaient facturées zéro, et le reporting
  /// de coûts restait crédible tout en étant faux. Le jumeau TypeScript
  /// portait le même défaut ; les cas vivent dans
  /// `test-fixtures/ai_pricing.json`.
  static AiModelPricing forModelIn(
    Map<String, AiModelPricing> table,
    String model,
  ) {
    final exact = table[model];
    if (exact != null) return exact;

    AiModelPricing? best;
    var bestLength = -1;
    for (final entry in table.entries) {
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
  static AiModelPricing effectiveFor(
    String model, {
    DateTime? at,
    required Map<String, AiModelPricing> table,
  }) {
    final pricing = forModelIn(table, model);
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
    required Map<String, AiModelPricing> table,
  }) {
    final p = effectiveFor(model, at: at, table: table);
    return (inputTokens / 1e6) * p.inputPerMillion +
        (outputTokens / 1e6) * p.outputPerMillion +
        imageOutputCount * p.imageOutputPerUnit;
  }
}
