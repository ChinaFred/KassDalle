import 'app_user.dart';

/// La part d'un compte que les autres membres voient : `user_profiles/{uid}`.
///
/// Projection de `users/{uid}` tenue par le serveur (`syncUserClaims`). Elle
/// ne porte ni l'adresse, ni le rôle, ni la révocation : `users/{uid}` ne se
/// lit plus que par son titulaire et par un administrateur.
class UserProfile {
  final String uid;
  final String displayName;
  final String? preferredName;
  final String? freeRecipeCoverUrl;

  const UserProfile({
    required this.uid,
    required this.displayName,
    this.preferredName,
    this.freeRecipeCoverUrl,
  });

  /// Le seul nom affiché pour une personne dont on ne connaît pas le nom :
  /// profil absent (compte antérieur à la v0.23.14 que la reprise « Profils
  /// publics » n'a pas traité, compte en attente), profil illisible, ou
  /// compte sans nom Google.
  static const fallbackName = 'Membre';

  /// Longueur maximale, en caractères, d'un nom (`display_name`,
  /// `preferred_name`). Les règles Firestore refusent au-delà sur
  /// `users/{uid}`, et le serveur tronque à la recopie dans le profil public
  /// (`publicProfileFrom`, `MAX_NAME_LENGTH`).
  static const maxNameLength = 60;

  /// [value] coupé à [maxNameLength] unités UTF-16, sans couper un caractère
  /// en deux. Les règles Firestore (`string.size()`) comptent en unités
  /// UTF-16 : un emoji y vaut 2. Couper par point de code laisserait passer
  /// jusqu'à 120 unités, que les règles refuseraient.
  static String truncateName(String value) {
    if (value.length <= maxNameLength) return value;
    var end = maxNameLength;
    final last = value.codeUnitAt(end - 1);
    // Une moitié haute de paire de substitution ne reste pas seule.
    if (last >= 0xD800 && last <= 0xDBFF) end -= 1;
    return value.substring(0, end);
  }

  /// Le nom sous lequel les autres membres voient cette personne.
  ///
  /// Même règle que [AppUser.displayedName], sans l'adresse : le nom préféré,
  /// sinon le prénom du compte Google, sinon [fallbackName].
  String get displayedName {
    final chosen = preferredName?.trim() ?? '';
    if (chosen.isNotEmpty) return chosen;
    return AppUser.defaultPreferredName(displayName, '');
  }

  factory UserProfile.fromFirestore(String uid, Map<String, dynamic> data) {
    final name = data['display_name'];
    final preferred = data['preferred_name'];
    final cover = data['free_recipe_cover_url'];
    return UserProfile(
      uid: uid,
      displayName: name is String ? name : '',
      preferredName: preferred is String ? preferred : null,
      freeRecipeCoverUrl: cover is String ? cover : null,
    );
  }

  /// Le profil du compte courant, tiré de son propre document.
  ///
  /// Un compte sans nom Google prend la partie locale de son adresse, comme
  /// dans [AppUser.displayedName] : le compte courant s'affiche sous le même
  /// nom partout, qu'on le lise par son document ou par ce profil.
  factory UserProfile.fromAppUser(AppUser user) => UserProfile(
    uid: user.uid,
    displayName: user.displayName.trim().isEmpty
        ? AppUser.defaultPreferredName('', user.email)
        : user.displayName,
    preferredName: user.preferredName,
    freeRecipeCoverUrl: user.freeRecipeCoverUrl,
  );
}
