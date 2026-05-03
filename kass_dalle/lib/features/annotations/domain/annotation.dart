enum AnnotationType { note, tip, correction }

class Annotation {
  final String id;
  final String recipeId;
  final String uid;
  final String authorName;
  final String text;
  final AnnotationType type;
  final DateTime createdAt;
  final DateTime? updatedAt;

  const Annotation({
    required this.id,
    required this.recipeId,
    required this.uid,
    required this.authorName,
    required this.text,
    required this.type,
    required this.createdAt,
    this.updatedAt,
  });

  factory Annotation.fromFirestore(
    String id,
    String recipeId,
    Map<String, dynamic> data,
  ) {
    return Annotation(
      id: id,
      recipeId: recipeId,
      uid: data['uid'] as String? ?? '',
      authorName: data['author_name'] as String? ?? '',
      text: data['text'] as String? ?? '',
      type: AnnotationType.values.firstWhere(
        (t) => t.name == (data['type'] as String?),
        orElse: () => AnnotationType.note,
      ),
      createdAt: data['created_at'] != null
          ? (data['created_at'] as dynamic).toDate() as DateTime
          : DateTime.now(),
      updatedAt: data['updated_at'] != null
          ? (data['updated_at'] as dynamic).toDate() as DateTime
          : null,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'uid': uid,
      'author_name': authorName,
      'text': text,
      'type': type.name,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }
}
