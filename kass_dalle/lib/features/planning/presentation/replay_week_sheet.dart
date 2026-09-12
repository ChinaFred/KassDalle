import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/week_replay.dart';

/// Choisir une semaine passée à reprendre.
///
/// Chaque ligne dit ce que la semaine contenait : c'est ce qu'on veut revoir
/// avant de dire « celle-là ». La semaine en cours est en gras, les autres
/// sont datées ; toutes sont passées ou en cours, jamais le cycle qu'on
/// compose.
class ReplayWeekSheet extends StatelessWidget {
  final List<ReplayableWeek> weeks;
  final DateTime today;

  const ReplayWeekSheet({super.key, required this.weeks, required this.today});

  static String _label(ReplayableWeek w) =>
      'Semaine du ${DateFormat('d MMMM', 'fr').format(w.week.start)}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.7;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.4,
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(
              'Reprendre une semaine passée',
              style: theme.textTheme.titleMedium,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Ses repas remplissent les créneaux vides, jour de semaine pour '
              'jour de semaine. Aucun appel à l\'IA.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: weeks.length,
              itemBuilder: (_, i) {
                final w = weeks[i];
                final current = w.week.contains(today);
                return ListTile(
                  leading: Icon(
                    Icons.history,
                    color: current ? theme.colorScheme.primary : null,
                  ),
                  title: Text(
                    _label(w),
                    style: TextStyle(
                      fontWeight: current ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                  subtitle: Text(
                    w.titres.join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: Text(
                    '${w.meals.length} repas',
                    style: theme.textTheme.bodySmall,
                  ),
                  onTap: () => Navigator.pop(context, w),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
