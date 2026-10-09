/// Conseil de conservation et de réchauffage d'une recette.
///
/// Produit une fois par recette et stocké sur elle : il décrit le plat, pas un
/// repas. Les deux régimes — réfrigérateur et congélateur — sont donnés
/// ensemble, et c'est le planning qui retient celui qui s'applique au délai
/// réel entre la préparation et le service.
library;

/// Durée et conditionnement pour un régime de conservation donné.
class StorageWindow {
  /// Durée maximale conseillée pour ce plat (« 3 jours », « 2 mois »).
  final String duree;

  /// Contenant et conditionnement adaptés à ce plat.
  final String contenant;

  /// Ce qui se dégrade en premier, et comment le limiter.
  final String conseil;

  const StorageWindow({
    required this.duree,
    this.contenant = '',
    this.conseil = '',
  });

  factory StorageWindow.fromMap(Map<String, dynamic> data) => StorageWindow(
    duree: data['duree'] as String? ?? '',
    contenant: data['contenant'] as String? ?? '',
    conseil: data['conseil'] as String? ?? '',
  );
}

/// Remise en température : méthode, réglage, durée, et le geste qui compte.
class ReheatAdvice {
  final String methode;
  final String temperature;
  final String duree;
  final String conseil;

  const ReheatAdvice({
    this.methode = '',
    this.temperature = '',
    this.duree = '',
    this.conseil = '',
  });

  factory ReheatAdvice.fromMap(Map<String, dynamic> data) => ReheatAdvice(
    methode: data['methode'] as String? ?? '',
    temperature: data['temperature'] as String? ?? '',
    duree: data['duree'] as String? ?? '',
    conseil: data['conseil'] as String? ?? '',
  );

  bool get isEmpty => methode.isEmpty && temperature.isEmpty && duree.isEmpty;

  /// Résumé d'une ligne, pour une puce de planning.
  String get summary {
    final parts = [
      methode,
      temperature,
      duree,
    ].where((s) => s.trim().isNotEmpty);
    return parts.join(' · ');
  }
}

class StorageAdvice {
  /// Une phrase : ce plat supporte-t-il d'attendre, et à quelles conditions.
  final String resume;

  /// Refroidissement propre à ce plat avant la mise au froid.
  final String refroidissement;

  final StorageWindow refrigerateur;

  /// Null quand le plat ne se congèle pas sans se dégrader.
  final StorageWindow? congelateur;

  /// Pourquoi la congélation est déconseillée, quand [congelateur] est null.
  final String? congelationDeconseillee;

  final ReheatAdvice rechauffage;

  /// Ce qu'il vaut mieux ajouter au dernier moment que conserver.
  final List<String> aAjouterAuDernierMoment;

  /// Signes qu'il ne faut plus le manger.
  final List<String> signesDAlerte;

  final String provider;
  final String model;
  final DateTime? generatedAt;

  const StorageAdvice({
    this.resume = '',
    this.refroidissement = '',
    this.refrigerateur = const StorageWindow(duree: ''),
    this.congelateur,
    this.congelationDeconseillee,
    this.rechauffage = const ReheatAdvice(),
    this.aAjouterAuDernierMoment = const [],
    this.signesDAlerte = const [],
    this.provider = '',
    this.model = '',
    this.generatedAt,
  });

  static List<String> _stringList(dynamic raw) {
    if (raw is! List) return const [];
    return raw
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  static DateTime? _date(dynamic raw) {
    if (raw is String) return DateTime.tryParse(raw);
    // Timestamp Firestore : lu via son `toDate()` sans importer le type ici.
    try {
      final dynamic candidate = raw;
      final value = candidate?.toDate();
      return value is DateTime ? value : null;
    } catch (_) {
      // Forme inconnue : la date n'est qu'un affichage, elle ne vaut pas
      // d'échec de lecture du conseil lui-même.
      return null;
    }
  }

  factory StorageAdvice.fromMap(Map<String, dynamic> data) {
    final congelateurRaw = data['congelateur'];
    return StorageAdvice(
      resume: data['resume'] as String? ?? '',
      refroidissement: data['refroidissement'] as String? ?? '',
      refrigerateur: StorageWindow.fromMap(
        Map<String, dynamic>.from(
          (data['refrigerateur'] as Map?) ?? const <String, dynamic>{},
        ),
      ),
      congelateur: congelateurRaw is Map
          ? StorageWindow.fromMap(Map<String, dynamic>.from(congelateurRaw))
          : null,
      congelationDeconseillee: data['congelation_deconseillee'] as String?,
      rechauffage: ReheatAdvice.fromMap(
        Map<String, dynamic>.from(
          (data['rechauffage'] as Map?) ?? const <String, dynamic>{},
        ),
      ),
      aAjouterAuDernierMoment: _stringList(data['a_ajouter_au_dernier_moment']),
      signesDAlerte: _stringList(data['signes_d_alerte']),
      provider: data['provider'] as String? ?? '',
      model: data['model'] as String? ?? '',
      generatedAt: _date(data['generated_at']),
    );
  }

  bool get isFreezable => congelateur != null;
}

/// Ce que rend la demande d'un conseil de conservation
/// (`StorageRepository.ensure`).
///
/// Trois issues qu'un écran affiche différemment : le conseil, l'absence de
/// droit de le demander, ou une recette qui n'existe plus. Un simple `null`
/// confondait les deux dernières, et une recette supprimée s'affichait comme
/// « réservée au créateur ».
sealed class StorageAdviceLookup {
  const StorageAdviceLookup();
}

/// Le conseil, relu ou produit.
class StorageAdviceAvailable extends StorageAdviceLookup {
  final StorageAdvice advice;
  const StorageAdviceAvailable(this.advice);
}

/// Aucun conseil enregistré, et l'appelant n'est ni le créateur de la recette
/// ni un administrateur : il ne peut pas en demander.
class StorageAdviceReserved extends StorageAdviceLookup {
  const StorageAdviceReserved();
}

/// La recette n'existe pas (ou plus).
class StorageAdviceRecipeMissing extends StorageAdviceLookup {
  const StorageAdviceRecipeMissing();
}
