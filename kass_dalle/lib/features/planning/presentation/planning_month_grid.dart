import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../domain/planned_meal.dart';

/// Bande calendaire du planning : trois mois côte à côte, le mois courant au
/// centre, le précédent et le suivant à ses côtés en plus petit.
///
/// La bande occupe une hauteur **imposée par l'écran** et n'en déborde jamais :
/// les cases se dimensionnent à partir de la hauteur reçue, elles ne l'étirent
/// pas. Une grille qui prend toute la largeur disponible produit des cases de
/// deux cents pixels — un mois qui ne tient plus dans l'écran n'est plus un
/// calendrier, c'est une liste très aérée.
///
/// Cette vue ne **stocke** rien et ne décide rien : elle range par jour les
/// repas que l'écran lui passe. Un mois est une position de lecture, pas un
/// porteur — le couple (personne, date) vit déjà dans `planned_meals`.
///
/// Les pastilles ne rejouent aucune règle de créneau : elles se lisent
/// entièrement dans des champs stockés — la recette est là ou non, la date de
/// préparation est là ou non. Rejouer ici les règles de midi et de soir serait
/// dupliquer une logique que le client a précisément cessé de porter.
class PlanningMonthBand extends StatelessWidget {
  /// Mois affiché au centre.
  final DateTime month;

  /// Jour sélectionné, dont l'agenda est affiché sous la bande.
  final DateTime selectedDay;

  /// Tous les repas connus : la bande range elle-même par jour, sur les trois
  /// mois qu'elle montre.
  final List<PlannedMeal> meals;

  final ValueChanged<DateTime> onSelectDay;
  final ValueChanged<DateTime> onMonthChanged;

  /// Borne d'historique : au-delà, le stream ne remonte plus rien et la
  /// navigation vers le passé s'arrête. Un mois vide parce qu'il n'est pas
  /// chargé ressemblerait à un mois vide parce que rien n'y a été planifié.
  final DateTime earliestMonth;

  const PlanningMonthBand({
    super.key,
    required this.month,
    required this.selectedDay,
    required this.meals,
    required this.onSelectDay,
    required this.onMonthChanged,
    required this.earliestMonth,
  });

  static DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);
  static DateTime monthOf(DateTime d) => DateTime(d.year, d.month);

  /// Hauteur réservée au libellé d'un mois, fixe : c'est elle qui aligne les
  /// trois grilles entre elles, et elle entre dans le calcul de la case.
  static const monthTitleHeight = 22.0;

  /// Hauteur de la ligne des initiales, exprimée en fraction d'une case.
  static const weekdayRowFactor = 0.62;

  /// Hauteur de la bande : un tiers de l'écran, bornée pour rester un
  /// calendrier sur un téléphone comme sur un écran de bureau.
  static double bandHeight(BuildContext context) =>
      (MediaQuery.sizeOf(context).height / 3).clamp(180.0, 320.0);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = dayOf(DateTime.now());

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

    final previous = DateTime(month.year, month.month - 1);
    final next = DateTime(month.year, month.month + 1);
    final canGoBack = monthOf(month).isAfter(monthOf(earliestMonth));

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(Icons.chevron_left),
          tooltip: canGoBack
              ? 'Mois précédent'
              : 'L\'historique du planning s\'arrête ici',
          onPressed: canGoBack ? () => onMonthChanged(previous) : null,
        ),
        // Le calcul des cases se fait DANS la place qui reste, pas dans la
        // largeur totale : soustraire une estimation de la largeur des
        // commandes revenait à deviner, et une estimation trop basse déborde de
        // quelques pixels sur un téléphone.
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              // La case se déduit des DEUX contraintes, jamais d'une seule :
              // six lignes de semaine plus le libellé et les initiales en
              // hauteur, sept cases en largeur. Ne regarder que la largeur
              // donnait les cases de deux cents pixels du premier essai.
              final cellByHeight =
                  (constraints.maxHeight - monthTitleHeight) /
                  (6 + weekdayRowFactor);
              final cellByWidth = constraints.maxWidth / 7;
              final centerCell = math
                  .min(cellByHeight, cellByWidth)
                  .clamp(14.0, 40.0);
              final sideCell = centerCell * 0.68;

              // Les mois latéraux ne s'affichent que s'ils tiennent en entier :
              // un mois tronqué se lit moins bien que pas de mois du tout, et
              // les flèches suffisent à y aller.
              final needed = centerCell * 7 + 2 * (sideCell * 7) + 32;
              final showSides = constraints.maxWidth >= needed;

              return Row(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showSides) ...[
                    _MonthCalendar(
                      month: previous,
                      cellSize: sideCell,
                      isCenter: false,
                      selectedDay: selectedDay,
                      today: today,
                      byDay: byDay,
                      prepByDay: prepByDay,
                      onSelectDay: onSelectDay,
                    ),
                    const SizedBox(width: 16),
                  ],
                  _MonthCalendar(
                    month: month,
                    cellSize: centerCell,
                    isCenter: true,
                    selectedDay: selectedDay,
                    today: today,
                    byDay: byDay,
                    prepByDay: prepByDay,
                    onSelectDay: onSelectDay,
                  ),
                  if (showSides) ...[
                    const SizedBox(width: 16),
                    _MonthCalendar(
                      month: next,
                      cellSize: sideCell,
                      isCenter: false,
                      selectedDay: selectedDay,
                      today: today,
                      byDay: byDay,
                      prepByDay: prepByDay,
                      onSelectDay: onSelectDay,
                    ),
                  ],
                ],
              );
            },
          ),
        ),
        IconButton(
          icon: const Icon(Icons.chevron_right),
          tooltip: 'Mois suivant',
          onPressed: () => onMonthChanged(next),
        ),
        _TodayButton(
          theme: theme,
          onPressed:
              monthOf(today) == monthOf(month) && dayOf(selectedDay) == today
              ? null
              : () {
                  onMonthChanged(monthOf(today));
                  onSelectDay(today);
                },
        ),
      ],
    );
  }
}

/// Un mois : son libellé, les initiales des jours, puis la grille.
///
/// Tout est dimensionné par [cellSize] — la grille ne s'étire pas pour remplir
/// ce qu'on lui donne, elle occupe exactement sept cases de large.
class _MonthCalendar extends StatelessWidget {
  final DateTime month;
  final double cellSize;
  final bool isCenter;
  final DateTime selectedDay;
  final DateTime today;
  final Map<DateTime, List<PlannedMeal>> byDay;
  final Map<DateTime, int> prepByDay;
  final ValueChanged<DateTime> onSelectDay;

  const _MonthCalendar({
    required this.month,
    required this.cellSize,
    required this.isCenter,
    required this.selectedDay,
    required this.today,
    required this.byDay,
    required this.prepByDay,
    required this.onSelectDay,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    // Le mois commence un lundi : `weekday` vaut 1 pour lundi, 7 pour dimanche.
    final leading = DateTime(month.year, month.month).weekday - 1;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final rows = ((leading + daysInMonth) / 7).ceil();

    final label = DateFormat('MMMM yyyy', 'fr').format(month);
    final title = '${label[0].toUpperCase()}${label.substring(1)}';

    return SizedBox(
      width: cellSize * 7,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: PlanningMonthBand.monthTitleHeight,
            child: Center(
              child: Text(
                isCenter ? title : DateFormat('MMMM', 'fr').format(month),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: isCenter
                    ? theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      )
                    : theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
              ),
            ),
          ),
          SizedBox(
            height: cellSize * PlanningMonthBand.weekdayRowFactor,
            child: Row(
              children: [
                for (final initial in const ['L', 'M', 'M', 'J', 'V', 'S', 'D'])
                  SizedBox(
                    width: cellSize,
                    child: Center(
                      child: Text(
                        initial,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: cellSize * 0.3,
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          for (var row = 0; row < rows; row++)
            SizedBox(
              height: cellSize,
              child: Row(
                children: [
                  for (var col = 0; col < 7; col++)
                    SizedBox(
                      width: cellSize,
                      child: Builder(
                        builder: (context) {
                          final dayNumber = row * 7 + col - leading + 1;
                          if (dayNumber < 1 || dayNumber > daysInMonth) {
                            return const SizedBox.shrink();
                          }
                          final day = DateTime(
                            month.year,
                            month.month,
                            dayNumber,
                          );
                          return _DayCell(
                            day: day,
                            size: cellSize,
                            meals: byDay[day] ?? const [],
                            prepCount: prepByDay[day] ?? 0,
                            isToday: day == today,
                            isSelected:
                                day == PlanningMonthBand.dayOf(selectedDay),
                            isPast: day.isBefore(today),
                            dense: !isCenter,
                            onTap: () => onSelectDay(day),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Une case de jour : le numéro, puis les pastilles.
///
/// Dans un mois latéral, il n'y a pas la place de compter : une seule pastille
/// dit « il se passe quelque chose ce jour-là », et le mois central dit quoi.
class _DayCell extends StatelessWidget {
  final DateTime day;
  final double size;
  final List<PlannedMeal> meals;
  final int prepCount;
  final bool isToday;
  final bool isSelected;
  final bool isPast;
  final bool dense;
  final VoidCallback onTap;

  const _DayCell({
    required this.day,
    required this.size,
    required this.meals,
    required this.prepCount,
    required this.isToday,
    required this.isSelected,
    required this.isPast,
    required this.dense,
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

    // Le surlignage d'un jour porteur de repas est une teinte de fond, pas un
    // point de plus : il se voit à la volée, sans se confondre avec les
    // pastilles qui, elles, comptent.
    final Color? background = isSelected
        ? scheme.primary
        : hasSomething
        ? scheme.primaryContainer.withValues(alpha: isPast ? 0.30 : 0.55)
        : null;

    final dotSize = (size * 0.13).clamp(3.0, 5.0);
    final visible = dense ? 1 : 3;
    final dots = <Widget>[
      for (final meal in meals.take(visible))
        _Dot(
          size: dotSize,
          color: meal.recipeId == null
              ? scheme.onSurfaceVariant.withValues(alpha: 0.45)
              : (isSelected ? scheme.onPrimary : scheme.primary),
          filled: meal.recipeId != null,
        ),
      if (prepCount > 0 && !dense)
        _Dot(
          size: dotSize,
          color: isSelected ? scheme.onPrimary : scheme.tertiary,
          filled: false,
        ),
      if (prepCount > 0 && dense && meals.isEmpty)
        _Dot(
          size: dotSize,
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
        borderRadius: BorderRadius.circular(size * 0.25),
        child: Container(
          margin: EdgeInsets.all(size * 0.06),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(size * 0.25),
            border: isToday && !isSelected
                ? Border.all(color: scheme.primary, width: 1.2)
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${day.day}',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: size * 0.36,
                  height: 1.1,
                  color: numberColor,
                  fontWeight: isToday || isSelected
                      ? FontWeight.w700
                      : FontWeight.w400,
                ),
              ),
              SizedBox(
                height: dotSize + 2,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ...dots,
                    if (!dense && meals.length > 3)
                      Padding(
                        padding: const EdgeInsets.only(left: 2),
                        child: Text(
                          '+${meals.length - 3}',
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: dotSize * 1.6,
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
  final double size;
  final Color color;
  final bool filled;

  const _Dot({required this.size, required this.color, required this.filled});

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

class _TodayButton extends StatelessWidget {
  final ThemeData theme;
  final VoidCallback? onPressed;

  const _TodayButton({required this.theme, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: const Text('Auj.'),
    );
  }
}

/// Ce que veulent dire les pastilles. Sans elle, trois points de couleurs
/// différentes ne sont qu'une décoration.
class PlanningMonthLegend extends StatelessWidget {
  const PlanningMonthLegend({super.key});

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
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 14,
        runSpacing: 2,
        children: [
          item(_Dot(size: 5, color: scheme.primary, filled: true), 'repas'),
          item(
            _Dot(
              size: 5,
              color: scheme.onSurfaceVariant.withValues(alpha: 0.45),
              filled: false,
            ),
            'créneau vide',
          ),
          item(
            _Dot(size: 5, color: scheme.tertiary, filled: false),
            'préparation',
          ),
        ],
      ),
    );
  }
}
