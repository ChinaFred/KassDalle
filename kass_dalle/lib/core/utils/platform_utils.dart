import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show TargetPlatform, kIsWeb;

class PlatformUtils {
  PlatformUtils._();

  static bool get isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  static bool get isWeb => kIsWeb;

  /// Android natif, et lui seul : l'APK, pas le navigateur d'un téléphone.
  ///
  /// `!kIsWeb` passe en premier, et l'ordre n'est pas cosmétique : `dart:io`
  /// n'existe pas sur le web, où `Platform.isAndroid` lèverait. Le `&&`
  /// court-circuite avant d'y toucher — même construction que `isMobile`.
  ///
  /// Distinct de `isMobile`, qui couvre aussi iOS, et de `Platform.isAndroid`
  /// seul, qui répond vrai depuis un navigateur Android.
  static bool get isAndroidApp => !kIsWeb && Platform.isAndroid;

  /// Windows natif, l'application de bureau.
  static bool get isWindowsApp => !kIsWeb && Platform.isWindows;

  static bool get hasCameraSupport => isMobile || kIsWeb;

  /// Le système qui fait tourner l'application native, lu par `dart:io` ;
  /// `null` sur le web.
  ///
  /// Distinct de `defaultTargetPlatform`, que les tests remplacent (Android
  /// par défaut) : un choix de plugin natif suit le vrai système.
  static TargetPlatform? get hostPlatform {
    if (kIsWeb) return null;
    if (Platform.isAndroid) return TargetPlatform.android;
    if (Platform.isIOS) return TargetPlatform.iOS;
    if (Platform.isMacOS) return TargetPlatform.macOS;
    if (Platform.isWindows) return TargetPlatform.windows;
    if (Platform.isLinux) return TargetPlatform.linux;
    return TargetPlatform.fuchsia;
  }

  // ── Seuils de largeur ───────────────────────────────────────────────────
  //
  // Ces trois seuils étaient écrits en clair au fil des écrans — « 700 » dans
  // quatre fichiers, « wideBreakpoint + 100 » dans un cinquième. Trois nombres
  // dispersés, dont deux sans nom : le jour où l'un bouge, rien ne dit lesquels
  // devaient bouger avec lui.
  //
  // Ils restent DISTINCTS parce qu'ils répondent à des questions différentes.
  // Les regrouper ici ne les confond pas, ça les rend comparables.

  /// Largeur à partir de laquelle on utilise le layout large (side-by-side) :
  /// navigation latérale, écrans de planning.
  static const double wideBreakpoint = 800.0;

  /// Largeur en dessous de laquelle un écran de détail passe en présentation
  /// compacte (onglets empilés, barre d'action resserrée).
  static const double compactDetailBreakpoint = 700.0;

  /// Largeur à partir de laquelle une vignette de recette a la place d'afficher
  /// le raccourci galerie en plus du reste.
  static const double galleryShortcutBreakpoint = 900.0;

  /// Largeur d'un BLOC (lue sur `LayoutBuilder`, pas sur l'écran) sous
  /// laquelle ses éléments s'empilent au lieu de s'aligner : une ligne
  /// d'ingrédient, la barre de l'éditeur hybride, une carte du coach de
  /// dressage. Un bloc étroit peut vivre dans un écran large (colonne d'un
  /// panneau, dialogue).
  static const double narrowContentBreakpoint = 480.0;

  /// Largeur du panneau latéral d'un écran large : critères de recherche,
  /// métadonnées d'un brouillon, panneau du planning par lot.
  static const double sidePanelWidth = 320.0;

  /// Largeur maximale d'une colonne de contenu centrée (liste, formulaire),
  /// pour qu'elle ne s'étire pas sur tout un écran large.
  static const double maxContentWidth = 640.0;

  /// Hauteur disponible sous laquelle une barre d'actions n'est plus fixée
  /// en bas d'une fiche : elle suit le contenu en fin de défilement
  /// (paysage, texte agrandi, bandeaux), plutôt que de masquer la fiche.
  static const double pinnedActionBarMinHeight = 420.0;
}
