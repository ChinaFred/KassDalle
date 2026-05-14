enum UserRole { admin, editor, reader }

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
  bool get canRead => !isRevoked;

  factory AppUser.fromFirestore(Map<String, dynamic> data) {
    return AppUser(
      uid: data['uid'] as String,
      email: data['email'] as String,
      displayName: data['display_name'] as String,
      photoUrl: data['photo_url'] as String?,
      freeRecipeCoverUrl: data['free_recipe_cover_url'] as String?,
      role: UserRole.values.firstWhere(
        (r) => r.name == (data['role'] as String? ?? 'reader'),
        orElse: () => UserRole.reader,
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
