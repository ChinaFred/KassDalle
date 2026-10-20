import 'package:flutter/material.dart';

/// Côté minimal d'une cible tactile : 48 px, le seuil de Material et
/// d'Android (iOS demande 44).
const double kMinTapTarget = 48;

/// Enveloppe cliquable d'une petite pastille (note, annotations, identifiant).
///
/// La pastille garde son dessin. Seule la zone d'appui grandit, jusqu'à
/// 48 × 48 px, centrée sur elle. L'infobulle et le lecteur d'écran disent la
/// même chose : ce que montre la pastille, puis ce que fait l'appui. Le contenu
/// dessiné (chiffres, icônes) n'est pas lu une seconde fois.
class TappablePill extends StatelessWidget {
  const TappablePill({
    super.key,
    required this.label,
    required this.onTap,
    required this.child,
    this.tooltip,
    this.customBorder = const StadiumBorder(),
  });

  /// Texte lu par le lecteur d'écran.
  final String label;

  /// Infobulle ; [label] quand elle est absente.
  final String? tooltip;

  final VoidCallback onTap;

  /// Forme de l'effet d'encre.
  final ShapeBorder customBorder;

  /// La pastille telle qu'elle est dessinée.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? label,
      excludeFromSemantics: true,
      child: Semantics(
        button: true,
        label: label,
        child: InkWell(
          customBorder: customBorder,
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minWidth: kMinTapTarget,
              minHeight: kMinTapTarget,
            ),
            child: Center(
              widthFactor: 1,
              heightFactor: 1,
              child: ExcludeSemantics(child: child),
            ),
          ),
        ),
      ),
    );
  }
}
