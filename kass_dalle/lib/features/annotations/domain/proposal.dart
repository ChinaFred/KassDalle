/// Type de proposition qu'un utilisateur peut soumettre à un autre.
enum ProposalType {
  /// Proposer une annotation sur une recette existante.
  annotation,

  /// Proposer une nouvelle recette dans un livre.
  recipe,
}

enum ProposalStatus { pending, accepted, rejected }

class Proposal {
  final String id;

  /// UID de l'utilisateur qui propose.
  final String fromUid;
  final String fromName;

  /// UID du propriétaire du livre / de la recette ciblée.
  final String toUid;
  final ProposalType type;

  /// Livre cible (obligatoire pour les deux types).
  final String bookId;

  /// Recette cible (uniquement pour type == annotation).
  final String? recipeId;

  /// Contenu de la proposition :
  ///   - annotation : {'text': String, 'annotation_type': String}
  ///   - recipe     : {'titre': String, 'raw_cooklang': String, ...}
  final Map<String, dynamic> content;
  final ProposalStatus status;
  final DateTime createdAt;
  final DateTime? resolvedAt;

  /// Commentaire optionnel du propriétaire lors de l'acceptation/rejet.
  final String? resolvedComment;

  const Proposal({
    required this.id,
    required this.fromUid,
    required this.fromName,
    required this.toUid,
    required this.type,
    required this.bookId,
    this.recipeId,
    required this.content,
    required this.status,
    required this.createdAt,
    this.resolvedAt,
    this.resolvedComment,
  });

  factory Proposal.fromFirestore(String id, Map<String, dynamic> data) {
    return Proposal(
      id: id,
      fromUid: data['from_uid'] as String,
      fromName: data['from_name'] as String,
      toUid: data['to_uid'] as String,
      type: ProposalType.values.firstWhere(
        (t) => t.name == (data['type'] as String),
        orElse: () => ProposalType.annotation,
      ),
      bookId: data['book_id'] as String,
      recipeId: data['recipe_id'] as String?,
      content: Map<String, dynamic>.from(data['content'] as Map),
      status: ProposalStatus.values.firstWhere(
        (s) => s.name == (data['status'] as String),
        orElse: () => ProposalStatus.pending,
      ),
      createdAt: (data['created_at'] as dynamic).toDate() as DateTime,
      resolvedAt: data['resolved_at'] != null
          ? (data['resolved_at'] as dynamic).toDate() as DateTime
          : null,
      resolvedComment: data['resolved_comment'] as String?,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'from_uid': fromUid,
      'from_name': fromName,
      'to_uid': toUid,
      'type': type.name,
      'book_id': bookId,
      'recipe_id': recipeId,
      'content': content,
      'status': status.name,
      'created_at': createdAt,
      'resolved_at': resolvedAt,
      'resolved_comment': resolvedComment,
    };
  }

  Proposal copyWith({
    ProposalStatus? status,
    DateTime? resolvedAt,
    String? resolvedComment,
  }) {
    return Proposal(
      id: id,
      fromUid: fromUid,
      fromName: fromName,
      toUid: toUid,
      type: type,
      bookId: bookId,
      recipeId: recipeId,
      content: content,
      status: status ?? this.status,
      createdAt: createdAt,
      resolvedAt: resolvedAt ?? this.resolvedAt,
      resolvedComment: resolvedComment ?? this.resolvedComment,
    );
  }
}
