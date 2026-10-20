import 'package:flutter/material.dart';

/// Couleurs de la syntaxe CookLang, partagées par tout l'éditeur : coloration
/// du texte ([CooklangSyntaxController]), puces, feuilles d'insertion, aide.
///
/// Chaque couleur garde la teinte d'origine de l'éditeur (bleu des
/// ingrédients, orange des ustensiles…), déclinée en deux tons HCT :
/// ton 40 en thème clair, ton 80 en thème sombre. Les valeurs ont été
/// calculées par `Hct.from(hue, chroma, 40 | 80)` de `material_color_utilities`
/// depuis les couleurs d'origine, notées en commentaire. Elles sont figées ici
/// pour ne pas ajouter de dépendance directe.
///
/// Le contraste de chaque couleur sur `surfaceContainerLowest` dépasse 4,5:1
/// dans les deux thèmes (test `editor_theme_targets_test.dart`).
@immutable
class CooklangPalette {
  const CooklangPalette._({
    required this.ingredient,
    required this.utensil,
    required this.timer,
    required this.section,
    required this.comment,
    required this.meta,
    required this.image,
    required this.continuation,
  });

  /// `@ingrédient` — d'origine 0xFF1565C0 (blue 800).
  final Color ingredient;

  /// `#ustensile` — d'origine 0xFFE64A19 (deep-orange 700).
  final Color utensil;

  /// `~minuteur` — d'origine 0xFF6A1B9A (purple 800).
  final Color timer;

  /// `## section` — d'origine 0xFF3949AB (indigo 600).
  final Color section;

  /// `-- commentaire` — d'origine 0xFF6A9955 (vert des commentaires VS Code).
  final Color comment;

  /// `>> métadonnée` — d'origine 0xFF9E9E9E (grey 500).
  final Color meta;

  /// `![position](url)` — d'origine 0xFF00838F (teal 700).
  final Color image;

  /// `+ ` suite d'étape — d'origine 0xFF607D8B (blue-grey 600).
  final Color continuation;

  /// Ton 40 : thème clair.
  static const light = CooklangPalette._(
    ingredient: Color(0xFF005DB7),
    utensil: Color(0xFFB02E00),
    timer: Color(0xFF843AB4),
    section: Color(0xFF4555B7),
    comment: Color(0xFF3D692B),
    meta: Color(0xFF5E5E5F),
    image: Color(0xFF006972),
    continuation: Color(0xFF466270),
  );

  /// Ton 80 : thème sombre.
  static const dark = CooklangPalette._(
    ingredient: Color(0xFFA9C7FF),
    utensil: Color(0xFFFFB5A0),
    timer: Color(0xFFE4B5FF),
    section: Color(0xFFBBC3FF),
    comment: Color(0xFFA2D489),
    meta: Color(0xFFC7C6C6),
    image: Color(0xFF75D5E2),
    continuation: Color(0xFFADCBDA),
  );

  /// Toutes les couleurs, pour les tests.
  List<Color> get all => [
    ingredient,
    utensil,
    timer,
    section,
    comment,
    meta,
    image,
    continuation,
  ];

  static CooklangPalette of(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;

  /// La palette du thème courant.
  static CooklangPalette ofContext(BuildContext context) =>
      of(Theme.of(context).brightness);
}
