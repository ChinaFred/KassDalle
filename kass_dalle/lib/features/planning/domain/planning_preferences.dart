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

/// Contraintes globales d'un compte qui n'en a jamais écrit : des règles de
/// variété que le modèle d'IA lit à chaque génération.
///
/// Sans goût personnel : ni régime, ni cuisine imposée au-delà d'une base
/// française. Chacun le retouche dans Préférences du planning. C'est aussi le
/// texte que le backfill « Contraintes de variété par défaut » pose sur les
/// comptes existants — le client l'envoie, le serveur n'en garde pas de copie.
///
/// Le texte cite encore « Paramètres du planning », l'ancien nom de l'écran :
/// il est stocké tel quel chez chaque compte, et le backfill reconnaît un
/// compte déjà traité à ce texte exact. Le changer ferait ajouter une seconde
/// copie au prochain passage.
const kDefaultGlobalConstraints =
    'VARIÉTÉ SUR LA SEMAINE (texte proposé par Kass\'Dalle, à modifier '
    'librement dans Paramètres du planning) :\n'
    '- Protéine : jamais la même protéine principale deux jours de suite. '
    'Alterner volaille, bœuf, porc, agneau, poisson, œufs, légumineuses.\n'
    '- Féculent : jamais le même féculent deux jours de suite. Pas plus de '
    '2 fois les pâtes par semaine. Alterner pâtes, riz, pommes de terre, '
    'semoule, pain.\n'
    '- Cuisine : jamais deux jours de suite une cuisine étrangère de la même '
    'région (asiatique, indienne, mexicaine, orientale…). Pas plus de 2 plats '
    'd\'une même cuisine étrangère par semaine.\n'
    '- Préférence : une majorité de cuisine française ou familiale. Les '
    'cuisines étrangères servent à varier.';

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

  /// Groupes familiaux qui voient ce planning, en lecture seule
  /// (`shared_group_ids`). Vide par défaut : rien n'est partagé tant que le
  /// compte n'a rien coché.
  ///
  /// Le serveur en tire `planning_reach/{uid}` des membres de ces groupes
  /// (déclencheur `syncPlanningReachOnConfig`). Un groupe disparu ou quitté
  /// est ignoré ; un compte qui n'est plus éditeur ne partage rien, et ses
  /// groupes restent ici, prêts pour le jour où il le redevient.
  final List<String> sharedGroupIds;

  /// Parts par défaut des repas de chaque groupe dont le compte est
  /// propriétaire (`group_portions`, identifiant du groupe → parts). Un
  /// groupe absent prend son nombre de membres (`groupDefaultPortions`).
  final Map<String, int> groupPortions;

  const PlanningPreferences({
    this.mealsPerCycle = 7,
    this.cycleStartDay = DateTime.friday,
    this.batchCookingDay,
    this.dailyConstraints = const {},
    this.globalConstraints = kDefaultGlobalConstraints,
    this.defaultMealHour = 19,
    this.defaultMealMinute = 0,
    this.defaultCalendarDurationMinutes = 60,
    this.calendarId = 'primary',
    this.calendarName = 'Principal',
    this.varietyWindowWeeks = kVarietyWindowDefaultWeeks,
    this.sharedGroupIds = const [],
    this.groupPortions = const {},
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
      // Absent : un compte qui n'a jamais réglé ses préférences reçoit les
      // règles de variété. Une chaîne vide enregistrée est un choix, gardé.
      globalConstraints:
          data['global_constraints'] as String? ?? kDefaultGlobalConstraints,
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
      sharedGroupIds: sharedGroupIdsFrom(data['shared_group_ids']),
      groupPortions: groupPortionsFrom(data['group_portions']),
    );
  }

  /// Lit `group_portions` : les entrées dont la valeur est un entier
  /// strictement positif. Une valeur mal formée est ignorée.
  static Map<String, int> groupPortionsFrom(Object? raw) {
    if (raw is! Map) return const {};
    return {
      for (final e in raw.entries)
        if (e.key is String &&
            (e.key as String).isNotEmpty &&
            e.value is int &&
            (e.value as int) > 0)
          e.key as String: e.value as int,
    };
  }

  /// Plafond de `shared_group_ids`, le même que celui des règles Firestore.
  static const maxSharedGroups = 50;

  /// Lit `shared_group_ids` : les chaînes non vides, sans doublon, dans
  /// l'ordre. Une valeur mal formée vaut une liste vide.
  static List<String> sharedGroupIdsFrom(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final value in raw) {
      if (value is String && value.isNotEmpty && !out.contains(value)) {
        out.add(value);
      }
    }
    return out;
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
    'shared_group_ids': sharedGroupIds,
    // Écrit seulement s'il porte quelque chose : l'enregistrement fusionne
    // (`SetOptions(merge: true)`), une table absente garde celle en base.
    if (groupPortions.isNotEmpty) 'group_portions': groupPortions,
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
    List<String>? sharedGroupIds,
    Map<String, int>? groupPortions,
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
    sharedGroupIds: sharedGroupIds ?? this.sharedGroupIds,
    groupPortions: groupPortions ?? this.groupPortions,
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
