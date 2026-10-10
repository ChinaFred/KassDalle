import 'package:cloud_firestore/cloud_firestore.dart';

import 'meal_choice_source.dart';

/// Durée pendant laquelle un refus pèse dans la présélection, après le
/// dernier. Même valeur que `REFUSAL_PENALTY_DAYS` côté serveur
/// (`functions/src/gemini/planning.ts`), verrouillée par
/// `test-fixtures/planning_slot_rules.json` (section `constants`).
const kRefusalPenaltyDays = 21;

/// Entrées gardées au plus dans le document ; les plus anciennes sortent.
/// Même valeur que `REFUSAL_MAX_ENTRIES` côté serveur.
const kRefusalMaxEntries = 300;

/// Avance tolérée d'une date de refus (horloge du téléphone). Au-delà,
/// l'entrée est ignorée. Même valeur que `REFUSAL_FUTURE_TOLERANCE_DAYS`.
const kRefusalFutureToleranceDays = 1;

/// Vrai quand écarter la recette d'un repas compte comme un refus : elle
/// avait été proposée par l'IA, par les règles de Kass'Dalle, ou conçue par
/// l'IA. Une recette choisie à la main, ou d'origine inconnue (repas
/// antérieur au champ `choice_source`), ne compte pas.
bool countsAsRefusal(MealChoiceSource? source) =>
    source != null && source != MealChoiceSource.manual;

/// Un refus : date du dernier, et nombre de refus depuis le premier encore
/// actif.
class PlanningRefusal {
  const PlanningRefusal({required this.refusedAt, required this.count});

  final DateTime refusedAt;
  final int count;

  /// Vrai tant que le dernier refus a [kRefusalPenaltyDays] jours ou moins,
  /// et n'est pas daté de plus de [kRefusalFutureToleranceDays] jour dans le
  /// futur. Même prédicat que `isRefusalActive` côté serveur, rejoué par la
  /// fixture `planning_slot_rules.json` (section `refusal_factor`).
  bool isActiveAt(DateTime now) {
    final age = now.difference(refusedAt);
    return age <= const Duration(days: kRefusalPenaltyDays) &&
        age >= -const Duration(days: kRefusalFutureToleranceDays);
  }
}

/// La mémoire des refus d'un compte :
/// `users/{uid}/preferences/planning_refusals`.
///
/// Forme Firestore : `{ entries: { recipeId: { refused_at, count } },
/// updated_at }`. Ce document appartient à son titulaire ; il n'est jamais
/// écrit dans la recette partagée. Le serveur le lit à la présélection
/// (`readUserRefusals`) et y applique la pénalité.
class PlanningRefusals {
  const PlanningRefusals(this.entries);

  static const empty = PlanningRefusals({});

  final Map<String, PlanningRefusal> entries;

  /// Lecture tolérante : une entrée sans date lisible est ignorée, un compte
  /// illisible vaut un refus.
  factory PlanningRefusals.fromFirestore(Map<String, dynamic>? data) {
    final raw = data?['entries'];
    if (raw is! Map) return empty;
    final out = <String, PlanningRefusal>{};
    raw.forEach((key, value) {
      if (key is! String || key.isEmpty || value is! Map) return;
      final at = value['refused_at'];
      final refusedAt = at is Timestamp
          ? at.toDate()
          : at is DateTime
          ? at
          : null;
      if (refusedAt == null) return;
      final count = value['count'];
      out[key] = PlanningRefusal(
        refusedAt: refusedAt,
        count: count is int && count >= 1 ? count : 1,
      );
    });
    return PlanningRefusals(out);
  }

  /// Nombre de plats refusés ces [kRefusalPenaltyDays] derniers jours.
  int activeCount(DateTime now) =>
      entries.values.where((e) => e.isActiveAt(now)).length;

  /// Ajoute les refus de [recipeIds] à [now].
  ///
  /// Les entrées expirées sortent. Un plat dont le refus est encore actif
  /// voit son compte augmenter ; sinon il repart à 1. Au plus
  /// [kRefusalMaxEntries] entrées, les plus récentes.
  PlanningRefusals record(Iterable<String> recipeIds, DateTime now) {
    final kept = <String, PlanningRefusal>{
      for (final e in entries.entries)
        if (e.value.isActiveAt(now)) e.key: e.value,
    };
    for (final id in recipeIds.where((id) => id.isNotEmpty).toSet()) {
      final previous = kept[id];
      kept[id] = PlanningRefusal(
        refusedAt: now,
        count: previous == null ? 1 : previous.count + 1,
      );
    }
    if (kept.length <= kRefusalMaxEntries) return PlanningRefusals(kept);
    final newestFirst = kept.entries.toList()
      ..sort((a, b) => b.value.refusedAt.compareTo(a.value.refusedAt));
    return PlanningRefusals({
      for (final e in newestFirst.take(kRefusalMaxEntries)) e.key: e.value,
    });
  }

  /// La carte `entries`, telle que Firestore la stocke.
  Map<String, dynamic> entriesToFirestore() => {
    for (final e in entries.entries)
      e.key: {
        'refused_at': Timestamp.fromDate(e.value.refusedAt),
        'count': e.value.count,
      },
  };
}
