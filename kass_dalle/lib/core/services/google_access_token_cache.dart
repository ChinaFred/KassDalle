/// Cache en mémoire d'un jeton d'accès Google (Agenda, Tasks), lié au compte
/// Firebase qui l'a obtenu.
///
/// Sans ce lien, un second compte connecté sur le même appareil dans l'heure
/// réutilisait le jeton du premier : ses événements partaient dans l'agenda
/// du premier compte, et la liste des agendas affichée était la sienne.
///
/// Deux protections, l'une sans l'autre ne suffit pas :
///  - [read] ne rend le jeton qu'au compte qui l'a obtenu, ce qui couvre une
///    déconnexion qui ne passe pas par l'application (révocation, session
///    expirée, changement de compte dans la fenêtre Google) ;
///  - [clearAll], appelé par `AuthRepository.signOut`, vide tous les caches à
///    la déconnexion.
///
/// Rien n'est écrit sur l'appareil ni envoyé au serveur.
class GoogleAccessTokenCache {
  /// Durée pendant laquelle un jeton est gardé (un jeton Google vaut ~1 h).
  final Duration lifetime;

  /// Marge avant la fin de [lifetime] où le jeton n'est plus rendu.
  final Duration margin;

  final DateTime Function() _now;

  String? _token;
  String? _uid;
  DateTime? _expiry;

  static final List<GoogleAccessTokenCache> _all = [];

  GoogleAccessTokenCache({
    this.lifetime = const Duration(minutes: 55),
    this.margin = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    _all.add(this);
  }

  /// Le jeton gardé pour [uid], ou `null` : aucun jeton, jeton d'un autre
  /// compte, compte inconnu (`null`), ou jeton trop proche de son échéance.
  /// Un jeton lu après son échéance est effacé.
  String? read(String? uid) {
    final token = _token;
    final expiry = _expiry;
    if (token == null || expiry == null || uid == null || uid != _uid) {
      return null;
    }
    if (!_now().isBefore(expiry.subtract(margin))) {
      clear();
      return null;
    }
    return token;
  }

  /// Garde [token] pour [uid]. Sans compte connu, rien n'est gardé : le jeton
  /// sert à l'appel en cours, et le suivant en redemande un.
  void store(String? uid, String token) {
    if (uid == null || uid.isEmpty) {
      clear();
      return;
    }
    _token = token;
    _uid = uid;
    _expiry = _now().add(lifetime);
  }

  /// Oublie le jeton.
  void clear() {
    _token = null;
    _uid = null;
    _expiry = null;
  }

  /// Vide tous les caches de jeton Google de l'application.
  static void clearAll() {
    for (final cache in _all) {
      cache.clear();
    }
  }
}
