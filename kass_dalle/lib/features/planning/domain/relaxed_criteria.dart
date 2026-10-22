/// Les critères que le serveur a relâchés pour choisir le plat d'un créneau.
///
/// La présélection (`gemini/planning.ts`, `RelaxedFilter`) relâche ses filtres
/// un par un quand aucune recette ne passe : la note personnelle, le « pas
/// deux fois dans le cycle », puis la fenêtre de variété. Elle le dit dans
/// `relaxed` de chaque liste classée — et depuis la v0.24.19 les préférences
/// comprises des textes (`wanted_proteins`, `wanted_starches`, `light`) et
/// la durée maximale (`max_duration`) ; depuis la v0.24.61, le style voulu
/// (`wanted_styles`), relâché en dernier. Le repas garde ces clés
/// (`relaxed_criteria`) pour que l'écart reste lisible après la validation,
/// dans la ligne d'origine du choix.
library;

/// Un critère relâché, par sa clé serveur.
enum RelaxedCriterion {
  inCycle('in_cycle', 'déjà servi dans ce cycle, faute d\'autre choix'),
  varietyWindow('variety_window', 'servi il y a peu, faute d\'autre choix'),
  rating('rating', 'aucune recette assez bien notée : critère de note relâché'),
  wantedProteins(
    'wanted_proteins',
    'protéine souhaitée introuvable, faute d\'autre choix',
  ),
  wantedStarches(
    'wanted_starches',
    'féculent souhaité introuvable, faute d\'autre choix',
  ),
  light('light', 'aucun plat léger possible, faute d\'autre choix'),
  maxDuration(
    'max_duration',
    'plus long que la durée demandée, faute d\'autre choix',
  ),
  wantedStyles(
    'wanted_styles',
    'style souhaité introuvable, faute d\'autre choix',
  );

  /// Clé écrite par le serveur et stockée sur le repas.
  final String key;

  /// Le constat, en minuscule : il suit l'origine du choix dans la ligne
  /// « Choisie par Kass'Dalle · déjà servi dans ce cycle, faute d'autre
  /// choix ». [sentence] le met en tête de ligne.
  final String phrase;

  const RelaxedCriterion(this.key, this.phrase);

  /// « Déjà servi dans ce cycle, faute d'autre choix ».
  String get sentence => phrase[0].toUpperCase() + phrase.substring(1);

  /// Le critère d'une clé, ou `null` pour une clé que cette version ne
  /// connaît pas : elle reste stockée telle quelle, sans s'afficher.
  static RelaxedCriterion? fromKey(String key) {
    for (final c in values) {
      if (c.key == key) return c;
    }
    return null;
  }

  /// Les critères connus de [keys], dans l'ordre du serveur, une fois chacun.
  static List<RelaxedCriterion> listFrom(Iterable<String> keys) {
    final out = <RelaxedCriterion>[];
    for (final k in keys) {
      final c = fromKey(k);
      if (c != null && !out.contains(c)) out.add(c);
    }
    return out;
  }
}

/// Lecture tolérante d'une liste de clés : chaînes non vides seulement.
List<String> relaxedKeysFrom(Object? raw) => [
  if (raw is List)
    for (final k in raw)
      if (k is String && k.isNotEmpty) k,
];
