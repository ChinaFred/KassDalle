import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;

class PlatformUtils {
  PlatformUtils._();

  static bool get isMobile => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  static bool get isDesktop =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  static bool get isWeb => kIsWeb;

  static bool get hasCameraSupport => isMobile || kIsWeb;

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
}
