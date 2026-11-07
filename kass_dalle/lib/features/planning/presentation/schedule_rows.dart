import 'package:flutter/material.dart';

import '../../../core/theme/app_icon_size.dart';
import '../../groups/domain/family_group.dart';
import '../domain/planning_target.dart';

/// Les lignes d'une feuille qui pose un repas à une date : « Planning »,
/// « Date », « Heure de début », une ligne d'information. Extraites de la
/// feuille « Planifier » (`schedule_recipe_sheet.dart`) pour la boîte
/// « Poser dans le planning » de l'atelier repas, qui a la même forme.
///
/// Rien ici n'écrit : chaque ligne affiche une valeur et rend l'appui.

/// Une ligne qui ouvre un sélecteur : icône, libellé, valeur à droite,
/// chevron. [onTap] nul quand un menu englobant reçoit l'appui (ligne
/// « Planning » dans un `PopupMenuButton`).
class SchedulePickerRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;

  /// Libellé en bout de ligne à la place du chevron : « Changer ».
  final String? actionLabel;

  /// Hauteur minimale de la ligne. `null` : la hauteur du texte et de sa
  /// marge (la feuille « Planifier ») ; 48 pour une cible tactile pleine.
  final double? minHeight;

  /// Le focus à l'ouverture (grand écran : la ligne « Date » de la boîte
  /// « Poser dans le planning »).
  final bool autofocus;

  const SchedulePickerRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
    this.actionLabel,
    this.minHeight,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Row(
        children: [
          Icon(
            icon,
            size: AppIconSize.small,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Text(label, style: theme.textTheme.bodyMedium),
          const SizedBox(width: 12),
          // Un nom de groupe long se coupe au lieu de déborder.
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (actionLabel != null)
            Text(
              actionLabel!,
              style: theme.textTheme.labelLarge?.copyWith(
                color: onTap == null
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.primary,
              ),
            )
          else
            Icon(
              Icons.chevron_right,
              size: AppIconSize.small,
              color: theme.colorScheme.onSurfaceVariant,
            ),
        ],
      ),
    );
    if (minHeight != null) {
      row = ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight!),
        child: Align(alignment: Alignment.centerLeft, child: row),
      );
    }
    if (onTap == null) return row;
    // Lu « Date, mar. 12 nov. 2026, bouton » par un lecteur d'écran.
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        autofocus: autofocus,
        borderRadius: BorderRadius.circular(8),
        child: row,
      ),
    );
  }
}

/// Une ligne d'information, sans action : « Durée estimée », « Parts ».
class ScheduleInfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const ScheduleInfoRow({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Row(
        children: [
          Icon(
            icon,
            size: AppIconSize.small,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Text(label, style: theme.textTheme.bodyMedium),
          const Spacer(),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// La ligne « Planning » : « Mon planning », puis chaque groupe possédé
/// (« Planning du groupe · 4 membres »), dans un `PopupMenuButton`. À
/// n'afficher qu'à qui possède au moins un groupe : sans elle, le repas va
/// dans « Mon planning ».
class PlanningTargetRow extends StatelessWidget {
  final PlanningTarget target;
  final List<FamilyGroup> ownedGroups;
  final ValueChanged<PlanningTarget>? onSelected;
  final double? minHeight;

  const PlanningTargetRow({
    super.key,
    required this.target,
    required this.ownedGroups,
    required this.onSelected,
    this.minHeight,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<PlanningTarget>(
      tooltip: 'Choisir le planning',
      initialValue: target,
      enabled: onSelected != null,
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final t in [
          const PlanningTarget.personal(),
          for (final g in ownedGroups) PlanningTarget.ofGroup(g),
        ])
          PopupMenuItem(
            value: t,
            child: ListTile(
              leading: Icon(
                t.isGroup
                    ? Icons.groups_outlined
                    : Icons.calendar_today_outlined,
              ),
              title: Text(t.title),
              subtitle: t.subtitle == null ? null : Text(t.subtitle!),
              contentPadding: EdgeInsets.zero,
            ),
          ),
      ],
      child: SchedulePickerRow(
        icon: target.isGroup
            ? Icons.groups_outlined
            : Icons.calendar_today_outlined,
        label: 'Planning',
        value: target.title,
        minHeight: minHeight,
      ),
    );
  }
}
