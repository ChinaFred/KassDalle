import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/planning_week.dart';

/// La barre des semaines au-dessus de la liste : une puce par semaine, la
/// semaine lue en avant, les semaines passées en retrait.
///
/// La puce « Tout » rend la lecture d'avant : toutes les semaines chargées à
/// la suite. Sur grand écran, deux flèches avancent ou reculent d'une
/// semaine, au-delà des repas existants s'il le faut.
class PlanningWeekBar extends StatefulWidget {
  final List<PlanningWeek> weeks;
  final PlanningWeek selected;
  final bool allSelected;
  final DateTime today;
  final bool isWide;
  final ValueChanged<PlanningWeek> onSelect;
  final VoidCallback onSelectAll;

  const PlanningWeekBar({
    super.key,
    required this.weeks,
    required this.selected,
    required this.allSelected,
    required this.today,
    required this.isWide,
    required this.onSelect,
    required this.onSelectAll,
  });

  @override
  State<PlanningWeekBar> createState() => _PlanningWeekBarState();
}

class _PlanningWeekBarState extends State<PlanningWeekBar> {
  final _scroll = ScrollController();
  final _selectedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _reveal();
  }

  @override
  void didUpdateWidget(PlanningWeekBar old) {
    super.didUpdateWidget(old);
    if (old.selected != widget.selected ||
        old.allSelected != widget.allSelected) {
      _reveal();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Amène la puce sélectionnée dans la partie visible de la barre.
  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedKey.currentContext;
      if (ctx == null || !mounted) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
      );
    });
  }

  static String _label(PlanningWeek week) =>
      'Sem. du ${DateFormat('d MMM', 'fr').format(week.start)}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chips = <Widget>[
      ChoiceChip(
        label: const Text('Tout'),
        selected: widget.allSelected,
        onSelected: (_) => widget.onSelectAll(),
      ),
      for (final week in widget.weeks)
        ChoiceChip(
          key: !widget.allSelected && week == widget.selected
              ? _selectedKey
              : null,
          label: Text(
            _label(week),
            style: TextStyle(
              fontWeight: week.contains(widget.today)
                  ? FontWeight.bold
                  : FontWeight.normal,
              color: week.end.isBefore(widget.today)
                  ? theme.colorScheme.onSurfaceVariant
                  : null,
            ),
          ),
          selected: !widget.allSelected && week == widget.selected,
          onSelected: (_) => widget.onSelect(week),
        ),
    ];

    return Row(
      children: [
        if (widget.isWide)
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Semaine précédente',
            onPressed: () => widget.onSelect(widget.selected.previous),
          ),
        Expanded(
          child: SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                for (final chip in chips)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: chip,
                  ),
              ],
            ),
          ),
        ),
        if (widget.isWide)
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Semaine suivante',
            onPressed: () => widget.onSelect(widget.selected.next),
          ),
      ],
    );
  }
}

/// Un jour de la semaine lue sans repas : il est dit libre, et un jour à
/// venir propose d'y poser une recette.
class PlanningEmptyDayRow extends StatelessWidget {
  final bool isPast;
  final VoidCallback? onPick;

  const PlanningEmptyDayRow({super.key, required this.isPast, this.onPick});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Row(
        children: [
          Text(
            'Rien de prévu',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(
                alpha: isPast ? 0.5 : 1,
              ),
            ),
          ),
          if (!isPast && onPick != null) ...[
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: onPick,
              icon: const Icon(Icons.add),
              label: const Text('Choisir une recette'),
            ),
          ],
        ],
      ),
    );
  }
}
