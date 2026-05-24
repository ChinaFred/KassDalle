import 'package:flutter/material.dart';

/// Extensions pratiques sur [BuildContext] pour réduire le boilerplate
/// d'affichage des SnackBars (50+ callsites dans l'application).
extension AppSnackBar on BuildContext {
  /// Affiche un SnackBar simple avec un message texte.
  void showSnackBar(
    String message, {
    Duration duration = const Duration(seconds: 3),
    SnackBarAction? action,
  }) {
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(content: Text(message), duration: duration, action: action),
    );
  }

  /// Affiche un SnackBar de succès (durée courte : 2 s).
  void showSuccessSnackBar(String message) =>
      showSnackBar(message, duration: const Duration(seconds: 2));

  /// Affiche un SnackBar d'erreur (durée longue : 4 s).
  void showErrorSnackBar(String message) =>
      showSnackBar(message, duration: const Duration(seconds: 4));
}
