import 'user_profile.dart';

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

  /// Le nom que cette personne a choisi de montrer à la famille.
  ///
  /// `null` tant que personne ne l'a écrit : le compte s'annonce alors sous le
  /// prénom de son compte Google. Le nom Google, lui, revient à chaque
  /// connexion — le remplacer ici ne tiendrait pas.
  final String? preferredName;

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
    this.preferredName,
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

  /// Peut modifier ou supprimer la recette créée par [createdBy].
  ///
  /// Miroir de la règle `recipes` de `firestore.rules` : on ne modifie que ses
  /// propres recettes, éditeur compris ; l'administrateur agit comme le
  /// créateur. Un `created_by` vide n'appartient à personne.
  bool canModifyRecipe(String createdBy) =>
      canRead && (isAdmin || (createdBy.isNotEmpty && createdBy == uid));

  /// Peut modifier ou supprimer le livre créé par [createdBy] — et donc
  /// changer sa couverture.
  ///
  /// Miroir de la règle `books` : il faut en plus le rôle éditeur, comme pour
  /// créer un livre.
  bool canModifyBook(String createdBy) =>
      canEdit && (isAdmin || (createdBy.isNotEmpty && createdBy == uid));

  /// Le nom sous lequel les autres membres voient cette personne — et donc sa
  /// bibliothèque.
  ///
  /// Les comptes Google portent des noms d'état civil, souvent avec le nom de
  /// famille que toute la maisonnée partage. « Livres de Frédéric Kassbi » et
  /// « Livres de Marie Kassbi » ne se distinguent qu'au deuxième mot. Le nom
  /// préféré rend l'usage : Fred, Marie.
  String get displayedName {
    final chosen = preferredName?.trim() ?? '';
    if (chosen.isNotEmpty) return chosen;
    return defaultPreferredName(displayName, email);
  }

  /// La valeur par défaut du nom préféré : le prénom du compte Google.
  ///
  /// Le prénom est le premier mot du nom affiché. Un nom vide se rabat sur la
  /// partie locale de l'adresse plutôt que sur une chaîne vide : un membre sans
  /// nom du tout rendrait les en-têtes de bibliothèque illisibles.
  static String defaultPreferredName(String displayName, String email) {
    final words = displayName
        .trim()
        .split(' ')
        .map((w) => w.trim())
        .where((w) => w.isNotEmpty);
    if (words.isNotEmpty) return words.first;
    final local = email.split('@').first.trim();
    return local.isEmpty ? UserProfile.fallbackName : local;
  }

  factory AppUser.fromFirestore(Map<String, dynamic> data) {
    return AppUser(
      uid: data['uid'] as String,
      email: data['email'] as String,
      displayName: data['display_name'] as String,
      preferredName: data['preferred_name'] as String?,
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
      'preferred_name': preferredName,
      'photo_url': photoUrl,
      'free_recipe_cover_url': freeRecipeCoverUrl,
      'role': role.name,
      'created_at': createdAt,
      'last_seen_at': lastSeenAt,
      'is_revoked': isRevoked,
    };
  }

  AppUser copyWith({
    String? preferredName,
    UserRole? role,
    bool? isRevoked,
    DateTime? lastSeenAt,
    String? freeRecipeCoverUrl,
  }) {
    return AppUser(
      uid: uid,
      email: email,
      displayName: displayName,
      preferredName: preferredName ?? this.preferredName,
      photoUrl: photoUrl,
      freeRecipeCoverUrl: freeRecipeCoverUrl ?? this.freeRecipeCoverUrl,
      role: role ?? this.role,
      createdAt: createdAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      isRevoked: isRevoked ?? this.isRevoked,
    );
  }
}
