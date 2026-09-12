/// Reprendre une semaine passée : ses repas remplissent les créneaux d'un
/// nouveau cycle, jour de semaine pour jour de semaine.
///
/// « Prends ce qu'on a fait il y a deux semaines » ne demande rien à l'IA :
/// la réponse est dans les repas déjà planifiés. Un cycle démarre le même jour
/// de semaine qu'une semaine de planning, donc un mardi reprend un mardi. Un
/// cycle plus long que sept jours revoit un jour de semaine déjà servi : la
/// recette n'est alors pas reposée une seconde fois.
library;

import '../../recipes/domain/recipe.dart';
import 'planned_meal.dart';
import 'planning_week.dart';

/// Une semaine passée qu'on peut reprendre : ses repas avec recette, dans
/// l'ordre des jours.
class ReplayableWeek {
  final PlanningWeek week;
  final List<PlannedMeal> meals;

  const ReplayableWeek({required this.week, required this.meals});

  /// Les titres servis, pour présenter la semaine avant de la choisir.
  List<String> get titres => [for (final m in meals) m.recipeTitre];

  /// Les recettes à résoudre avant de reprendre.
  Set<String> get recipeIds => {
    for (final m in meals)
      if (m.recipeId != null && m.recipeId!.isNotEmpty) m.recipeId!,
  };
}

/// Les semaines qui portent au moins un repas avec recette, de la plus
/// récente à la plus ancienne.
///
/// Les semaines que recouvre le cycle en composition n'y figurent pas : on ne
/// reprend pas une semaine dans elle-même, et ses repas seront de toute façon
/// remplacés ou doublés à la validation.
List<ReplayableWeek> replayableWeeks(
  Iterable<PlannedMeal> meals, {
  required int cycleStartDay,
  required Iterable<DateTime> cycleDates,
}) {
  final cycleWeeks = {
    for (final d in cycleDates) planningWeekOf(d, cycleStartDay: cycleStartDay),
  };
  final byWeek = <PlanningWeek, List<PlannedMeal>>{};
  for (final meal in meals) {
    if (meal.recipeId == null || meal.recipeId!.isEmpty) continue;
    final week = planningWeekOf(meal.plannedAt, cycleStartDay: cycleStartDay);
    if (cycleWeeks.contains(week)) continue;
    byWeek.putIfAbsent(week, () => []).add(meal);
  }
  final out = [
    for (final e in byWeek.entries)
      ReplayableWeek(
        week: e.key,
        meals: e.value..sort((a, b) => a.plannedAt.compareTo(b.plannedAt)),
      ),
  ];
  out.sort((a, b) => b.week.start.compareTo(a.week.start));
  return out;
}

/// Ce qu'une reprise a fait, et ce qu'elle n'a pas pu faire.
class WeekReplay {
  /// Créneau → recette reprise.
  final Map<int, Recipe> assignments;

  /// Créneaux déjà remplis, laissés tels quels.
  final int skippedFilled;

  /// Jours dont la recette n'a pas pu être retrouvée : supprimée, ou dans un
  /// livre devenu privé.
  final int skippedMissing;

  /// Jours de semaine sans repas dans la semaine reprise.
  final int skippedNoMeal;

  /// Jours dont la recette était déjà posée ailleurs dans le cycle.
  final int skippedDuplicate;

  const WeekReplay({
    required this.assignments,
    required this.skippedFilled,
    required this.skippedMissing,
    required this.skippedNoMeal,
    required this.skippedDuplicate,
  });

  int get applied => assignments.length;
}

/// Pose les repas de [source] sur les créneaux vides de [slotDates].
///
/// Jour de semaine pour jour de semaine : le mardi du cycle reçoit le mardi de
/// la semaine reprise. Quand ce jour-là portait plusieurs repas, le premier
/// dont la recette existe encore l'emporte. Une recette déjà posée dans le
/// cycle, par la reprise ou avant elle, n'est pas reposée.
///
/// [recipesById] contient les recettes déjà résolues ; celles qui manquent
/// sont comptées, pas inventées.
WeekReplay replayWeek({
  required ReplayableWeek source,
  required List<DateTime> slotDates,
  required Map<int, Recipe?> slots,
  required Map<String, Recipe> recipesById,
}) {
  final used = <String>{
    for (final r in slots.values)
      if (r != null && r.id.isNotEmpty) r.id,
  };
  final assignments = <int, Recipe>{};
  var skippedFilled = 0;
  var skippedMissing = 0;
  var skippedNoMeal = 0;
  var skippedDuplicate = 0;

  for (var i = 0; i < slotDates.length; i++) {
    if (slots[i] != null) {
      skippedFilled++;
      continue;
    }
    final weekday = slotDates[i].weekday;
    final dayMeals = source.meals.where((m) => m.plannedAt.weekday == weekday);
    Recipe? chosen;
    var sawMissing = false;
    var sawDuplicate = false;
    var sawMeal = false;
    for (final meal in dayMeals) {
      final id = meal.recipeId;
      if (id == null || id.isEmpty) continue;
      sawMeal = true;
      final recipe = recipesById[id];
      if (recipe == null) {
        sawMissing = true;
        continue;
      }
      if (used.contains(id)) {
        sawDuplicate = true;
        continue;
      }
      chosen = recipe;
      break;
    }
    if (chosen == null) {
      if (!sawMeal) {
        skippedNoMeal++;
      } else if (sawMissing) {
        skippedMissing++;
      } else if (sawDuplicate) {
        skippedDuplicate++;
      }
      continue;
    }
    assignments[i] = chosen;
    used.add(chosen.id);
  }

  return WeekReplay(
    assignments: assignments,
    skippedFilled: skippedFilled,
    skippedMissing: skippedMissing,
    skippedNoMeal: skippedNoMeal,
    skippedDuplicate: skippedDuplicate,
  );
}
