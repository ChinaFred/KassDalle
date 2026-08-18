import 'package:cloud_firestore/cloud_firestore.dart';

/// Un critère lu par le moteur, avec son palier d'origine.
class ModerationCriterion {
  final String key;
  final String likelihood;

  const ModerationCriterion({required this.key, required this.likelihood});
}

/// Un label rendu par le moteur, avec sa confiance.
class ModerationLabelScore {
  final String name;
  final double score;

  const ModerationLabelScore({required this.name, required this.score});
}

/// Une décision de modération, telle qu'elle est relue par l'administration.
///
/// Le journal porte **toutes** les images, pas seulement les refusées : une
/// page qui ne montrerait que les rejets ne dirait rien du plus important, ce
/// que la modération laisse passer.
class ModerationEntry {
  final String id;
  final String status;
  final String uid;
  final String targetKind;
  final String? ownerId;
  final String decisionReason;
  final String engine;
  final String engineVersion;
  final int sizeBytes;
  final String mimeType;
  final String? publishedUrl;

  /// Chemin de l'image conservée après un refus, sous `rejected/`.
  ///
  /// Aucune URL n'est stockée : l'écran lit le fichier avec les droits de
  /// l'administrateur qui le consulte. Émettre un jeton de téléchargement
  /// rendrait le lien partageable et survivrait au retrait du rôle.
  final String? rejectedPath;

  final String? correlationId;
  final DateTime? createdAt;
  final DateTime? reviewedAt;
  final String? reviewedBy;
  final String? reviewNote;

  /// Paliers d'origine, dans l'ordre d'affichage des critères connus.
  final List<ModerationCriterion> criteria;
  final List<ModerationLabelScore> labels;

  /// Labels qui ont fait le contexte culinaire — mis en évidence à l'écran.
  final List<String> culinaryMatches;

  const ModerationEntry({
    required this.id,
    required this.status,
    required this.uid,
    required this.targetKind,
    required this.ownerId,
    required this.decisionReason,
    required this.engine,
    required this.engineVersion,
    required this.sizeBytes,
    required this.mimeType,
    required this.publishedUrl,
    required this.rejectedPath,
    required this.correlationId,
    required this.createdAt,
    required this.reviewedAt,
    required this.reviewedBy,
    required this.reviewNote,
    required this.criteria,
    required this.labels,
    required this.culinaryMatches,
  });

  /// Ordre d'affichage des critères : du plus grave au plus anecdotique.
  static const _criteriaOrder = [
    'adult',
    'racy',
    'violence',
    'medical',
    'spoof',
  ];

  static DateTime? _date(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return null;
  }

  factory ModerationEntry.fromMap(String id, Map<String, dynamic> data) {
    final signals = (data['signals'] as Map?)?.cast<String, dynamic>() ?? {};
    final raw = (signals['raw'] as Map?)?.cast<String, dynamic>() ?? {};

    // On parcourt l'ordre voulu plutôt que les clés reçues : un moteur qui
    // ajouterait un critère ne doit pas décaler l'affichage des autres, et un
    // critère absent doit se voir absent plutôt que de se glisser à la fin.
    final criteria = <ModerationCriterion>[];
    for (final key in _criteriaOrder) {
      final value = raw[key];
      if (value == null) continue;
      criteria.add(ModerationCriterion(key: key, likelihood: value.toString()));
    }

    final labels = <ModerationLabelScore>[];
    for (final entry in (signals['labels'] as List? ?? const [])) {
      if (entry is! Map) continue;
      final name = (entry['name'] ?? '').toString();
      if (name.isEmpty) continue;
      labels.add(
        ModerationLabelScore(
          name: name,
          score: (entry['score'] as num?)?.toDouble() ?? 0,
        ),
      );
    }
    labels.sort((a, b) => b.score.compareTo(a.score));

    return ModerationEntry(
      id: id,
      status: (data['status'] ?? '').toString(),
      uid: (data['uid'] ?? '').toString(),
      targetKind: (data['target_kind'] ?? '').toString(),
      ownerId: data['owner_id'] as String?,
      decisionReason: (data['decision_reason'] ?? '').toString(),
      engine: (data['engine'] ?? '').toString(),
      engineVersion: (data['engine_version'] ?? '').toString(),
      sizeBytes: (data['size_bytes'] as num?)?.toInt() ?? 0,
      mimeType: (data['mime_type'] ?? '').toString(),
      publishedUrl: data['published_url'] as String?,
      rejectedPath: data['rejected_path'] as String?,
      correlationId: data['correlation_id'] as String?,
      createdAt: _date(data['created_at']),
      reviewedAt: _date(data['reviewed_at']),
      reviewedBy: data['reviewed_by'] as String?,
      reviewNote: data['review_note'] as String?,
      criteria: criteria,
      labels: labels,
      culinaryMatches: (data['culinary_matches'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(),
    );
  }

  /// Vrai si cette image attend réellement la décision de quelqu'un.
  bool get awaitsDecision => status == 'manual_review';
}
