/// Retrait de la section de conservation héritée du CookLang d'une recette.
///
/// Le conseil de conservation a d'abord été **recopié en fin de recette**, sous
/// une section « Conservation et réchauffage ». C'était une mauvaise place :
///
///  - le conseil est déjà lu là où la question se pose, dans le bandeau de la
///    fiche ouverte depuis un repas préparé à l'avance — la section n'en était
///    qu'un doublon ;
///  - le rendu CookLang numérote comme des étapes ce qui n'en est pas : le
///    titre de section et le résumé s'affichaient en « 6 » et « 7 », à la suite
///    de la préparation ;
///  - le conseil vit déjà sur la recette, dans `storage_advice`. L'écrire une
///    seconde fois dans le texte, c'était deux versions du même conseil qu'une
///    régénération pouvait laisser diverger.
///
/// Plus rien ne l'écrit. Ce qui reste ici sert à **retirer** la section des
/// recettes qui la portent encore. Seule la section au titre exact est
/// reconnue : une section « Conservation » écrite à la main n'est jamais
/// touchée.
library;

/// Titre de la section jadis insérée — sert de repère pour la retirer.
const String kStorageSectionTitle = 'Conservation et réchauffage';

/// Une section s'écrit `## Titre` ; l'éditeur visuel produit aussi `== Titre`.
final RegExp _sectionLine = RegExp(
  r'^\s*(?:#{2,}|={2,})\s+(.+?)\s*(?:={2,})?\s*$',
);

/// Vrai si le CookLang porte encore la section de conservation.
///
/// Cherche le titre, et non un écart de longueur avant/après retrait : le
/// retrait supprime aussi les lignes vides de fin, si bien qu'une comparaison
/// de longueurs déclarait « section présente » sur toute recette terminée par
/// un saut de ligne. C'est ce qui décide d'écrire ou non sur la recette.
bool hasStorageSection(String cooklang) {
  for (final line in cooklang.split('\n')) {
    final match = _sectionLine.firstMatch(line);
    if (match != null &&
        match.group(1)!.trim().toLowerCase() ==
            kStorageSectionTitle.toLowerCase()) {
      return true;
    }
  }
  return false;
}

/// Retire la section de conservation du CookLang, en conservant le reste.
String removeStorageSection(String cooklang) {
  final lines = cooklang.split('\n');
  final kept = <String>[];
  var skipping = false;

  for (final line in lines) {
    final match = _sectionLine.firstMatch(line);
    if (match != null) {
      final title = match.group(1)!.trim().toLowerCase();
      skipping = title == kStorageSectionTitle.toLowerCase();
      if (skipping) continue;
    }
    if (!skipping) kept.add(line);
  }

  while (kept.isNotEmpty && kept.last.trim().isEmpty) {
    kept.removeLast();
  }
  return kept.join('\n');
}
