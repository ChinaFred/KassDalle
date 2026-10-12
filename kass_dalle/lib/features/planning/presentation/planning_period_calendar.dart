import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/planned_meal.dart';
import '../domain/planning_week.dart';

/// Le calendrier du planning : il choisit la période que l'écran affiche.
///
/// La grille est un calendrier habituel, du lundi au dimanche. La période
/// choisie y est surlignée d'une bande continue, qui passe d'une ligne à
/// l'autre quand elle chevauche deux semaines — du vendredi au jeudi, par
/// exemple.
///
/// Un appui sur un jour choisit la période par défaut qui le contient : sept
/// jours à partir du jour de démarrage du cycle. Un appui long commence une
/// période libre, que l'appui suivant termine. Rien n'est stocké : la période
/// et le mois sont des positions de lecture.
///
/// Replié, il ne montre que les lignes qui contiennent la période ; déplié, le
/// mois entier. Les pastilles se lisent dans des champs stockés — recette
/// posée ou non, date de préparation ou non — et ne rejouent aucune règle de
/// créneau.
class PlanningPeriodCalendar extends StatelessWidget {
  /// Période choisie, affichée sous le calendrier.
  final PlanningPeriod period;

  /// Jour de démarrage du cycle, 1 = lundi … 7 = dimanche : il fixe la période
  /// par défaut.
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

  final ValueChanged<PlanningPeriod> onSelectPeriod;
  final ValueChanged<DateTime> onMonthChanged;

  /// Appui sur un jour de la période, calendrier replié : la liste y descend.
  /// Null : l'appui choisit la période par défaut, comme ailleurs.
  final ValueChanged<DateTime>? onTapDay;

  /// Plie ou déplie le calendrier. Null : il reste dans son état, sans
  /// bouton — c'est le cas du grand écran, où le mois est toujours affiché.
  final VoidCallback? onToggleExpanded;

  /// Premier jour d'une période libre en cours de choix, ou null.
  final DateTime? rangeStart;

  /// Appui long sur un jour : il devient le début d'une période libre.
  final ValueChanged<DateTime> onRangeStart;

  /// Abandon de la période libre en cours de choix.
  final VoidCallback onRangeCancel;

  /// Fin touchée trop loin du début : plus de [PlanningPeriod.maxLength]
  /// jours. Rien n'est appliqué, le choix reste en cours.
  final VoidCallback onRangeTooLong;

  /// Ouvre le sélecteur de dates. Affiché sous la grille quand il est donné —
  /// sur grand écran, où il n'y a pas de menu ⋮.
  final VoidCallback? onChooseDates;

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
    required this.onRangeStart,
    required this.onRangeCancel,
    required this.onRangeTooLong,
    this.rangeStart,
    this.onTapDay,
    this.onToggleExpanded,
    this.onChooseDates,
    this.now,
  });

  /// Taille d'une case : 48 px, la cible tactile minimale, quand la largeur
  /// le permet.
  static const cellSize = 48.0;

  static DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);
  static DateTime monthOf(DateTime d) => DateTime(d.year, d.month);

  /// Vrai si [period] est la période par défaut qui commence à son premier
  /// jour : une semaine qui part du jour de démarrage du cycle.
  static bool isDefault(PlanningPeriod period, {required int cycleStartDay}) =>
      period == planningWeekOf(period.start, cycleStartDay: cycleStartDay);

  /// Titre d'une période par défaut : « Cette semaine », « Semaine
  /// prochaine », « Semaine dernière », ou la date de début. Pour une période
  /// libre : « Du ven. 9 au mer. 14 oct. ».
  static String periodTitle(
    PlanningPeriod period, {
    required DateTime today,
    required int cycleStartDay,
  }) {
    if (!isDefault(period, cycleStartDay: cycleStartDay)) {
      if (period.length == 1) {
        return DateFormat('EEE d MMM', 'fr').format(period.start);
      }
      final sameMonth = period.start.month == period.end.month;
      final start = DateFormat(
        sameMonth ? 'EEE d' : 'EEE d MMM',
        'fr',
      ).format(period.start);
      final end = DateFormat('EEE d MMM', 'fr').format(period.end);
      return 'Du $start au $end';
    }
    final current = planningWeekOf(today, cycleStartDay: cycleStartDay);
    if (period == current) return 'Cette semaine';
    if (period == current.next) return 'Semaine prochaine';
    if (period == current.previous) return 'Semaine dernière';
    return 'Semaine du ${DateFormat('d MMMM', 'fr').format(period.start)}';
  }

  /// « ven. 9 – jeu. 15 oct. », le mois répété quand la période en change.
  static String periodRange(PlanningPeriod period) {
    if (period.length == 1) {
      return DateFormat('EEE d MMM', 'fr').format(period.start);
    }
    final sameMonth = period.start.month == period.end.month;
    final start = DateFormat(
      sameMonth ? 'EEE d' : 'EEE d MMM',
      'fr',
    ).format(period.start);
    final end = DateFormat('EEE d MMM', 'fr').format(period.end);
    return '$start – $end';
  }

  /// « 1 jour », « 6 jours ».
  static String lengthLabel(PlanningPeriod period) =>
      period.length == 1 ? '1 jour' : '${period.length} jours';

  /// Termine une période libre sur [day] : la période va du début choisi à
  /// ce jour, dans l'ordre où ils tombent.
  void _finishRange(DateTime day) {
    final chosen = PlanningPeriod.between(rangeStart!, day);
    if (chosen.length > PlanningPeriod.maxLength) {
      onRangeTooLong();
      return;
    }
    onSelectPeriod(chosen);
  }

  void _onTap(DateTime day) {
    if (rangeStart != null) {
      _finishRange(day);
    } else if (!expanded && onTapDay != null && period.contains(day)) {
      onTapDay!(day);
    } else {
      onSelectPeriod(planningWeekOf(day, cycleStartDay: cycleStartDay));
    }
  }

  String _tapHint(DateTime day) {
    if (rangeStart != null) return 'Finir la période ici';
    if (!expanded && onTapDay != null && period.contains(day)) {
      return 'Afficher ce jour';
    }
    return 'Choisir la semaine';
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

    final rows = expanded
        ? planningWeeksCovering(month, cycleStartDay: DateTime.monday)
        : calendarRowsFor(period);
    final firstLoadedDay = monthOf(earliestDay);

    final grid = LayoutBuilder(
      builder: (context, constraints) {
        final cell = (constraints.maxWidth / 7).clamp(0.0, cellSize);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _WeekdayInitials(cell: cell),
            for (final row in rows)
              Center(
                child: SizedBox(
                  width: cell * 7,
                  height: cell,
                  child: Row(
                    children: [
                      for (final day in row.days)
                        SizedBox(
                          width: cell,
                          child: _DayCell(
                            day: day,
                            size: cell,
                            meals: byDay[day] ?? const [],
                            prepCount: prepByDay[day] ?? 0,
                            isToday: day == today,
                            inPeriod: period.contains(day),
                            isPeriodStart: day == period.start,
                            isPeriodEnd: day == period.end,
                            isRangeStart: day == rangeStart,
                            isPast: day.isBefore(today),
                            outsideMonth:
                                expanded &&
                                (day.month != month.month ||
                                    day.year != month.year),
                            tapHint: _tapHint(day),
                            onTap: day.isBefore(firstLoadedDay)
                                ? null
                                : () => _onTap(day),
                            onLongPress: day.isBefore(firstLoadedDay)
                                ? null
                                : () => onRangeStart(day),
                          ),
                        ),
                    ],
                  ),
                ),
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
            choosing: rangeStart != null,
            onSelectPeriod: (p) {
              if (rangeStart != null) onRangeCancel();
              onSelectPeriod(p);
            },
            onMonthChanged: onMonthChanged,
            onToggleExpanded: onToggleExpanded,
          ),
          if (rangeStart != null)
            _RangeBanner(start: rangeStart!, onCancel: onRangeCancel),
          if (expanded || rangeStart != null)
            grid
          else
            // Un balayage du bandeau passe à la période voisine, de même
            // longueur. Il est coupé pendant le choix d'une période libre : un
            // geste raté y perdrait le début choisi.
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
          if (expanded)
            Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                const PlanningCalendarLegend(),
                if (onChooseDates != null)
                  TextButton.icon(
                    onPressed: onChooseDates,
                    icon: const Icon(Icons.date_range_outlined),
                    label: const Text('Choisir des dates…'),
                  ),
              ],
            ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

/// La ligne de titre : flèches, période ou mois lu, retour à aujourd'hui.
class _Header extends StatelessWidget {
  final PlanningPeriod period;
  final int cycleStartDay;
  final bool expanded;
  final DateTime month;
  final DateTime today;
  final DateTime earliestDay;
  final bool choosing;
  final ValueChanged<PlanningPeriod> onSelectPeriod;
  final ValueChanged<DateTime> onMonthChanged;
  final VoidCallback? onToggleExpanded;

  const _Header({
    required this.period,
    required this.cycleStartDay,
    required this.expanded,
    required this.month,
    required this.today,
    required this.earliestDay,
    required this.choosing,
    required this.onSelectPeriod,
    required this.onMonthChanged,
    required this.onToggleExpanded,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final isDefault = PlanningPeriodCalendar.isDefault(
      period,
      cycleStartDay: cycleStartDay,
    );
    final todayPeriod = planningWeekOf(today, cycleStartDay: cycleStartDay);
    final atToday =
        !choosing &&
        period == todayPeriod &&
        (!expanded ||
            PlanningPeriodCalendar.monthOf(month) ==
                PlanningPeriodCalendar.monthOf(today));

    // Pendant le choix d'une période libre, le calendrier est déplié et les
    // flèches changent de mois : la fin peut tomber le mois suivant.
    final byMonth = expanded || choosing;

    final VoidCallback? back;
    final VoidCallback forward;
    final String backTip;
    final String forwardTip;
    final String title;
    final String subtitle;
    if (byMonth) {
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
      subtitle = isDefault
          ? PlanningPeriodCalendar.periodRange(period)
          : '${PlanningPeriodCalendar.periodRange(period)} · '
                '${PlanningPeriodCalendar.lengthLabel(period)}';
    } else {
      final canGoBack = period.start.isAfter(earliestDay);
      back = canGoBack ? () => onSelectPeriod(period.previous) : null;
      forward = () => onSelectPeriod(period.next);
      final unit = isDefault ? 'Semaine' : 'Période';
      backTip = canGoBack
          ? '$unit précédente'
          : 'L\'historique du planning s\'arrête ici';
      forwardTip = '$unit suivante';
      title = PlanningPeriodCalendar.periodTitle(
        period,
        today: today,
        cycleStartDay: cycleStartDay,
      );
      // Le titre d'une période libre dit déjà ses dates : la seconde ligne
      // donne sa longueur.
      subtitle = isDefault
          ? PlanningPeriodCalendar.periodRange(period)
          : PlanningPeriodCalendar.lengthLabel(period);
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
          subtitle,
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
          child: onToggleExpanded == null || choosing
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: titleBlock,
                )
              : Semantics(
                  button: true,
                  expanded: expanded,
                  child: Tooltip(
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
                                expanded
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                                color: scheme.onSurfaceVariant,
                              ),
                            ],
                          ),
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

/// Le bandeau du choix d'une période libre : où il a commencé, et comment en
/// sortir.
class _RangeBanner extends StatelessWidget {
  final DateTime start;
  final VoidCallback onCancel;

  const _RangeBanner({required this.start, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.only(left: 12),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              liveRegion: true,
              child: Text(
                'Du ${DateFormat('EEE d MMM', 'fr').format(start)} — '
                'touchez le dernier jour',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
          ),
          TextButton(onPressed: onCancel, child: const Text('Annuler')),
        ],
      ),
    );
  }
}

/// Les initiales des jours, du lundi au dimanche.
class _WeekdayInitials extends StatelessWidget {
  final double cell;

  const _WeekdayInitials({required this.cell});

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
            for (final initial in _initials)
              SizedBox(
                width: cell,
                child: Center(
                  child: Text(
                    initial,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
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

/// Une case de jour : la bande de la période en fond, le numéro, puis les
/// pastilles.
class _DayCell extends StatelessWidget {
  final DateTime day;
  final double size;
  final List<PlannedMeal> meals;
  final int prepCount;
  final bool isToday;
  final bool inPeriod;
  final bool isPeriodStart;
  final bool isPeriodEnd;
  final bool isRangeStart;
  final bool isPast;
  final bool outsideMonth;
  final String tapHint;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _DayCell({
    required this.day,
    required this.size,
    required this.meals,
    required this.prepCount,
    required this.isToday,
    required this.inPeriod,
    required this.isPeriodStart,
    required this.isPeriodEnd,
    required this.isRangeStart,
    required this.isPast,
    required this.outsideMonth,
    required this.tapHint,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final base = isRangeStart
        ? scheme.onPrimary
        : inPeriod
        ? scheme.onPrimaryContainer
        : scheme.onSurface;
    final Color numberColor;
    if (isRangeStart) {
      numberColor = scheme.onPrimary;
    } else if (isToday) {
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

    // Plusieurs plannings affichés : la pastille compte les repas de tous,
    // et le lecteur d'écran dit pour combien de personnes.
    final people = meals.map((m) => m.uid).toSet().length;
    final mealsLabel = meals.isEmpty
        ? (prepCount > 0 ? 'jour de préparation' : 'aucun repas')
        : people > 1
        ? '${meals.length} repas, $people personnes'
        : '${meals.length} repas';

    // La bande : arrondie au premier et au dernier jour de la période,
    // coupée droite au changement de ligne pour se lire d'un seul tenant.
    final radius = Radius.circular(size / 2);
    final band = inPeriod
        ? BoxDecoration(
            color: scheme.primaryContainer,
            borderRadius: BorderRadius.horizontal(
              left: isPeriodStart ? radius : Radius.zero,
              right: isPeriodEnd ? radius : Radius.zero,
            ),
          )
        : null;

    final BoxDecoration? mark;
    if (isRangeStart) {
      mark = BoxDecoration(shape: BoxShape.circle, color: scheme.primary);
    } else if (isToday) {
      mark = BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: scheme.primary, width: 1.5),
      );
    } else {
      mark = null;
    }

    return Semantics(
      button: true,
      selected: inPeriod,
      label: DateFormat('EEEE d MMMM', 'fr').format(day),
      value: inPeriod ? '$mealsLabel, dans la période choisie' : mealsLabel,
      onTapHint: onTap == null ? null : tapHint,
      onLongPressHint: onLongPress == null ? null : 'Commencer une période ici',
      child: Container(
        margin: EdgeInsets.symmetric(vertical: size * 0.06),
        decoration: band,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          customBorder: const CircleBorder(),
          child: Container(
            margin: EdgeInsets.all(size * 0.04),
            decoration: mark,
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
                      fontWeight: isToday || isRangeStart
                          ? FontWeight.w700
                          : FontWeight.w400,
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
