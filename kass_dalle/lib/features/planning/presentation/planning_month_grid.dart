import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/planned_meal.dart';

/// Grille mensuelle du planning : sept colonnes, une pastille par repas.
///
/// Cette vue ne **stocke** rien et ne décide rien : elle range par jour les
/// repas que l'écran lui passe. Un mois est une lecture, pas un porteur — le
/// couple (personne, date) vit déjà dans `planned_meals`.
///
/// Les pastilles ne rejouent aucune règle de créneau : elles se lisent
/// entièrement dans des champs stockés — la recette est là ou non, la date de
/// préparation est là ou non. Rejouer ici les règles de midi et de soir serait
/// dupliquer une logique que le client a précisément cessé de porter.
class PlanningMonthGrid extends StatelessWidget {
  /// Premier jour du mois affiché.
  final DateTime month;

  /// Jour sélectionné, dont l'agenda est affiché sous la grille.
  final DateTime selectedDay;

  /// Repas du mois affiché, dans n'importe quel ordre.
  final List<PlannedMeal> meals;

  /// Repas préparés ce mois-ci pour être servis un autre jour — repérés par
  /// leur `prep_date`, qui peut tomber dans un mois différent du repas.
  final List<PlannedMeal> prepared;

  final ValueChanged<DateTime> onSelectDay;
  final ValueChanged<DateTime> onMonthChanged;

  /// Borne d'historique : au-delà, le stream ne remonte plus rien et la
  /// navigation vers le passé s'arrête. Un mois vide parce qu'il n'est pas
  /// chargé ressemblerait à un mois vide parce que rien n'y a été planifié.
  final DateTime earliestMonth;

  const PlanningMonthGrid({
    super.key,
    required this.month,
    required this.selectedDay,
    required this.meals,
    required this.prepared,
    required this.onSelectDay,
    required this.onMonthChanged,
    required this.earliestMonth,
  });

  static DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);
  static DateTime monthOf(DateTime d) => DateTime(d.year, d.month);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = dayOf(DateTime.now());

    // Le mois commence un lundi : `weekday` vaut 1 pour lundi, 7 pour dimanche.
    final firstOfMonth = DateTime(month.year, month.month);
    final leading = firstOfMonth.weekday - 1;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final cells = ((leading + daysInMonth) / 7).ceil() * 7;

    final byDay = <DateTime, List<PlannedMeal>>{};
    for (final meal in meals) {
      (byDay[dayOf(meal.plannedAt)] ??= []).add(meal);
    }
    final prepByDay = <DateTime, int>{};
    for (final meal in prepared) {
      final prep = meal.prepDate;
      if (prep == null) continue;
      final day = dayOf(prep);
      prepByDay[day] = (prepByDay[day] ?? 0) + 1;
    }

    final canGoBack = monthOf(month).isAfter(monthOf(earliestMonth));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _MonthHeader(
          month: month,
          canGoBack: canGoBack,
          onPrevious: () =>
              onMonthChanged(DateTime(month.year, month.month - 1)),
          onNext: () => onMonthChanged(DateTime(month.year, month.month + 1)),
          onToday: monthOf(today) == monthOf(month) && selectedDay == today
              ? null
              : () {
                  onMonthChanged(monthOf(today));
                  onSelectDay(today);
                },
        ),
        const SizedBox(height: 4),
        _WeekdayRow(theme: theme),
        const SizedBox(height: 2),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              childAspectRatio: 0.92,
            ),
            itemCount: cells,
            itemBuilder: (context, index) {
              final dayNumber = index - leading + 1;
              if (dayNumber < 1 || dayNumber > daysInMonth) {
                return const SizedBox.shrink();
              }
              final day = DateTime(month.year, month.month, dayNumber);
              return _DayCell(
                day: day,
                meals: byDay[day] ?? const [],
                prepCount: prepByDay[day] ?? 0,
                isToday: day == today,
                isSelected: day == dayOf(selectedDay),
                isPast: day.isBefore(today),
                onTap: () => onSelectDay(day),
              );
            },
          ),
        ),
        const SizedBox(height: 8),
        _Legend(theme: theme),
      ],
    );
  }
}

class _MonthHeader extends StatelessWidget {
  final DateTime month;
  final bool canGoBack;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  /// `null` quand on est déjà sur aujourd'hui : un bouton qui ne fait rien
  /// n'apprend rien.
  final VoidCallback? onToday;

  const _MonthHeader({
    required this.month,
    required this.canGoBack,
    required this.onPrevious,
    required this.onNext,
    required this.onToday,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = DateFormat('MMMM yyyy', 'fr').format(month);

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: canGoBack
                ? 'Mois précédent'
                : 'L\'historique du planning s\'arrête ici',
            onPressed: canGoBack ? onPrevious : null,
          ),
          Expanded(
            child: Text(
              '${label[0].toUpperCase()}${label.substring(1)}',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Mois suivant',
            onPressed: onNext,
          ),
          TextButton(onPressed: onToday, child: const Text('Auj.')),
        ],
      ),
    );
  }
}

class _WeekdayRow extends StatelessWidget {
  final ThemeData theme;
  const _WeekdayRow({required this.theme});

  @override
  Widget build(BuildContext context) {
    const labels = ['L', 'M', 'M', 'J', 'V', 'S', 'D'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          for (final label in labels)
            Expanded(
              child: Text(
                label,
                textAlign: TextAlign.center,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Une case de jour : le numéro, puis les pastilles.
///
/// Au-delà de trois pastilles la case afficherait une ligne illisible : le
/// surplus est annoncé par un « +n », qui dit qu'il y a plus sans prétendre le
/// montrer.
class _DayCell extends StatelessWidget {
  final DateTime day;
  final List<PlannedMeal> meals;
  final int prepCount;
  final bool isToday;
  final bool isSelected;
  final bool isPast;
  final VoidCallback onTap;

  const _DayCell({
    required this.day,
    required this.meals,
    required this.prepCount,
    required this.isToday,
    required this.isSelected,
    required this.isPast,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasSomething = meals.isNotEmpty || prepCount > 0;

    final Color numberColor;
    if (isSelected) {
      numberColor = scheme.onPrimary;
    } else if (isToday) {
      numberColor = scheme.primary;
    } else if (isPast) {
      numberColor = scheme.onSurfaceVariant.withValues(alpha: 0.55);
    } else {
      numberColor = scheme.onSurface;
    }

    // Le surlignage du jour porteur de repas est une teinte de fond, pas un
    // point de plus : il se voit à la volée, sans se confondre avec les
    // pastilles qui, elles, comptent.
    final Color? background = isSelected
        ? scheme.primary
        : hasSomething
        ? scheme.primaryContainer.withValues(alpha: isPast ? 0.30 : 0.55)
        : null;

    final dots = <Widget>[
      for (final meal in meals.take(3))
        _Dot(
          color: meal.recipeId == null
              ? scheme.onSurfaceVariant.withValues(alpha: 0.45)
              : (isSelected ? scheme.onPrimary : scheme.primary),
          filled: meal.recipeId != null,
        ),
      if (prepCount > 0)
        _Dot(
          color: isSelected ? scheme.onPrimary : scheme.tertiary,
          filled: false,
        ),
    ];

    return Semantics(
      button: true,
      selected: isSelected,
      label: DateFormat('EEEE d MMMM', 'fr').format(day),
      value: meals.isEmpty
          ? (prepCount > 0 ? 'jour de préparation' : 'aucun repas')
          : '${meals.length} repas',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          margin: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(10),
            border: isToday && !isSelected
                ? Border.all(color: scheme.primary, width: 1.5)
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${day.day}',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: numberColor,
                  fontWeight: isToday || isSelected
                      ? FontWeight.w700
                      : FontWeight.w400,
                ),
              ),
              const SizedBox(height: 3),
              SizedBox(
                height: 8,
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
                            fontSize: 8,
                            height: 1,
                            color: isSelected
                                ? scheme.onPrimary
                                : scheme.onSurfaceVariant,
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

class _Dot extends StatelessWidget {
  final Color color;
  final bool filled;

  const _Dot({required this.color, required this.filled});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 5,
      height: 5,
      margin: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? color : Colors.transparent,
        border: filled ? null : Border.all(color: color, width: 1),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final ThemeData theme;
  const _Legend({required this.theme});

  @override
  Widget build(BuildContext context) {
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
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 14,
        runSpacing: 4,
        children: [
          item(_Dot(color: scheme.primary, filled: true), 'repas'),
          item(
            _Dot(
              color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
              filled: false,
            ),
            'créneau vide',
          ),
          item(_Dot(color: scheme.tertiary, filled: false), 'préparation'),
        ],
      ),
    );
  }
}
