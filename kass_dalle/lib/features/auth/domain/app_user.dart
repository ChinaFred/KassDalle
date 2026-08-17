/// Les rôles d'un compte, du plus large au plus étroit.
///
/// [pending] n'ouvre rien : c'est l'état d'un compte qui vient d'être créé et
/// qu'aucun administrateur n'a encore nommé. Il existe parce qu'être connecté
/// avec un compte Google donnait auparavant accès, dès la première seconde, à
/// toute la bibliothèque de la famille.
enum UserRole { admin, editor, reader, pending }

class AppUser {
  final String uid;
  final String email;
  final String displayName;
  final String? photoUrl;
  final String? freeRecipeCoverUrl;
  final UserRole role;
  final DateTime createdAt;
  final DateTime lastSeenAt;
  final bool isRevoked;

  const AppUser({
    required this.uid,
    required this.email,
    required this.displayName,
    this.photoUrl,
    this.freeRecipeCoverUrl,
    required this.role,
    required this.createdAt,
    required this.lastSeenAt,
    this.isRevoked = false,
  });

  bool get canEdit =>
      !isRevoked && (role == UserRole.editor || role == UserRole.admin);
  bool get isAdmin => !isRevoked && role == UserRole.admin;

  /// Le compte attend d'être nommé par un administrateur.
  bool get isPending => role == UserRole.pending;

  /// Le compte a été nommé et n'est pas révoqué — la condition d'entrée.
  ///
  /// Doit rester le miroir exact de `isApproved()` dans `firestore.rules` : un
  /// client plus permissif que les règles n'ouvre rien de plus, il affiche
  /// seulement des écrans vides et des erreurs de permission.
  bool get canRead => !isRevoked && role != UserRole.pending;

  factory AppUser.fromFirestore(Map<String, dynamic> data) {
    return AppUser(
      uid: data['uid'] as String,
      email: data['email'] as String,
      displayName: data['display_name'] as String,
      photoUrl: data['photo_url'] as String?,
      freeRecipeCoverUrl: data['free_recipe_cover_url'] as String?,
      // Un rôle absent ou inconnu vaut `pending`, jamais `reader` : c'est le
      // repli qui refuse. Un document mal formé est une anomalie, et une
      // anomalie ne doit pas ouvrir la bibliothèque.
      role: UserRole.values.firstWhere(
        (r) => r.name == (data['role'] as String? ?? ''),
        orElse: () => UserRole.pending,
      ),
      createdAt: (data['created_at'] as dynamic).toDate() as DateTime,
      lastSeenAt: (data['last_seen_at'] as dynamic).toDate() as DateTime,
      isRevoked: data['is_revoked'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'uid': uid,
      'email': email,
      'display_name': displayName,
      'photo_url': photoUrl,
      'free_recipe_cover_url': freeRecipeCoverUrl,
      'role': role.name,
      'created_at': createdAt,
      'last_seen_at': lastSeenAt,
      'is_revoked': isRevoked,
    };
  }

  AppUser copyWith({
    UserRole? role,
    bool? isRevoked,
    DateTime? lastSeenAt,
    String? freeRecipeCoverUrl,
  }) {
    return AppUser(
      uid: uid,
      email: email,
      displayName: displayName,
      photoUrl: photoUrl,
      freeRecipeCoverUrl: freeRecipeCoverUrl ?? this.freeRecipeCoverUrl,
      role: role ?? this.role,
      createdAt: createdAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      isRevoked: isRevoked ?? this.isRevoked,
    );
  }
}
