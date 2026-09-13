// Modèle de données pour les préférences de planification des repas.
//
// Stocké dans Firestore : planning_config/{uid}

import 'meal_format.dart';
import 'planning_history.dart';

export 'meal_format.dart';

const Map<int, String> kWeekdayNames = {
  DateTime.monday: 'Lundi',
  DateTime.tuesday: 'Mardi',
  DateTime.wednesday: 'Mercredi',
  DateTime.thursday: 'Jeudi',
  DateTime.friday: 'Vendredi',
  DateTime.saturday: 'Samedi',
  DateTime.sunday: 'Dimanche',
};

String weekdayLabel(int weekday) => kWeekdayNames[weekday] ?? '?';

/// Contrainte quotidienne pour un jour de la semaine donné.
class DayConstraint {
  /// Durée maximale de préparation en minutes (0 = pas de limite).
  final int maxPrepMinutes;

  /// Nombre de parts à préparer ce jour (0 = utiliser les portions de la recette).
  final int targetPortions;

  /// Vrai si ce jour est dédié au batch cooking (réchauffage uniquement).
  final bool isBatchCooking;

  /// Contrainte en langage naturel (ex: "Repas léger, sport le soir").
  final String notes;

  /// Heure du repas ce jour-là, quand elle diffère de l'heure par défaut.
  ///
  /// `null` veut dire « comme les autres jours » — et non « minuit ». Stocker
  /// une copie de l'heure globale sur chaque jour aurait figé sept valeurs que
  /// plus rien ne ramènerait ensemble : changer le défaut n'aurait plus rien
  /// changé, sans que rien ne l'explique.
  final int? mealHour;
  final int? mealMinute;

  /// Le format du repas ce jour-là : plat seul, plat et dessert, entrée et
  /// plat, le repas complet, ou léger.
  ///
  /// `null` veut dire « le défaut », le plat seul — et non un format de plus.
  /// Rien ne change pour un planning qui n'en dit rien.
  final MealFormat? mealFormat;

  const DayConstraint({
    this.maxPrepMinutes = 0,
    this.targetPortions = 0,
    this.isBatchCooking = false,
    this.notes = '',
    this.mealHour,
    this.mealMinute,
    this.mealFormat,
  });

  /// Vrai si ce jour porte sa propre heure.
  bool get hasOwnTime => mealHour != null;

  /// Le format appliqué : celui du jour, ou le plat seul.
  MealFormat get effectiveFormat => mealFormat ?? MealFormat.defaultFormat;

  factory DayConstraint.fromMap(Map<String, dynamic> data) => DayConstraint(
    maxPrepMinutes: data['max_prep_minutes'] as int? ?? 0,
    targetPortions: data['target_portions'] as int? ?? 0,
    isBatchCooking: data['is_batch_cooking'] as bool? ?? false,
    notes: data['notes'] as String? ?? '',
    mealHour: data['meal_hour'] as int?,
    mealMinute: data['meal_minute'] as int?,
    mealFormat: MealFormat.fromKey(data['meal_format'] as String?),
  );

  Map<String, dynamic> toMap() => {
    'max_prep_minutes': maxPrepMinutes,
    'target_portions': targetPortions,
    'is_batch_cooking': isBatchCooking,
    'notes': notes,
    // Écrites seulement quand le jour a son heure : un `null` stocké et une
    // clé absente se relisent pareil, mais l'absence dit mieux ce qu'elle est.
    if (mealHour != null) 'meal_hour': mealHour,
    if (mealMinute != null) 'meal_minute': mealMinute,
    if (mealFormat != null) 'meal_format': mealFormat!.key,
  };

  DayConstraint copyWith({
    int? maxPrepMinutes,
    int? targetPortions,
    bool? isBatchCooking,
    String? notes,
    int? mealHour,
    int? mealMinute,
    MealFormat? mealFormat,

    /// Rend le jour à l'heure par défaut. Un `copyWith` ne peut pas remettre un
    /// champ à `null` — sans ce drapeau, une heure posée ne se retirerait plus.
    bool clearMealTime = false,

    /// Rend le jour au format par défaut, pour la même raison.
    bool clearMealFormat = false,
  }) => DayConstraint(
    maxPrepMinutes: maxPrepMinutes ?? this.maxPrepMinutes,
    targetPortions: targetPortions ?? this.targetPortions,
    isBatchCooking: isBatchCooking ?? this.isBatchCooking,
    notes: notes ?? this.notes,
    mealHour: clearMealTime ? null : (mealHour ?? this.mealHour),
    mealMinute: clearMealTime ? null : (mealMinute ?? this.mealMinute),
    mealFormat: clearMealFormat ? null : (mealFormat ?? this.mealFormat),
  );

  bool get isEmpty =>
      maxPrepMinutes == 0 &&
      targetPortions == 0 &&
      !isBatchCooking &&
      notes.trim().isEmpty &&
      mealHour == null &&
      mealFormat == null;
}

/// Préférences globales de planification.
class PlanningPreferences {
  /// Nombre de repas par cycle (ex: 7 pour une semaine).
  final int mealsPerCycle;

  /// Jour de démarrage du cycle (1=Lundi … 7=Dimanche).
  final int cycleStartDay;

  /// Jour de batch cooking dans le cycle (nullable = aucun).
  final int? batchCookingDay;

  /// Contraintes par jour de la semaine (clé = DateTime.weekday).
  final Map<int, DayConstraint> dailyConstraints;

  /// Contraintes globales en langage naturel (ex: "Pas de poisson deux fois").
  final String globalConstraints;

  /// Heure par défaut des repas (0–23).
  final int defaultMealHour;

  /// Minutes par défaut des repas.
  final int defaultMealMinute;

  /// Durée par défaut des événements Google Calendar, en minutes.
  final int defaultCalendarDurationMinutes;

  /// Identifiant du calendrier Google cible ("primary" = calendrier principal).
  final String calendarId;

  /// Nom du calendrier Google cible (pour affichage).
  final String calendarName;

  /// Fenêtre de variété, en semaines : un plat servi dans les N semaines qui
  /// précèdent le cycle n'est pas reproposé. Zéro la désactive.
  ///
  /// Une préférence et non une constante : une famille de trois recettes
  /// fétiches ne veut pas la même fenêtre qu'un corpus de deux cents.
  final int varietyWindowWeeks;

  const PlanningPreferences({
    this.mealsPerCycle = 7,
    this.cycleStartDay = DateTime.friday,
    this.batchCookingDay,
    this.dailyConstraints = const {},
    this.globalConstraints = '',
    this.defaultMealHour = 19,
    this.defaultMealMinute = 0,
    this.defaultCalendarDurationMinutes = 60,
    this.calendarId = 'primary',
    this.calendarName = 'Principal',
    this.varietyWindowWeeks = kVarietyWindowDefaultWeeks,
  });

  factory PlanningPreferences.fromFirestore(Map<String, dynamic> data) {
    final dailyRaw = data['daily_constraints'] as Map<String, dynamic>? ?? {};
    return PlanningPreferences(
      mealsPerCycle: data['meals_per_cycle'] as int? ?? 7,
      cycleStartDay: data['cycle_start_day'] as int? ?? DateTime.friday,
      batchCookingDay: data['batch_cooking_day'] as int?,
      dailyConstraints: {
        for (final e in dailyRaw.entries)
          int.parse(e.key): DayConstraint.fromMap(
            Map<String, dynamic>.from(e.value as Map),
          ),
      },
      globalConstraints: data['global_constraints'] as String? ?? '',
      defaultMealHour: data['default_meal_hour'] as int? ?? 19,
      defaultMealMinute: data['default_meal_minute'] as int? ?? 0,
      defaultCalendarDurationMinutes:
          data['default_calendar_duration_minutes'] as int? ?? 60,
      calendarId: data['calendar_id'] as String? ?? 'primary',
      calendarName: data['calendar_name'] as String? ?? 'Principal',
      // Absent = le défaut, et jamais hors bornes : une valeur écrite à la
      // main dans la console ne fait pas remonter dix ans de repas.
      varietyWindowWeeks: clampVarietyWindow(
        data['variety_window_weeks'] as int? ?? kVarietyWindowDefaultWeeks,
      ),
    );
  }

  Map<String, dynamic> toFirestore() => {
    'meals_per_cycle': mealsPerCycle,
    'cycle_start_day': cycleStartDay,
    'batch_cooking_day': batchCookingDay,
    'daily_constraints': {
      for (final e in dailyConstraints.entries)
        e.key.toString(): e.value.toMap(),
    },
    'global_constraints': globalConstraints,
    'default_meal_hour': defaultMealHour,
    'default_meal_minute': defaultMealMinute,
    'default_calendar_duration_minutes': defaultCalendarDurationMinutes,
    'calendar_id': calendarId,
    'calendar_name': calendarName,
    'variety_window_weeks': varietyWindowWeeks,
  };

  PlanningPreferences copyWith({
    int? mealsPerCycle,
    int? cycleStartDay,
    int? batchCookingDay,
    Map<int, DayConstraint>? dailyConstraints,
    String? globalConstraints,
    bool clearBatchCookingDay = false,
    int? defaultMealHour,
    int? defaultMealMinute,
    int? defaultCalendarDurationMinutes,
    String? calendarId,
    String? calendarName,
    int? varietyWindowWeeks,
  }) => PlanningPreferences(
    mealsPerCycle: mealsPerCycle ?? this.mealsPerCycle,
    cycleStartDay: cycleStartDay ?? this.cycleStartDay,
    batchCookingDay: clearBatchCookingDay
        ? null
        : (batchCookingDay ?? this.batchCookingDay),
    dailyConstraints: dailyConstraints ?? this.dailyConstraints,
    globalConstraints: globalConstraints ?? this.globalConstraints,
    defaultMealHour: defaultMealHour ?? this.defaultMealHour,
    defaultMealMinute: defaultMealMinute ?? this.defaultMealMinute,
    defaultCalendarDurationMinutes:
        defaultCalendarDurationMinutes ?? this.defaultCalendarDurationMinutes,
    calendarId: calendarId ?? this.calendarId,
    calendarName: calendarName ?? this.calendarName,
    varietyWindowWeeks: clampVarietyWindow(
      varietyWindowWeeks ?? this.varietyWindowWeeks,
    ),
  );

  /// Heure retenue pour un jour de la semaine : la sienne s'il en a une, celle
  /// de tout le monde sinon.
  ///
  /// Une seule fonction répond à cette question, et tout ce qui affiche ou
  /// planifie l'appelle : deux endroits qui la recalculent finissent par ne
  /// plus dire la même heure.
  ({int hour, int minute}) mealTimeFor(int weekday) {
    final day = dailyConstraints[weekday];
    if (day != null && day.mealHour != null) {
      return (hour: day.mealHour!, minute: day.mealMinute ?? 0);
    }
    return (hour: defaultMealHour, minute: defaultMealMinute);
  }

  /// Change l'heure par défaut **et** ramène tous les jours à cette heure.
  ///
  /// C'est la décision qui rend l'heure par jour utilisable : sans remise à
  /// zéro, régler l'heure globale n'aurait plus d'effet visible dès qu'un seul
  /// jour aurait été personnalisé — et l'utilisateur devrait deviner lesquels
  /// des sept jours résistent, et pourquoi.
  PlanningPreferences withDefaultMealTime(int hour, int minute) => copyWith(
    defaultMealHour: hour,
    defaultMealMinute: minute,
    dailyConstraints: {
      for (final e in dailyConstraints.entries)
        e.key: e.value.copyWith(clearMealTime: true),
    },
  );

  /// Calcule les dates du prochain cycle à partir d'aujourd'hui.
  ///
  /// Le cycle commence au prochain [cycleStartDay], aujourd'hui compris :
  /// ouvrir l'écran un vendredi quand le cycle démarre le vendredi doit
  /// proposer ce vendredi-ci, pas le suivant.
  List<DateTime> nextCycleDates() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final daysUntilStart = (cycleStartDay - today.weekday + 7) % 7;
    final start = today.add(Duration(days: daysUntilStart));
    return List.generate(mealsPerCycle, (i) => start.add(Duration(days: i)));
  }
}
