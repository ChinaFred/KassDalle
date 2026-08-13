/// Écriture du conseil de dressage dans le CookLang d'une recette.
///
/// Le conseil vit d'abord dans son onglet ; l'utilisateur peut décider de le
/// faire entrer dans la recette elle-même, avec les visuels de montage en
/// images flottantes. Deux règles gouvernent ce fichier :
///
///  - le texte inséré est nettoyé des caractères de balisage CookLang, sinon un
///    « @ » ou un « # » dans une phrase fabriquerait un ingrédient ou un
///    ustensile fantôme, qui remonterait ensuite dans l'index et la liste de
///    courses ;
///  - une seconde insertion remplace la section précédente au lieu de
///    l'empiler, faute de quoi régénérer un conseil trois fois donnerait trois
///    sections « Dressage » contradictoires dans la même recette.
library;

import 'plating_advice.dart';

/// Titre de la section insérée — sert aussi de repère pour la remplacer.
const String kPlatingSectionTitle = 'Dressage';

/// Une section s'écrit `## Titre` ; l'éditeur visuel produit aussi `== Titre`.
/// Les deux formes doivent être reconnues, sans quoi une seconde insertion
/// laisserait la première en place.
final RegExp _sectionLine = RegExp(r'^\s*(?:#{2,}|={2,})\s+(.+?)\s*(?:={2,})?\s*$');

/// Retire le balisage CookLang d'un texte destiné à une étape.
String sanitizeForCooklang(String value) {
  return value
      .replaceAll(RegExp(r'[@#~]'), '')
      .replaceAll(RegExp(r'[{}]'), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Construit les lignes de la section « Dressage ».
///
/// Les visuels alternent droite/gauche : deux images du même côté à la suite
/// créent une colonne de texte étranglée sur la largeur de lecture.
String buildPlatingSection(PlatingAdvice advice) {
  final lines = <String>['## $kPlatingSectionTitle'];

  final contenant = sanitizeForCooklang(advice.contenant);
  if (contenant.isNotEmpty) {
    lines.add('> $contenant');
  }

  var imageCount = 0;
  for (final step in advice.etapes) {
    final geste = sanitizeForCooklang(step.geste);
    if (geste.isEmpty) continue;
    final titre = sanitizeForCooklang(step.titre);
    lines.add(titre.isEmpty ? geste : '$titre : $geste');

    final url = step.imageUrl;
    if (url != null && url.isNotEmpty) {
      final side = imageCount.isEven ? 'right' : 'left';
      lines.add('![$side|40]($url)');
      imageCount += 1;
    }
  }

  for (final piege in advice.pieges) {
    final text = sanitizeForCooklang(piege);
    if (text.isNotEmpty) lines.add('> $text');
  }

  for (final touche in advice.derniereMinute) {
    final text = sanitizeForCooklang(touche);
    if (text.isNotEmpty) lines.add('> Au dernier moment : $text');
  }

  // Le résultat dressé clôt la section en pleine largeur : c'est la seule image
  // qu'on regarde pour elle-même, pas en regard d'un geste.
  final finalUrl = advice.finalImageUrl;
  if (finalUrl != null && finalUrl.isNotEmpty) {
    lines.add('![after]($finalUrl)');
  }

  return lines.join('\n');
}

/// Retire une section « Dressage » déjà présente, en conservant le reste.
String removePlatingSection(String cooklang) {
  final lines = cooklang.split('\n');
  final kept = <String>[];
  var skipping = false;

  for (final line in lines) {
    final match = _sectionLine.firstMatch(line);
    if (match != null) {
      final title = match.group(1)!.trim().toLowerCase();
      skipping = title == kPlatingSectionTitle.toLowerCase();
      if (skipping) continue;
    }
    if (!skipping) kept.add(line);
  }

  while (kept.isNotEmpty && kept.last.trim().isEmpty) {
    kept.removeLast();
  }
  return kept.join('\n');
}

/// Retourne le CookLang complet, section de dressage à jour.
String applyPlatingSection(String cooklang, PlatingAdvice advice) {
  final base = removePlatingSection(cooklang);
  final section = buildPlatingSection(advice);
  if (base.trim().isEmpty) return section;
  return '$base\n\n$section';
}
