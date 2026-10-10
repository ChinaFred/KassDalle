import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/planned_meal.dart';
import '../domain/planning_week.dart';

/// Le calendrier du planning : il choisit la semaine que l'écran affiche.
///
/// Ses colonnes partent du jour de démarrage du cycle — « V S D L M M J » pour
/// un cycle du vendredi. Une ligne de la grille est donc une semaine de
/// planning entière, et un appui sur n'importe quel jour la sélectionne d'un
/// coup. Une grille du lundi au dimanche coupait la semaine en deux lignes.
///
/// Replié, il ne montre que les sept jours de la semaine choisie ; déplié, le
/// mois entier. Sur un téléphone il s'ouvre replié : la liste des repas en
/// dessous est ce qu'on lit.
///
/// Rien n'est stocké : la semaine et le mois sont des positions de lecture.
/// Les pastilles se lisent dans des champs stockés — recette posée ou non,
/// date de préparation ou non — et ne rejouent aucune règle de créneau.
class PlanningPeriodCalendar extends StatelessWidget {
  /// Semaine choisie, affichée sous le calendrier.
  final PlanningWeek period;

  /// Jour de démarrage du cycle, 1 = lundi … 7 = dimanche.
  final int cycleStartDay;

  /// Tous les repas connus ; le calendrier les range lui-même par jour.
  final List<PlannedMeal> meals;

  /// Vrai quand le mois entier est affiché.
  final bool expanded;

  /// Mois affiché quand le calendrier est déplié.
  final DateTime month;

  /// Premier jour consultable : au-delà, l'historique n'est pas chargé et la
  /// navigation vers le passé s'arrête. Un mois vide faute de chargement
  /// ressemblerait à un mois sans repas.
  final DateTime earliestDay;

  final ValueChanged<PlanningWeek> onSelectPeriod;
  final ValueChanged<DateTime> onMonthChanged;

  /// Appui sur un jour du bandeau replié. Null : l'appui choisit la semaine,
  /// comme dans la grille.
  final ValueChanged<DateTime>? onTapDay;

  /// Plie ou déplie le calendrier. Null : il reste dans son état, sans
  /// bouton — c'est le cas du grand écran, où le mois est toujours affiché.
  final VoidCallback? onToggleExpanded;

  /// L'instant courant, injectable par les tests ; sinon l'horloge.
  final DateTime? now;

  const PlanningPeriodCalendar({
    super.key,
    required this.period,
    required this.cycleStartDay,
    required this.meals,
    required this.expanded,
    required this.month,
    required this.earliestDay,
    required this.onSelectPeriod,
    required this.onMonthChanged,
    this.onTapDay,
    this.onToggleExpanded,
    this.now,
  });

  /// Taille d'une case : 48 px, la cible tactile minimale, quand la largeur
  /// le permet.
  static const cellSize = 48.0;

  static DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);
  static DateTime monthOf(DateTime d) => DateTime(d.year, d.month);

  /// « Cette semaine », « Semaine prochaine », « Semaine dernière », ou la
  /// date de début pour les autres.
  static String periodTitle(
    PlanningWeek period, {
    required DateTime today,
    required int cycleStartDay,
  }) {
    final current = planningWeekOf(today, cycleStartDay: cycleStartDay);
    if (period == current) return 'Cette semaine';
    if (period == current.next) return 'Semaine prochaine';
    if (period == current.previous) return 'Semaine dernière';
    return 'Semaine du ${DateFormat('d MMMM', 'fr').format(period.start)}';
  }

  /// « ven. 9 – jeu. 15 oct. », le mois répété quand la semaine en change.
  static String periodRange(PlanningWeek period) {
    final sameMonth = period.start.month == period.end.month;
    final start = DateFormat(
      sameMonth ? 'EEE d' : 'EEE d MMM',
      'fr',
    ).format(period.start);
    final end = DateFormat('EEE d MMM', 'fr').format(period.end);
    return '$start – $end';
  }

  @override
  Widget build(BuildContext context) {
    final today = dayOf(now ?? DateTime.now());

    final byDay = <DateTime, List<PlannedMeal>>{};
    final prepByDay = <DateTime, int>{};
    for (final meal in meals) {
      (byDay[dayOf(meal.plannedAt)] ??= []).add(meal);
      final prep = meal.prepDate;
      if (prep != null) {
        final day = dayOf(prep);
        prepByDay[day] = (prepByDay[day] ?? 0) + 1;
      }
    }

    final weeks = expanded
        ? planningWeeksCovering(month, cycleStartDay: cycleStartDay)
        : [period];

    final grid = LayoutBuilder(
      builder: (context, constraints) {
        final cell = (constraints.maxWidth / 7).clamp(0.0, cellSize);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _WeekdayInitials(cycleStartDay: cycleStartDay, cell: cell),
            for (final week in weeks)
              _WeekRow(
                week: week,
                cell: cell,
                // Replié, le bandeau EST la semaine choisie : la surligner
                // n'apprendrait rien.
                isSelected: expanded && week == period,
                month: expanded ? month : null,
                today: today,
                byDay: byDay,
                prepByDay: prepByDay,
                onTapDay: (day) {
                  if (!expanded && onTapDay != null) {
                    onTapDay!(day);
                  } else {
                    onSelectPeriod(
                      planningWeekOf(day, cycleStartDay: cycleStartDay),
                    );
                  }
                },
              ),
          ],
        );
      },
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            period: period,
            cycleStartDay: cycleStartDay,
            expanded: expanded,
            month: month,
            today: today,
            earliestDay: earliestDay,
            onSelectPeriod: onSelectPeriod,
            onMonthChanged: onMonthChanged,
            onToggleExpanded: onToggleExpanded,
          ),
          if (expanded)
            grid
          else
            // Un balayage du bandeau passe à la semaine voisine.
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragEnd: (details) {
                final v = details.primaryVelocity ?? 0;
                if (v > 200 && period.start.isAfter(earliestDay)) {
                  onSelectPeriod(period.previous);
                } else if (v < -200) {
                  onSelectPeriod(period.next);
                }
              },
              child: grid,
            ),
          if (expanded) const PlanningCalendarLegend(),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// La ligne de titre : flèches, semaine ou mois lu, retour à aujourd'hui.
class _Header extends StatelessWidget {
  final PlanningWeek period;
  final int cycleStartDay;
  final bool expanded;
  final DateTime month;
  final DateTime today;
  final DateTime earliestDay;
  final ValueChanged<PlanningWeek> onSelectPeriod;
  final ValueChanged<DateTime> onMonthChanged;
  final VoidCallback? onToggleExpanded;

  const _Header({
    required this.period,
    required this.cycleStartDay,
    required this.expanded,
    required this.month,
    required this.today,
    required this.earliestDay,
    required this.onSelectPeriod,
    required this.onMonthChanged,
    required this.onToggleExpanded,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final todayPeriod = planningWeekOf(today, cycleStartDay: cycleStartDay);
    final atToday =
        period == todayPeriod &&
        (!expanded ||
            PlanningPeriodCalendar.monthOf(month) ==
                PlanningPeriodCalendar.monthOf(today));

    final VoidCallback? back;
    final VoidCallback forward;
    final String backTip;
    final String forwardTip;
    final String title;
    if (expanded) {
      final canGoBack = PlanningPeriodCalendar.monthOf(
        month,
      ).isAfter(PlanningPeriodCalendar.monthOf(earliestDay));
      back = canGoBack
          ? () => onMonthChanged(DateTime(month.year, month.month - 1))
          : null;
      forward = () => onMonthChanged(DateTime(month.year, month.month + 1));
      backTip = canGoBack
          ? 'Mois précédent'
          : 'L\'historique du planning s\'arrête ici';
      forwardTip = 'Mois suivant';
      final label = DateFormat('MMMM yyyy', 'fr').format(month);
      title = '${label[0].toUpperCase()}${label.substring(1)}';
    } else {
      final canGoBack = period.start.isAfter(earliestDay);
      back = canGoBack ? () => onSelectPeriod(period.previous) : null;
      forward = () => onSelectPeriod(period.next);
      backTip = canGoBack
          ? 'Semaine précédente'
          : 'L\'historique du planning s\'arrête ici';
      forwardTip = 'Semaine suivante';
      title = PlanningPeriodCalendar.periodTitle(
        period,
        today: today,
        cycleStartDay: cycleStartDay,
      );
    }

    final titleBlock = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          PlanningPeriodCalendar.periodRange(period),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );

    return Row(
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          tooltip: backTip,
          onPressed: back,
        ),
        Expanded(
          child: onToggleExpanded == null
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: titleBlock,
                )
              : Tooltip(
                  message: expanded
                      ? 'Réduire le calendrier'
                      : 'Afficher le mois',
                  child: InkWell(
                    onTap: onToggleExpanded,
                    borderRadius: BorderRadius.circular(8),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 48),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          children: [
                            Flexible(child: titleBlock),
                            const SizedBox(width: 4),
                            Icon(
                              expanded ? Icons.expand_less : Icons.expand_more,
                              color: scheme.onSurfaceVariant,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        ),
        IconButton(
          icon: const Icon(Icons.today_outlined),
          tooltip: 'Revenir à aujourd\'hui',
          onPressed: atToday
              ? null
              : () {
                  onMonthChanged(PlanningPeriodCalendar.monthOf(today));
                  onSelectPeriod(todayPeriod);
                },
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          tooltip: forwardTip,
          onPressed: forward,
        ),
      ],
    );
  }
}

/// Les initiales des jours, dans l'ordre du cycle.
class _WeekdayInitials extends StatelessWidget {
  final int cycleStartDay;
  final double cell;

  const _WeekdayInitials({required this.cycleStartDay, required this.cell});

  static const _initials = ['L', 'M', 'M', 'J', 'V', 'S', 'D'];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ExcludeSemantics(
      child: SizedBox(
        height: 24,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < 7; i++)
              SizedBox(
                width: cell,
                child: Center(
                  child: Text(
                    _initials[(cycleStartDay - 1 + i) % 7],
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      // Le premier jour du cycle se lit en gras : c'est là
                      // que la semaine commence.
                      fontWeight: i == 0 ? FontWeight.w800 : FontWeight.w500,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Une ligne de la grille : une semaine de planning.
class _WeekRow extends StatelessWidget {
  final PlanningWeek week;
  final double cell;
  final bool isSelected;

  /// Mois affiché ; les jours d'un autre mois s'affichent atténués. Null dans
  /// le bandeau replié, où aucun jour n'est hors mois.
  final DateTime? month;
  final DateTime today;
  final Map<DateTime, List<PlannedMeal>> byDay;
  final Map<DateTime, int> prepByDay;
  final ValueChanged<DateTime> onTapDay;

  const _WeekRow({
    required this.week,
    required this.cell,
    required this.isSelected,
    required this.month,
    required this.today,
    required this.byDay,
    required this.prepByDay,
    required this.onTapDay,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rangeLabel =
        'semaine du ${DateFormat('d MMMM', 'fr').format(week.start)} '
        'au ${DateFormat('d MMMM', 'fr').format(week.end)}';
    return Center(
      child: Container(
        width: cell * 7,
        height: cell,
        decoration: isSelected
            ? BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(cell / 2),
              )
            : null,
        child: Row(
          children: [
            for (final day in week.days)
              SizedBox(
                width: cell,
                child: _DayCell(
                  day: day,
                  size: cell,
                  meals: byDay[day] ?? const [],
                  prepCount: prepByDay[day] ?? 0,
                  isToday: day == today,
                  inSelectedWeek: isSelected,
                  isPast: day.isBefore(today),
                  outsideMonth:
                      month != null &&
                      (day.month != month!.month || day.year != month!.year),
                  weekLabel: rangeLabel,
                  onTap: () => onTapDay(day),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Une case de jour : le numéro, puis les pastilles.
class _DayCell extends StatelessWidget {
  final DateTime day;
  final double size;
  final List<PlannedMeal> meals;
  final int prepCount;
  final bool isToday;
  final bool inSelectedWeek;
  final bool isPast;
  final bool outsideMonth;
  final String weekLabel;
  final VoidCallback onTap;

  const _DayCell({
    required this.day,
    required this.size,
    required this.meals,
    required this.prepCount,
    required this.isToday,
    required this.inSelectedWeek,
    required this.isPast,
    required this.outsideMonth,
    required this.weekLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final base = inSelectedWeek ? scheme.onPrimaryContainer : scheme.onSurface;
    final Color numberColor;
    if (isToday) {
      numberColor = scheme.primary;
    } else if (outsideMonth) {
      numberColor = base.withValues(alpha: 0.35);
    } else if (isPast) {
      numberColor = base.withValues(alpha: 0.6);
    } else {
      numberColor = base;
    }

    final dotSize = (size * 0.11).clamp(3.0, 5.0);
    final dots = <Widget>[
      for (final meal in meals.take(3))
        PlanningCalendarDot(
          size: dotSize,
          color: meal.recipeId == null
              ? scheme.onSurfaceVariant.withValues(alpha: 0.6)
              : scheme.primary,
          filled: meal.recipeId != null,
        ),
      if (prepCount > 0)
        PlanningCalendarDot(
          size: dotSize,
          color: scheme.tertiary,
          filled: false,
        ),
    ];

    final mealsLabel = meals.isEmpty
        ? (prepCount > 0 ? 'jour de préparation' : 'aucun repas')
        : '${meals.length} repas';

    return Semantics(
      button: true,
      selected: inSelectedWeek,
      label: DateFormat('EEEE d MMMM', 'fr').format(day),
      value: '$mealsLabel, $weekLabel',
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          margin: EdgeInsets.all(size * 0.08),
          decoration: isToday
              ? BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: scheme.primary, width: 1.5),
                )
              : null,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  '${day.day}',
                  softWrap: false,
                  maxLines: 1,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    height: 1.1,
                    color: numberColor,
                    fontWeight: isToday ? FontWeight.w700 : FontWeight.w400,
                  ),
                ),
              ),
              SizedBox(
                height: dotSize + 2,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ...dots,
                    if (meals.length > 3)
                      Padding(
                        padding: const EdgeInsets.only(left: 2),
                        child: Text(
                          '+${meals.length - 3}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: dotSize * 1.6,
                            height: 1,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PlanningCalendarDot extends StatelessWidget {
  final double size;
  final Color color;
  final bool filled;

  const PlanningCalendarDot({
    super.key,
    required this.size,
    required this.color,
    required this.filled,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      margin: const EdgeInsets.symmetric(horizontal: 0.8),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? color : Colors.transparent,
        border: filled ? null : Border.all(color: color, width: 1),
      ),
    );
  }
}

/// Ce que veulent dire les pastilles. Sans elle, trois points de couleurs
/// différentes ne sont qu'une décoration.
class PlanningCalendarLegend extends StatelessWidget {
  const PlanningCalendarLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.labelSmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

    Widget item(Widget dot, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dot,
        const SizedBox(width: 4),
        Text(label, style: style),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 14,
        runSpacing: 2,
        children: [
          item(
            PlanningCalendarDot(size: 5, color: scheme.primary, filled: true),
            'repas',
          ),
          item(
            PlanningCalendarDot(
              size: 5,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.6),
              filled: false,
            ),
            'créneau vide',
          ),
          item(
            PlanningCalendarDot(size: 5, color: scheme.tertiary, filled: false),
            'préparation',
          ),
        ],
      ),
    );
  }
}
