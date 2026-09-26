import 'package:intl/intl.dart';

/// Ce que le serveur a lu d'un livre avant son import.
///
/// Importer un livre entier déclenche autant d'imports de page qu'il a de
/// tranches, et chacun est facturé. L'écran de confirmation montre ces chiffres
/// avant que le premier ne parte.
class BookImportAnalysis {
  const BookImportAnalysis({
    required this.kind,
    required this.sizeBytes,
    required this.windows,
    this.pages,
    this.characters,
    this.titre,
    this.auteur,
    this.estimatedCostUsd,
    this.costPerWindowUsd,
    this.referenceScans = 0,
    this.referenceKind,
    this.suggestedBudgetUsd,
    this.usdToEur,
  });

  /// `pdf`, `epub` ou `docx`.
  final String kind;
  final int sizeBytes;

  /// Nombre de pages, pour un PDF.
  final int? pages;

  /// Nombre de caractères, pour un texte (EPUB, Word).
  final int? characters;

  /// Nombre de jobs d'import que le livre va créer.
  final int windows;

  final String? titre;
  final String? auteur;

  /// Coût estimé de l'import entier, en dollars. Absent quand aucun import
  /// précédent ne permet de le mesurer : l'écran le dit, il n'invente rien.
  final double? estimatedCostUsd;

  /// Coût moyen mesuré d'un import de page, en dollars.
  final double? costPerWindowUsd;

  /// Nombre de livres ou de pages scannées qui ont servi à la mesure.
  final int referenceScans;

  /// Ce que la mesure a porté : `books` (des livres déjà importés, coût mesuré
  /// par tranche), `pages` (des pages scannées, faute de livre), ou null.
  final String? referenceKind;

  /// Plafond proposé pour cet import, en dollars.
  ///
  /// Une décision du serveur, pas une mesure : elle existe même quand aucune
  /// estimation n'est possible. L'utilisateur la lit et la règle.
  final double? suggestedBudgetUsd;

  /// Taux dollar → euro relevé sur la facturation, ou null.
  final double? usdToEur;

  factory BookImportAnalysis.fromMap(Map<String, dynamic> map) {
    return BookImportAnalysis(
      kind: map['kind'] as String? ?? 'pdf',
      sizeBytes: (map['sizeBytes'] as num?)?.toInt() ?? 0,
      pages: (map['pages'] as num?)?.toInt(),
      characters: (map['characters'] as num?)?.toInt(),
      windows: (map['windows'] as num?)?.toInt() ?? 0,
      titre: map['titre'] as String?,
      auteur: map['auteur'] as String?,
      estimatedCostUsd: (map['estimatedCostUsd'] as num?)?.toDouble(),
      costPerWindowUsd: (map['costPerWindowUsd'] as num?)?.toDouble(),
      referenceScans: (map['referenceScans'] as num?)?.toInt() ?? 0,
      referenceKind: map['referenceKind'] as String?,
      suggestedBudgetUsd: (map['suggestedBudgetUsd'] as num?)?.toDouble(),
      usdToEur: (map['usdToEur'] as num?)?.toDouble(),
    );
  }

  /// « 312 pages » ou « environ 180 000 caractères ».
  String get contentLabel {
    final format = NumberFormat.decimalPattern('fr_FR');
    final p = pages;
    if (p != null) return '${format.format(p)} page${p > 1 ? 's' : ''}';
    final c = characters ?? 0;
    // Arrondi aux milliers : le nombre exact d'un texte extrait ne dit rien.
    final rounded = (c / 1000).round() * 1000;
    return 'environ ${format.format(rounded == 0 ? c : rounded)} caractères';
  }

  /// « 42,5 Mo ».
  String get sizeLabel {
    final mb = sizeBytes / (1024 * 1024);
    return '${NumberFormat('0.#', 'fr_FR').format(mb)} Mo';
  }
}

/// Le plafond saisi sur l'écran de confirmation, en dollars.
///
/// Accepte la virgule comme le point : le champ est rempli par quelqu'un qui
/// écrit « 12,5 ». Rend null pour tout ce qui n'est pas un nombre strictement
/// positif — un plafond à zéro, négatif ou illisible n'est pas un plafond, et
/// l'import ne part pas sans en avoir un.
double? parseBudgetInput(String text) {
  final cleaned = text
      .trim()
      .replaceAll(RegExp(r'\s'), '')
      .replaceAll(',', '.');
  if (cleaned.isEmpty) return null;
  final value = double.tryParse(cleaned);
  if (value == null || !value.isFinite || value <= 0) return null;
  return value;
}

/// Le plafond proposé, tel qu'il s'écrit dans le champ : sans décimale inutile.
String formatBudgetInput(double usd) {
  return usd == usd.roundToDouble()
      ? usd.toInt().toString()
      : usd.toStringAsFixed(2).replaceAll('.', ',');
}
