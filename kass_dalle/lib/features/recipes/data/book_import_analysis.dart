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

  /// Nombre d'imports passés qui ont servi à la mesure.
  final int referenceScans;

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
