import 'package:flutter/material.dart';

/// Extensions pratiques sur [BuildContext] pour réduire le boilerplate
/// d'affichage des SnackBars (150+ callsites dans l'application).
///
/// Les trois variantes ne se distinguaient que par leur durée d'affichage :
/// 2 secondes pour un succès, 4 pour une erreur, même fond et même texte.
/// Un enregistrement raté ressemblait donc trait pour trait à un
/// enregistrement réussi — la durée est une différence que personne ne mesure.
/// Chaque variante porte maintenant sa couleur et son icône, prises du thème
/// pour rester lisibles en clair comme en sombre.
extension AppSnackBar on BuildContext {
  /// Affiche un SnackBar neutre — information, pas verdict.
  void showSnackBar(
    String message, {
    Duration duration = const Duration(seconds: 3),
    SnackBarAction? action,
  }) {
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(content: Text(message), duration: duration, action: action),
    );
  }

  /// Affiche un SnackBar de succès : fond secondaire, coche, durée courte.
  void showSuccessSnackBar(String message, {SnackBarAction? action}) {
    final scheme = Theme.of(this).colorScheme;
    _showTinted(
      message: message,
      icon: Icons.check_circle_outline,
      background: scheme.secondaryContainer,
      foreground: scheme.onSecondaryContainer,
      duration: const Duration(seconds: 2),
      action: action,
    );
  }

  /// Affiche un SnackBar d'erreur : fond d'erreur, icône, durée longue.
  void showErrorSnackBar(String message, {SnackBarAction? action}) {
    final scheme = Theme.of(this).colorScheme;
    _showTinted(
      message: message,
      icon: Icons.error_outline,
      background: scheme.errorContainer,
      foreground: scheme.onErrorContainer,
      duration: const Duration(seconds: 4),
      action: action,
    );
  }

  void _showTinted({
    required String message,
    required IconData icon,
    required Color background,
    required Color foreground,
    required Duration duration,
    SnackBarAction? action,
  }) {
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        backgroundColor: background,
        duration: duration,
        action: action,
        content: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: foreground, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(message, style: TextStyle(color: foreground)),
            ),
          ],
        ),
      ),
    );
  }
}
