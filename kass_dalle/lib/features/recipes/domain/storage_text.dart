/// Écriture du conseil de conservation dans le CookLang d'une recette.
///
/// La conservation se lit après tout le reste, dressage compris : c'est ce
/// qu'on fait du plat une fois le repas fini, ou ce qu'on relit trois jours
/// plus tard avant de le réchauffer. Les mêmes trois règles que le dressage
/// gouvernent ce fichier :
///
///  - le texte inséré est nettoyé du balisage CookLang, sinon un « @ » dans une
///    phrase fabriquerait un ingrédient fantôme qui remonterait dans l'index et
///    la liste de courses ;
///  - une seconde insertion **remplace** la précédente au lieu de l'empiler ;
///  - seule la section au titre exact est reconnue : une section
///    « Conservation » écrite à la main n'est jamais touchée.
library;

import 'plating_text.dart' show sanitizeForCooklang;
import 'storage_advice.dart';

/// Titre de la section insérée — sert aussi de repère pour la remplacer.
const String kStorageSectionTitle = 'Conservation et réchauffage';

/// Une section s'écrit `## Titre` ; l'éditeur visuel produit aussi `== Titre`.
final RegExp _sectionLine = RegExp(
  r'^\s*(?:#{2,}|={2,})\s+(.+?)\s*(?:={2,})?\s*$',
);

/// Construit les lignes de la section « Conservation et réchauffage ».
String buildStorageSection(StorageAdvice advice) {
  final lines = <String>['## $kStorageSectionTitle'];

  void addQuote(String label, String value) {
    final text = sanitizeForCooklang(value);
    if (text.isNotEmpty) lines.add('> $label : $text');
  }

  final resume = sanitizeForCooklang(advice.resume);
  if (resume.isNotEmpty) lines.add(resume);

  addQuote('Refroidissement', advice.refroidissement);

  final frigo = advice.refrigerateur;
  if (frigo.duree.trim().isNotEmpty) {
    final detail = [
      frigo.contenant,
      frigo.conseil,
    ].map(sanitizeForCooklang).where((s) => s.isNotEmpty).join(' ');
    addQuote(
      'Réfrigérateur',
      detail.isEmpty ? frigo.duree : '${frigo.duree}. $detail',
    );
  }

  final congel = advice.congelateur;
  if (congel != null && congel.duree.trim().isNotEmpty) {
    final detail = [
      congel.contenant,
      congel.conseil,
    ].map(sanitizeForCooklang).where((s) => s.isNotEmpty).join(' ');
    addQuote(
      'Congélateur',
      detail.isEmpty ? congel.duree : '${congel.duree}. $detail',
    );
  } else if ((advice.congelationDeconseillee ?? '').trim().isNotEmpty) {
    addQuote('Congélation déconseillée', advice.congelationDeconseillee!);
  }

  final reheat = advice.rechauffage;
  if (!reheat.isEmpty) {
    final detail = [
      reheat.summary,
      reheat.conseil,
    ].map(sanitizeForCooklang).where((s) => s.isNotEmpty).join('. ');
    addQuote('Réchauffage', detail);
  }

  for (final item in advice.aAjouterAuDernierMoment) {
    addQuote('À ajouter au dernier moment', item);
  }

  for (final item in advice.signesDAlerte) {
    addQuote('Ne plus consommer si', item);
  }

  return lines.join('\n');
}

/// Vrai si le CookLang porte déjà une section de conservation.
bool hasStorageSection(String cooklang) =>
    removeStorageSection(cooklang).length < cooklang.length;

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

/// Retourne le CookLang complet, section de conservation à jour.
String applyStorageSection(String cooklang, StorageAdvice advice) {
  final base = removeStorageSection(cooklang);
  final section = buildStorageSection(advice);
  if (base.trim().isEmpty) return section;
  return '$base\n\n$section';
}
