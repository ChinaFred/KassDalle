import 'dart:math' as math;

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
    this.maxBudgetUsd,
    this.maxBudgetPerWindowUsd,
    this.budgetUsdToEur,
    this.usdToEur,
    this.existingBook,
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

  /// Plafond le plus haut que le serveur appliquera, en dollars : 4 € par
  /// tranche, convertis au taux de la facture (4 $ par tranche sans taux).
  ///
  /// Absent d'une réponse d'avant v0.23.13 : l'écran ne borne alors pas la
  /// saisie, et le serveur ramène le plafond au maximum.
  final double? maxBudgetUsd;

  /// Maximum par tranche, en dollars, tel que le serveur l'applique. L'écran
  /// l'affiche plutôt que d'écrire « 4 € » en dur : un changement côté serveur
  /// s'y reflète.
  final double? maxBudgetPerWindowUsd;

  /// Taux qui a servi au maximum : présent seulement s'il est plausible. Le
  /// plafond se saisit alors en euros ; sans lui, en dollars.
  final double? budgetUsdToEur;

  /// Taux dollar → euro relevé sur la facturation, ou null.
  final double? usdToEur;

  /// Un livre de l'utilisateur qui semble être celui-ci, ou null. L'écran
  /// n'en tient compte qu'en mode « nouveau livre ».
  final ExistingBookMatch? existingBook;

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
      maxBudgetUsd: (map['maxBudgetUsd'] as num?)?.toDouble(),
      maxBudgetPerWindowUsd: (map['maxBudgetPerWindowUsd'] as num?)?.toDouble(),
      budgetUsdToEur: (map['budgetUsdToEur'] as num?)?.toDouble(),
      usdToEur: (map['usdToEur'] as num?)?.toDouble(),
      existingBook: ExistingBookMatch.fromMap(map['existingBook']),
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

/// Le livre déjà en bibliothèque que le serveur a rapproché du fichier lu
/// (`existingBook` de `analyzeBookFileFn`).
///
/// [sameFile] : même empreinte SHA-256 qu'un livre importé depuis un fichier.
/// [sameTitle] : titre normalisé égal et auteurs compatibles.
class ExistingBookMatch {
  const ExistingBookMatch({
    required this.id,
    required this.titre,
    this.auteur,
    this.sameFile = false,
    this.sameTitle = false,
    this.importedAt,
  });

  final String id;
  final String titre;
  final String? auteur;
  final bool sameFile;
  final bool sameTitle;

  /// Date du premier import du même fichier, quand le serveur la connaît.
  final DateTime? importedAt;

  /// Lecture tolérante : absent, nul, ou sans identifiant vaut « aucun ».
  static ExistingBookMatch? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final titre = raw['titre'];
    final auteur = raw['auteur'];
    final importedAt = raw['importedAt'];
    return ExistingBookMatch(
      id: id,
      titre: titre is String ? titre : '',
      auteur: auteur is String && auteur.trim().isNotEmpty ? auteur : null,
      sameFile: raw['sameFile'] == true,
      sameTitle: raw['sameTitle'] == true,
      importedAt: importedAt is String
          ? DateTime.tryParse(importedAt)?.toLocal()
          : null,
    );
  }

  /// « Ce livre semble déjà dans votre bibliothèque : Le Riz Jaune, Thaï
  /// Liou. », sans l'auteur quand il est inconnu.
  String get warningLabel {
    final who = auteur == null ? titre : '$titre, $auteur';
    return 'Ce livre semble déjà dans votre bibliothèque : $who.';
  }

  /// « Ce fichier a déjà été importé le 12/03/2026. » quand l'empreinte
  /// correspond, null sinon. Sans date connue, la phrase s'arrête au verbe.
  String? get sameFileLabel {
    if (!sameFile) return null;
    final date = importedAt;
    return date == null
        ? 'Ce fichier a déjà été importé.'
        : 'Ce fichier a déjà été importé le '
              '${DateFormat('dd/MM/yyyy').format(date)}.';
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

/// La devise dans laquelle le plafond d'un import se saisit et s'affiche.
///
/// En euros quand le serveur a fourni un taux plausible (`budgetUsdToEur`),
/// en dollars sinon. Le serveur reçoit toujours des dollars : la conversion
/// se fait ici, avec le même taux que celui du maximum.
class BudgetCurrency {
  const BudgetCurrency._(this.usdToEur);

  factory BudgetCurrency.of(BookImportAnalysis analysis) {
    final rate = analysis.budgetUsdToEur;
    return BudgetCurrency._(rate != null && rate > 0 ? rate : null);
  }

  /// Taux euros par dollar, ou null : saisie en dollars.
  final double? usdToEur;

  bool get isEuro => usdToEur != null;

  /// « € » ou « $ ».
  String get symbol => isEuro ? '€' : '\$';

  /// Un montant en dollars, dans la devise de saisie.
  double fromUsd(double usd) => isEuro ? usd * usdToEur! : usd;

  /// Un montant saisi, en dollars pour le serveur.
  double toUsd(double amount) => isEuro ? amount / usdToEur! : amount;

  /// Un maximum dans la devise de saisie, arrondi au centime inférieur : le
  /// montant affiché ne dépasse jamais celui que le serveur appliquera.
  double maxFromUsd(double usd) =>
      (fromUsd(usd) * 100 + 1e-6).floorToDouble() / 100;

  /// Le plafond proposé dans la devise de saisie : arrondi à l'unité
  /// supérieure, sans dépasser le maximum.
  double suggestionFromUsd(double usd, double? maxUsd) {
    final value = fromUsd(usd).ceilToDouble();
    return maxUsd == null ? value : math.min(value, maxFromUsd(maxUsd));
  }
}

/// Le plafond saisi dépasse-t-il le maximum du serveur ?
///
/// Un centime de tolérance : le maximum est arrondi au centime, la saisie aussi.
bool budgetExceedsMax(double limitUsd, double? maxUsd) {
  if (maxUsd == null || maxUsd <= 0) return false;
  return limitUsd > maxUsd + 0.005;
}

/// Le plafond proposé, tel qu'il s'écrit dans le champ : sans décimale inutile.
String formatBudgetInput(double usd) {
  return usd == usd.roundToDouble()
      ? usd.toInt().toString()
      : usd.toStringAsFixed(2).replaceAll('.', ',');
}
