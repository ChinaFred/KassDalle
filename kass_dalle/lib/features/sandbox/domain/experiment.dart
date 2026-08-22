import 'package:flutter/widgets.dart';

/// Descripteur d'une expérience du bac à sable.
///
/// Le bac à sable est isolé du reste de l'application : il lit et appelle son
/// code, il n'en modifie aucune ligne. Voir la section « Bac à sable » de
/// `CLAUDE.md`.
@immutable
class Experiment {
  /// Identifiant stable, celui qui apparaît dans l'URL
  /// (`/admin/sandbox/<id>`). Il ne change pas : un lien partagé doit continuer
  /// d'ouvrir la même expérience.
  final String id;

  final String title;

  /// Ce que l'expérience cherche à établir, en une phrase.
  final String subtitle;

  final IconData icon;

  /// Construit l'écran de l'expérience. Une fonction et non un `Widget` :
  /// l'écran ne doit exister que lorsqu'on ouvre l'expérience.
  final WidgetBuilder builder;

  const Experiment({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.builder,
  });
}
