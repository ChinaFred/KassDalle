/// Listes classées par le serveur, gardées en mémoire pour « Autre
/// suggestion ».
///
/// Le client ne note rien et ne pondère rien : l'ordre vient du serveur
/// (`gemini/planning.ts`, `preselect`). Il filtre seulement, au moment de
/// piocher, ce qui a changé depuis : une recette écartée, posée ailleurs, ou
/// sortie du corpus.
library;

/// Un candidat d'un créneau, avec les faits qui le justifient.
class RankedCandidate {
  final String recipeId;

  /// Faits produits par le serveur : protéine, durée, note, dernier service.
  final String why;

  /// Vrai si la recette n'est là que parce qu'un filtre s'est relâché.
  final bool repeat;

  /// « Écrite pour 4 parts, servie pour 6. », calculé par le serveur.
  final String? resizeReason;

  const RankedCandidate({
    required this.recipeId,
    this.why = '',
    this.repeat = false,
    this.resizeReason,
  });

  /// Lecture tolérante d'un élément de la réponse ; `null` sans identifiant.
  static RankedCandidate? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['recipeId'];
    if (id is! String || id.isEmpty) return null;
    final why = raw['why'];
    final resize = raw['resizeReason'];
    return RankedCandidate(
      recipeId: id,
      why: why is String ? why : '',
      repeat: raw['repeat'] == true,
      resizeReason: resize is String && resize.isNotEmpty ? resize : null,
    );
  }
}

/// Les listes classées d'un créneau.
class SlotRanking {
  final List<RankedCandidate> plats;
  final List<RankedCandidate> entrees;
  final List<RankedCandidate> desserts;

  /// Jour de préparation d'un créneau de réchauffage, calculé par le serveur.
  final DateTime? prepDate;

  const SlotRanking({
    this.plats = const [],
    this.entrees = const [],
    this.desserts = const [],
    this.prepDate,
  });

  static List<RankedCandidate> _list(Object? raw) => [
    if (raw is List)
      for (final item in raw) ?RankedCandidate.fromMap(item),
  ];

  factory SlotRanking.fromMap(Map<dynamic, dynamic> raw) {
    final prep = raw['prepDate'];
    return SlotRanking(
      plats: _list(raw['plats']),
      entrees: _list(raw['entrees']),
      desserts: _list(raw['desserts']),
      prepDate: prep is String ? DateTime.tryParse(prep) : null,
    );
  }
}

/// Premier candidat de [ranking] ni écarté, ni posé sur un autre créneau,
/// ni absent du corpus courant. `null` : liste épuisée.
///
/// Filtrage seulement — l'ordre vient du serveur. Une recette marquée
/// [RankedCandidate.repeat] reste admise si elle est posée ailleurs : le
/// serveur l'a déjà proposée faute d'autre choix.
RankedCandidate? nextRankedCandidate(
  List<RankedCandidate> ranking, {
  required Set<String> dismissed,
  required Set<String> usedElsewhere,
  required Set<String> availableIds,
}) {
  for (final c in ranking) {
    if (dismissed.contains(c.recipeId)) continue;
    if (!availableIds.contains(c.recipeId)) continue;
    if (usedElsewhere.contains(c.recipeId) && !c.repeat) continue;
    return c;
  }
  return null;
}
