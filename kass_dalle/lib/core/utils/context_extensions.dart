import '../theme/app_icon_size.dart';
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
///
/// Depuis Flutter 3.29, un SnackBar qui porte une action reste affiché tant
/// qu'on n'agit pas (`persist` vaut `action != null` par défaut) : sa durée est
/// ignorée et rien ne permet de le fermer (ticket #69). Les trois variantes
/// appliquent donc une seule règle, dans [_persists] et [_withAction] :
/// - avec une action, le message reste [_actionDuration] (8 s) et porte une
///   croix de fermeture ;
/// - avec un lecteur d'écran actif, un message à action reste jusqu'à ce que
///   l'utilisateur agisse ou le ferme, comme avant Flutter 3.29 ;
/// - sans action, la durée de la variante s'applique.
extension AppSnackBar on BuildContext {
  /// Durée d'un message qui porte une action : lire deux lignes, puis
  /// atteindre « Annuler » ou « Réessayer ». La croix permet de fermer avant.
  static const _actionDuration = Duration(seconds: 8);

  /// Un message à action ne persiste qu'avec un lecteur d'écran actif.
  bool _persists(SnackBarAction? action) =>
      action != null && MediaQuery.accessibleNavigationOf(this);

  /// Affiche un SnackBar neutre — information, pas verdict.
  void showSnackBar(
    String message, {
    Duration? duration,
    SnackBarAction? action,
  }) {
    ScaffoldMessenger.of(this).showSnackBar(
      SnackBar(
        content: Text(message),
        duration:
            duration ??
            (action == null ? const Duration(seconds: 3) : _actionDuration),
        action: action,
        persist: _persists(action),
        showCloseIcon: action != null,
      ),
    );
  }

  /// Affiche un SnackBar de succès : fond secondaire, coche, durée courte
  /// (deux secondes ; huit avec une [action]).
  void showSuccessSnackBar(String message, {SnackBarAction? action}) {
    final scheme = Theme.of(this).colorScheme;
    _showTinted(
      message: message,
      icon: Icons.check_circle_outline,
      background: scheme.secondaryContainer,
      foreground: scheme.onSecondaryContainer,
      duration: action == null ? const Duration(seconds: 2) : _actionDuration,
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
      duration: action == null ? const Duration(seconds: 4) : _actionDuration,
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
        // Le libellé de l'action prend la couleur du texte : la couleur par
        // défaut (`inversePrimary`) manque de contraste sur ces fonds clairs.
        action: action == null
            ? null
            : SnackBarAction(
                label: action.label,
                onPressed: action.onPressed,
                textColor: foreground,
              ),
        persist: _persists(action),
        showCloseIcon: action != null,
        closeIconColor: foreground,
        content: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: foreground, size: AppIconSize.small),
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
