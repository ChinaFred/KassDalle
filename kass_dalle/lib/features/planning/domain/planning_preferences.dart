/// Modèle de données pour les préférences de planification des repas.
///
/// Stocké dans Firestore : planning_config/{uid}

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

  /// Vrai si ce jour est dédié au batch cooking (réchauffage uniquement).
  final bool isBatchCooking;

  /// Contrainte en langage naturel (ex: "Repas léger, sport le soir").
  final String notes;

  const DayConstraint({
    this.maxPrepMinutes = 0,
    this.isBatchCooking = false,
    this.notes = '',
  });

  factory DayConstraint.fromMap(Map<String, dynamic> data) => DayConstraint(
    maxPrepMinutes: data['max_prep_minutes'] as int? ?? 0,
    isBatchCooking: data['is_batch_cooking'] as bool? ?? false,
    notes: data['notes'] as String? ?? '',
  );

  Map<String, dynamic> toMap() => {
    'max_prep_minutes': maxPrepMinutes,
    'is_batch_cooking': isBatchCooking,
    'notes': notes,
  };

  DayConstraint copyWith({
    int? maxPrepMinutes,
    bool? isBatchCooking,
    String? notes,
  }) => DayConstraint(
    maxPrepMinutes: maxPrepMinutes ?? this.maxPrepMinutes,
    isBatchCooking: isBatchCooking ?? this.isBatchCooking,
    notes: notes ?? this.notes,
  );

  bool get isEmpty =>
      maxPrepMinutes == 0 && !isBatchCooking && notes.trim().isEmpty;
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

  const PlanningPreferences({
    this.mealsPerCycle = 7,
    this.cycleStartDay = DateTime.friday,
    this.batchCookingDay,
    this.dailyConstraints = const {},
    this.globalConstraints = '',
    this.defaultMealHour = 19,
    this.defaultMealMinute = 0,
  });

  factory PlanningPreferences.fromFirestore(Map<String, dynamic> data) {
    final dailyRaw =
        data['daily_constraints'] as Map<String, dynamic>? ?? {};
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
  );

  /// Calcule les dates du prochain cycle à partir d'aujourd'hui.
  /// Le cycle commence au prochain [cycleStartDay] (au moins demain).
  List<DateTime> nextCycleDates() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    int daysUntilStart = (cycleStartDay - today.weekday + 7) % 7;
    if (daysUntilStart == 0) daysUntilStart = 7;
    final start = today.add(Duration(days: daysUntilStart));
    return List.generate(mealsPerCycle, (i) => start.add(Duration(days: i)));
  }
}
