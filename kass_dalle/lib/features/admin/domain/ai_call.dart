/// Un appel de modèle, tel qu'il a été facturé.
///
/// Il ne vient pas des journaux : il vient de `ai_usage`, la collection que
/// lisent aussi les écrans de facturation. Chiffrer l'appel ici, depuis les
/// jetons écrits dans une ligne de journal, aurait produit un second montant
/// calculé autrement que le premier — deux écrans, deux chiffres, et aucun
/// moyen de dire lequel est juste.
class AiCall {
  const AiCall({
    required this.callId,
    required this.correlationId,
    required this.scanId,
    required this.feature,
    required this.provider,
    required this.model,
    required this.status,
    required this.inputTokens,
    required this.outputTokens,
    required this.totalTokens,
    required this.costUsd,
    required this.timestamp,
  });

  /// Identifiant partagé avec les lignes de journal de cet appel.
  ///
  /// `null` pour les appels enregistrés avant que ce champ existe : leur
  /// montant reste exact et compte dans les totaux, mais aucune ligne de
  /// journal ne peut leur être rattachée.
  final String? callId;

  final String? correlationId;
  final String? scanId;
  final String feature;
  final String provider;
  final String model;

  /// `ok` ou `error` — un appel échoué a été servi, donc facturé.
  final String status;

  final int inputTokens;
  final int outputTokens;
  final int totalTokens;

  /// `null` quand la grille tarifaire était en panne au moment de l'appel.
  ///
  /// Ce n'est pas zéro : l'appel a coûté quelque chose qu'on ne sait pas
  /// chiffrer. L'écran l'affiche comme tel, sans jamais l'additionner.
  final double? costUsd;

  final DateTime? timestamp;

  factory AiCall.fromMap(Map<String, dynamic> map) {
    final cost = map['costUsd'];
    final ts = map['timestamp'];
    return AiCall(
      callId: map['callId'] as String?,
      correlationId: map['correlationId'] as String?,
      scanId: map['scanId'] as String?,
      feature: (map['feature'] ?? '').toString(),
      provider: (map['provider'] ?? '').toString(),
      model: (map['model'] ?? '').toString(),
      status: (map['status'] ?? 'ok').toString(),
      inputTokens: (map['inputTokens'] as num?)?.toInt() ?? 0,
      outputTokens: (map['outputTokens'] as num?)?.toInt() ?? 0,
      totalTokens: (map['totalTokens'] as num?)?.toInt() ?? 0,
      costUsd: cost is num ? cost.toDouble() : null,
      timestamp: ts is String ? DateTime.tryParse(ts) : null,
    );
  }

  bool get failed => status == 'error';
}

/// Somme des coûts d'un ensemble d'appels, et ce qu'elle ne couvre pas.
///
/// Le nombre d'appels non chiffrés voyage AVEC le total, et n'est pas une
/// information annexe : un total de 0,03 $ sur douze appels dont quatre sans
/// prix n'est pas un total, c'est un minimum. L'afficher seul le ferait passer
/// pour la dépense réelle.
class AiCostTotal {
  const AiCostTotal({
    required this.costUsd,
    required this.calls,
    required this.unpricedCalls,
    required this.totalTokens,
  });

  static const empty = AiCostTotal(
    costUsd: 0,
    calls: 0,
    unpricedCalls: 0,
    totalTokens: 0,
  );

  final double costUsd;
  final int calls;

  /// Appels dont le coût est inconnu — grille tarifaire en panne à ce
  /// moment-là. Ils comptent dans [calls] mais pas dans [costUsd].
  final int unpricedCalls;

  final int totalTokens;

  bool get isEmpty => calls == 0;

  AiCostTotal plus(AiCall call) {
    return AiCostTotal(
      costUsd: costUsd + (call.costUsd ?? 0),
      calls: calls + 1,
      unpricedCalls: unpricedCalls + (call.costUsd == null ? 1 : 0),
      totalTokens: totalTokens + call.totalTokens,
    );
  }

  AiCostTotal merge(AiCostTotal other) {
    return AiCostTotal(
      costUsd: costUsd + other.costUsd,
      calls: calls + other.calls,
      unpricedCalls: unpricedCalls + other.unpricedCalls,
      totalTokens: totalTokens + other.totalTokens,
    );
  }

  static AiCostTotal of(Iterable<AiCall> calls) {
    var total = AiCostTotal.empty;
    for (final call in calls) {
      total = total.plus(call);
    }
    return total;
  }
}
