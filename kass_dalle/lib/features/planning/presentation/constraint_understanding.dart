import 'package:flutter/material.dart';

import '../../../core/theme/app_icon_size.dart';
import '../domain/planning_criteria.dart';

/// Ligne du texte non traduit, selon ce que le modèle du planning en a fait.
///
/// [modelStatus] est le `modelStatus` de la dernière génération de l'écran
/// (`ok`, `partial`, `failed`, `budget`, `skipped`), `null` hors génération.
/// « Transmis à l'IA » n'est vrai que si le modèle a répondu (`ok`,
/// `partial`) ; sans génération, la ligne décrit ce que fera la prochaine.
/// Le 21 octobre 2026, elle s'affichait alors qu'aucun modèle n'avait
/// répondu et que le code avait choisi les plats.
///
/// `skipped` : aucun créneau n'avait plus d'une recette possible comme plat,
/// entrée ou dessert (`needsModel`, `gemini/planning.ts`), zéro compris. Le
/// mode sans IA (« Autre suggestion ») rend aussi `skipped`, mais l'écran ne
/// garde pas ce statut : seule la génération le pose.
String untranslatedConstraintLabel(String rest, String? modelStatus) =>
    switch (modelStatus) {
      null || 'ok' || 'partial' => 'Transmis à l\'IA, non vérifié : « $rest »',
      'budget' =>
        'Non lu, l\'IA n\'a pas été appelée (plafond atteint) : « $rest »',
      'skipped' =>
        'Non lu, aucun choix à faire entre recettes, '
            'l\'IA n\'a pas été appelée : « $rest »',
      _ => 'Non lu, l\'IA n\'a pas répondu : « $rest »',
    };

/// Ce que Kass'Dalle a compris d'un texte libre des préférences, sous son
/// champ : « Compris : sans porc · 30 min max », puis « Transmis à l'IA, non
/// vérifié : « pas trop gras » ».
///
/// Rien ne se traduit ici : la traduction part au clic sur « Planifier avec
/// l'IA », pour les seuls textes modifiés. Un texte que le serveur n'a pas
/// encore lu le dit, sans rien promettre de plus.
class ConstraintUnderstandingLines extends StatelessWidget {
  /// Le texte du champ, tel qu'il est à l'écran.
  final String text;

  /// La traduction de ce texte exact ; `null` s'il n'a pas encore été lu.
  final ConstraintTranslation? translation;

  /// `modelStatus` de la dernière génération de l'écran ; `null` hors
  /// génération. Voir [untranslatedConstraintLabel].
  final String? modelStatus;

  const ConstraintUnderstandingLines({
    super.key,
    required this.text,
    this.translation,
    this.modelStatus,
  });

  @override
  Widget build(BuildContext context) {
    if (text.trim().isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final t = translation;
    final lines = <Widget>[];
    if (t == null) {
      lines.add(
        _line(
          theme,
          Icons.schedule_outlined,
          muted,
          'Sera lu au prochain « Planifier avec l\'IA ».',
          italic: true,
        ),
      );
    } else {
      final labels = t.labels;
      if (labels.isNotEmpty) {
        lines.add(
          _line(
            theme,
            Icons.check_circle_outline,
            theme.colorScheme.primary,
            'Compris : ${labels.join(' · ')}',
            maxLines: null,
          ),
        );
      }
      final rest = t.untranslated.trim();
      if (rest.isNotEmpty) {
        lines.add(
          _line(
            theme,
            Icons.info_outline,
            muted,
            untranslatedConstraintLabel(rest, modelStatus),
          ),
        );
      }
    }
    if (lines.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < lines.length; i++) ...[
            if (i > 0) const SizedBox(height: 2),
            lines[i],
          ],
        ],
      ),
    );
  }

  Widget _line(
    ThemeData theme,
    IconData icon,
    Color color,
    String label, {
    bool italic = false,
    int? maxLines = 3,
  }) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Icon(icon, size: AppIconSize.badge, color: color),
      const SizedBox(width: 4),
      Expanded(
        child: Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: color,
            fontStyle: italic ? FontStyle.italic : null,
          ),
          // Les critères compris se lisent en entier ; le texte transmis à
          // l'IA, souvent long, se coupe.
          maxLines: maxLines,
          overflow: maxLines == null ? null : TextOverflow.ellipsis,
        ),
      ),
    ],
  );
}
