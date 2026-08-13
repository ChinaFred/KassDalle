/// Le dressage comme texte autonome.
///
/// Le conseil a d'abord été recopié dans le CookLang de la recette. C'était une
/// erreur de place : le dressage n'est pas une étape de la recette, c'est ce
/// qu'on fait une fois qu'elle est finie. Fondu dans les étapes, il allongeait
/// la recette de gestes qu'on ne lit pas en cuisinant, et une régénération
/// réécrivait un contenu que l'utilisateur avait peut-être retouché.
///
/// Il vit donc dans son onglet, et ce fichier n'en produit qu'une version
/// texte — à copier, à coller, à envoyer. [removePlatingSection] reste pour
/// défaire les insertions faites par les versions précédentes.
library;

import 'plating_advice.dart';

/// Titre de la section insérée par les versions antérieures.
const String kPlatingSectionTitle = 'Dressage';

/// Une section s'écrit `## Titre` ; l'éditeur visuel produit aussi `== Titre`.
final RegExp _sectionLine = RegExp(r'^\s*(?:#{2,}|={2,})\s+(.+?)\s*(?:={2,})?\s*$');

/// Le conseil sous forme de texte lisible, prêt à être copié.
String buildPlatingText(PlatingAdvice advice, {String? recipeTitle}) {
  final lines = <String>[];

  final titre = recipeTitle?.trim();
  lines.add(
    titre == null || titre.isEmpty ? 'Dressage' : 'Dressage — $titre',
  );

  if (advice.resume.isNotEmpty) {
    lines
      ..add('')
      ..add(advice.resume);
  }

  if (advice.contenant.isNotEmpty) {
    lines
      ..add('')
      ..add('Contenant : ${advice.contenant}');
  }

  var numero = 0;
  for (final step in advice.etapes) {
    if (step.geste.trim().isEmpty) continue;
    numero += 1;
    if (numero == 1) lines.add('');
    lines.add(
      step.titre.trim().isEmpty
          ? '$numero. ${step.geste}'
          : '$numero. ${step.titre} — ${step.geste}',
    );
  }

  if (advice.pieges.isNotEmpty) {
    lines
      ..add('')
      ..add('Ce qui rate sur ce plat :');
    for (final piege in advice.pieges) {
      lines.add('- $piege');
    }
  }

  if (advice.derniereMinute.isNotEmpty) {
    lines
      ..add('')
      ..add('Au dernier moment :');
    for (final touche in advice.derniereMinute) {
      lines.add('- $touche');
    }
  }

  return lines.join('\n');
}

/// Vrai si le CookLang porte encore une section « Dressage » insérée autrefois.
bool hasPlatingSection(String cooklang) {
  return removePlatingSection(cooklang).length < cooklang.length;
}

/// Retire une section « Dressage » du CookLang, en conservant le reste.
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
