/// Critères structurés du planning, côté client.
///
/// Le texte libre des préférences (préférences générales, note du jour) est
/// traduit par le serveur en critères de ce vocabulaire (poste
/// `planning_constraints`), une fois par texte modifié, et mis en cache sous
/// `users/{uid}/preferences/planning_constraints`. Le serveur vérifie le plat,
/// les entrées et les desserts ; le client vérifie les accompagnements et les
/// choix faits à la main.
///
/// Deux régimes. Une **exclusion** (allergène, protéine principale, féculent
/// principal) ne se relâche jamais. Une **préférence** (protéine ou féculent
/// voulus, durée maximale, léger) se relâche faute d'autre choix.
///
/// Logique dupliquée : `functions/src/gemini/planningCriteria.ts` porte la
/// même lecture, la même réunion et le même prédicat d'exclusion, verrouillés
/// par `test-fixtures/planning_criteria.json`. Le prédicat des préférences
/// est serveur seul.
library;

import '../../recipes/domain/allergens.dart';
import '../../recipes/domain/meal_role.dart';
import '../../recipes/domain/recipe.dart';
import 'meal_component.dart';
import 'meal_staple.dart';
import 'planning_preferences.dart';

enum CriterionRegime {
  exclusion,
  preference;

  static CriterionRegime? fromKey(Object? key) => switch (key) {
    'exclusion' => CriterionRegime.exclusion,
    'preference' => CriterionRegime.preference,
    _ => null,
  };
}

/// Les clés, dans l'ordre du vocabulaire.
enum CriterionKey {
  excludedAllergens('excluded_allergens', CriterionRegime.exclusion),
  excludedProteins('excluded_proteins', CriterionRegime.exclusion),
  excludedStarches('excluded_starches', CriterionRegime.exclusion),
  wantedProteins('wanted_proteins', CriterionRegime.preference),
  wantedStarches('wanted_starches', CriterionRegime.preference),
  maxDuration('max_duration', CriterionRegime.preference),
  light('light', CriterionRegime.preference);

  final String key;
  final CriterionRegime regime;
  const CriterionKey(this.key, this.regime);

  static CriterionKey? fromKey(Object? key) {
    for (final k in values) {
      if (k.key == key) return k;
    }
    return null;
  }
}

/// Bornes d'une durée maximale lue, en minutes. Hors bornes : absente.
const int kMaxDurationMin = 5;
const int kMaxDurationMax = 600;

List<String> _vocabularyList(Object? raw, List<String> vocabulary) {
  if (raw is! List) return const [];
  final wanted = raw.whereType<String>().toSet();
  return [
    for (final v in vocabulary)
      if (wanted.contains(v)) v,
  ];
}

int? _readDuration(Object? raw) {
  if (raw is! int) return null;
  return raw >= kMaxDurationMin && raw <= kMaxDurationMax ? raw : null;
}

/// Les critères d'un texte, ou d'un créneau une fois réunis.
class PlanningCriteria {
  final List<String> excludedAllergens;
  final List<String> excludedProteins;
  final List<String> excludedStarches;
  final List<String> wantedProteins;
  final List<String> wantedStarches;

  /// Préparation maximale, en minutes ; `null` sans limite.
  final int? maxDuration;
  final bool light;

  const PlanningCriteria({
    this.excludedAllergens = const [],
    this.excludedProteins = const [],
    this.excludedStarches = const [],
    this.wantedProteins = const [],
    this.wantedStarches = const [],
    this.maxDuration,
    this.light = false,
  });

  static const empty = PlanningCriteria();

  /// Une valeur exclue quitte la liste voulue : l'exclusion l'emporte.
  PlanningCriteria _withoutConflicts() => PlanningCriteria(
    excludedAllergens: excludedAllergens,
    excludedProteins: excludedProteins,
    excludedStarches: excludedStarches,
    wantedProteins: [
      for (final p in wantedProteins)
        if (!excludedProteins.contains(p)) p,
    ],
    wantedStarches: [
      for (final s in wantedStarches)
        if (!excludedStarches.contains(s)) s,
    ],
    maxDuration: maxDuration,
    light: light,
  );

  /// Lecture tolérante d'un objet stocké, en snake_case : une valeur hors
  /// vocabulaire est écartée.
  factory PlanningCriteria.fromMap(Object? raw) {
    if (raw is! Map) return empty;
    return PlanningCriteria(
      excludedAllergens: _vocabularyList(
        raw['excluded_allergens'],
        kAllergenKeys,
      ),
      excludedProteins: _vocabularyList(
        raw['excluded_proteins'],
        kMainProteins,
      ),
      excludedStarches: _vocabularyList(
        raw['excluded_starches'],
        kMainStarches,
      ),
      wantedProteins: _vocabularyList(raw['wanted_proteins'], kMainProteins),
      wantedStarches: _vocabularyList(raw['wanted_starches'], kMainStarches),
      maxDuration: _readDuration(raw['max_duration']),
      light: raw['light'] == true,
    )._withoutConflicts();
  }

  /// La forme canonique : les sept clés.
  Map<String, Object?> toMap() => {
    'excluded_allergens': excludedAllergens,
    'excluded_proteins': excludedProteins,
    'excluded_starches': excludedStarches,
    'wanted_proteins': wantedProteins,
    'wanted_starches': wantedStarches,
    'max_duration': maxDuration,
    'light': light,
  };

  /// Préférences générales et note du jour réunies : listes en union, durée
  /// la plus courte, léger si l'un le dit.
  static PlanningCriteria merge(Iterable<PlanningCriteria> parts) {
    final list = parts.toList(growable: false);
    List<String> union(
      List<String> Function(PlanningCriteria) pick,
      List<String> vocabulary,
    ) => _vocabularyList([for (final p in list) ...pick(p)], vocabulary);
    final durations = [
      for (final p in list)
        if (p.maxDuration != null) p.maxDuration!,
    ];
    return PlanningCriteria(
      excludedAllergens: union((p) => p.excludedAllergens, kAllergenKeys),
      excludedProteins: union((p) => p.excludedProteins, kMainProteins),
      excludedStarches: union((p) => p.excludedStarches, kMainStarches),
      wantedProteins: union((p) => p.wantedProteins, kMainProteins),
      wantedStarches: union((p) => p.wantedStarches, kMainStarches),
      maxDuration: durations.isEmpty
          ? null
          : durations.reduce((a, b) => a < b ? a : b),
      light: list.any((p) => p.light),
    )._withoutConflicts();
  }

  bool get hasExclusions =>
      excludedAllergens.isNotEmpty ||
      excludedProteins.isNotEmpty ||
      excludedStarches.isNotEmpty;

  /// Ce que le client affiche après « Compris : » — « sans porc · sans
  /// gluten · 30 min max ». La protéine et le féculent exclus ne portent que
  /// sur la valeur principale de la recette.
  List<String> get labels => [
    for (final p in excludedProteins) 'sans ${_proteinWord(p)}',
    for (final a in excludedAllergens) 'sans ${allergenLabel(a).toLowerCase()}',
    for (final s in excludedStarches)
      s == 'aucun' ? 'avec un féculent' : 'sans ${_starchWord(s)}',
    if (wantedProteins.isNotEmpty)
      'plutôt ${wantedProteins.map(_proteinWord).join(' ou ')}',
    if (wantedStarches.isNotEmpty)
      'plutôt ${wantedStarches.map(_starchWord).join(' ou ')}',
    if (maxDuration != null) '$maxDuration min max',
    if (light) 'léger',
  ];
}

String _proteinWord(String key) => switch (key) {
  'boeuf' => 'bœuf',
  'oeuf' => 'œufs',
  'fruits_de_mer' => 'fruits de mer',
  'vegetarien' => 'végétarien',
  'legumineuses' => 'légumineuses',
  _ => key,
};

String _starchWord(String key) => switch (key) {
  'pates' => 'pâtes',
  'pommes_de_terre' => 'pommes de terre',
  'aucun' => 'sans féculent',
  _ => key,
};

/// Ce que le prédicat sait d'un élément.
class CriteriaItem {
  /// Clés présentes et liste complète ; `null` quand on ne sait rien.
  final ({List<String> present, bool complete})? allergens;
  final String? mainProtein;
  final String? mainStarch;

  /// Une garniture, dont les allergènes se saisissent à la main : absents,
  /// ils sont « non renseignés ». Ceux d'une recette se calculent : absents
  /// ou incomplets, ils sont « non vérifiés ».
  final bool isStaple;

  const CriteriaItem({
    this.allergens,
    this.mainProtein,
    this.mainStarch,
    this.isStaple = false,
  });

  /// Une recette : son champ `allergens` (serveur seul) et ses protéine et
  /// féculent principaux.
  factory CriteriaItem.ofRecipe(Recipe r) {
    final a = r.allergens;
    return CriteriaItem(
      allergens: a == null ? null : (present: a.present, complete: a.complete),
      mainProtein: r.tags.mainProtein,
      mainStarch: r.tags.mainStarch,
    );
  }

  /// Une garniture : ses allergènes saisis à la main (absents = non
  /// renseignés), et le féculent lu dans son nom — « Pâtes fraîches » est des
  /// pâtes. Une garniture d'une famille sans féculent (légume, salade,
  /// fromage, fruit, laitage) n'en porte pas. La protéine n'est pas connue.
  factory CriteriaItem.ofStaple(MealStaple s) {
    final allergens = s.allergens;
    return CriteriaItem(
      allergens: allergens == null
          ? null
          : (present: allergens, complete: true),
      mainStarch: stapleMainStarch(s),
      isStaple: true,
    );
  }
}

/// Le féculent d'une garniture, lu dans son identifiant de nom ; `aucun`
/// pour une famille qui n'en porte pas ; `null` quand on ne sait pas.
String? stapleMainStarch(MealStaple s) {
  final id = stapleIdFromName(s.name);
  for (final starch in kMainStarches) {
    if (starch == 'aucun') continue;
    if (id == starch || id.startsWith('${starch}_')) return starch;
  }
  if (s.category == StapleCategory.pain) return 'pain';
  return switch (s.category) {
    StapleCategory.legume ||
    StapleCategory.salade ||
    StapleCategory.fromage ||
    StapleCategory.fruit ||
    StapleCategory.laitage => 'aucun',
    StapleCategory.feculent ||
    StapleCategory.pain ||
    StapleCategory.autre => null,
  };
}

enum CriterionVerdict { ok, violates, unknown }

/// Le résultat du prédicat pour un critère.
class CriterionCheck {
  final CriterionKey key;
  final CriterionVerdict verdict;

  /// Ce qui est en cause, ou ce qui n'a pas pu être vérifié.
  final List<String> values;

  const CriterionCheck(this.key, this.verdict, [this.values = const []]);
}

/// Prédicat d'exclusion : un résultat par exclusion active.
///
/// Une donnée absente ne prouve rien : un allergène exclu absent d'une liste
/// incomplète, une protéine inconnue rendent `unknown`, jamais `ok`.
List<CriterionCheck> checkExclusions(PlanningCriteria c, CriteriaItem item) {
  final out = <CriterionCheck>[];
  if (c.excludedAllergens.isNotEmpty) {
    final present = (item.allergens?.present ?? const <String>[]).toSet();
    final found = [
      for (final a in c.excludedAllergens)
        if (present.contains(a)) a,
    ];
    if (found.isNotEmpty) {
      out.add(
        CriterionCheck(
          CriterionKey.excludedAllergens,
          CriterionVerdict.violates,
          found,
        ),
      );
    } else if (item.allergens == null || !item.allergens!.complete) {
      out.add(
        CriterionCheck(
          CriterionKey.excludedAllergens,
          CriterionVerdict.unknown,
          c.excludedAllergens,
        ),
      );
    } else {
      out.add(
        const CriterionCheck(
          CriterionKey.excludedAllergens,
          CriterionVerdict.ok,
        ),
      );
    }
  }
  void exclusionOf(
    CriterionKey key,
    List<String> excluded,
    String? value,
    List<String> vocabulary,
  ) {
    if (excluded.isEmpty) return;
    final v = value != null && vocabulary.contains(value) ? value : null;
    if (v == null) {
      out.add(CriterionCheck(key, CriterionVerdict.unknown, excluded));
    } else if (excluded.contains(v)) {
      out.add(CriterionCheck(key, CriterionVerdict.violates, [v]));
    } else {
      out.add(CriterionCheck(key, CriterionVerdict.ok));
    }
  }

  exclusionOf(
    CriterionKey.excludedProteins,
    c.excludedProteins,
    item.mainProtein,
    kMainProteins,
  );
  exclusionOf(
    CriterionKey.excludedStarches,
    c.excludedStarches,
    item.mainStarch,
    kMainStarches,
  );
  return out;
}

/// Vrai si l'élément viole une exclusion de [c].
bool violatesExclusion(PlanningCriteria c, CriteriaItem item) =>
    checkExclusions(c, item).any((r) => r.verdict == CriterionVerdict.violates);

/// Vrai si toutes les exclusions de [c] sont vérifiées pour l'élément.
bool exclusionsVerified(PlanningCriteria c, CriteriaItem item) =>
    checkExclusions(c, item).every((r) => r.verdict == CriterionVerdict.ok);

/// Le signal d'un choix fait à la main : « contient : gluten, porc », ou,
/// quand rien ne viole mais qu'un allergène exclu n'a pas pu être vérifié,
/// « allergènes non renseignés » pour une garniture et « allergènes non
/// vérifiés » pour une recette. `null` sans rien à dire.
String? exclusionWarning(PlanningCriteria c, CriteriaItem item) {
  final checks = checkExclusions(c, item);
  final violated = [
    for (final r in checks)
      if (r.verdict == CriterionVerdict.violates)
        for (final v in r.values)
          switch (r.key) {
            CriterionKey.excludedAllergens => allergenLabel(v).toLowerCase(),
            CriterionKey.excludedProteins => _proteinWord(v),
            _ => _starchWord(v),
          },
  ];
  if (violated.isNotEmpty) return 'contient : ${violated.join(', ')}';
  final allergensUnknown = checks.any(
    (r) =>
        r.key == CriterionKey.excludedAllergens &&
        r.verdict == CriterionVerdict.unknown,
  );
  if (!allergensUnknown) return null;
  return item.isStaple
      ? 'allergènes non renseignés'
      : 'allergènes non vérifiés';
}

// ── Traductions des textes ───────────────────────────────────────────────────

/// Ce que le serveur a compris d'un texte libre.
class ConstraintTranslation {
  /// Le texte traduit, sans espaces en bord.
  final String text;
  final PlanningCriteria criteria;

  /// Ce que le modèle n'a pas su traduire : transmis à l'IA, non vérifié.
  final String untranslated;

  /// Faux quand la traduction a échoué : tout le texte part au prompt.
  final bool translated;

  const ConstraintTranslation({
    required this.text,
    required this.criteria,
    required this.untranslated,
    this.translated = true,
  });

  /// Une traduction en échec : tout le texte reste non vérifié.
  const ConstraintTranslation.failed(this.text)
    : criteria = PlanningCriteria.empty,
      untranslated = text,
      translated = false;

  /// Lecture tolérante d'une entrée du cache ou de la réponse du planning.
  static ConstraintTranslation? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final text = raw['text'];
    if (text is! String || text.trim().isEmpty) return null;
    final status = raw['status'];
    if (status == 'failed' || status == 'skipped') {
      return ConstraintTranslation.failed(text.trim());
    }
    final untranslated = raw['untranslated'];
    return ConstraintTranslation(
      text: text.trim(),
      criteria: PlanningCriteria.fromMap(raw['criteria']),
      untranslated: untranslated is String ? untranslated.trim() : '',
    );
  }
}

/// Les entrées du document `users/{uid}/preferences/planning_constraints`,
/// par texte.
Map<String, ConstraintTranslation> readConstraintTranslations(
  Map<String, dynamic>? data,
) {
  final entries = data?['entries'];
  if (entries is! Map) return const {};
  final out = <String, ConstraintTranslation>{};
  for (final e in entries.values) {
    final t = ConstraintTranslation.fromMap(e);
    if (t != null) out[t.text] = t;
  }
  return out;
}

/// Les critères compris pour [texts] — préférences générales, note du jour
/// —, réunis. Un texte absent des traductions ne compte pas.
PlanningCriteria criteriaForTexts(
  Map<String, ConstraintTranslation> translations,
  Iterable<String> texts,
) => PlanningCriteria.merge([
  for (final t in texts)
    if (translations[t.trim()] case final tr?) tr.criteria,
]);

/// Les critères compris d'un repas à la date [date] : les préférences
/// générales, puis la note du jour — celle de [dayConstraint] quand l'écran
/// en porte une à lui (Nouveau planning), sinon celle du jour de semaine.
PlanningCriteria criteriaForDay({
  required PlanningPreferences prefs,
  required Map<String, ConstraintTranslation> translations,
  required DateTime date,
  DayConstraint? dayConstraint,
}) => criteriaForTexts(translations, [
  prefs.globalConstraints,
  (dayConstraint ?? prefs.dailyConstraints[date.weekday])?.notes ?? '',
]);

// ── Écarts stockés sur le repas ──────────────────────────────────────────────

/// Un critère que le choix ne tient pas, ou n'a pas pu vérifier — rendu par
/// le serveur, stocké sur le repas (`unmet_criteria`).
class UnmetCriterion {
  /// Clé du critère ; gardée telle quelle si cette version ne la connaît pas.
  final String key;
  final CriterionRegime regime;

  /// `relaxed` (préférence relâchée), `empty` (exclusion sans candidat),
  /// `unverified` (exclusion que la donnée ne permet pas de vérifier).
  final String status;

  /// `plat`, `entree` ou `dessert`.
  final String service;

  /// Phrase du serveur, prête à afficher.
  final String detail;

  const UnmetCriterion({
    required this.key,
    required this.regime,
    required this.status,
    required this.service,
    required this.detail,
  });

  bool get isEmptyService => status == 'empty';

  /// Lecture tolérante ; `null` sans clé, régime ou phrase.
  static UnmetCriterion? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final key = raw['key'];
    final regime = CriterionRegime.fromKey(raw['regime']);
    final detail = raw['detail'];
    if (key is! String || key.isEmpty || regime == null) return null;
    if (detail is! String || detail.trim().isEmpty) return null;
    final status = raw['status'];
    final service = raw['service'];
    return UnmetCriterion(
      key: key,
      regime: regime,
      status: status is String ? status : '',
      service: service is String && service.isNotEmpty ? service : 'plat',
      detail: detail.trim(),
    );
  }

  static List<UnmetCriterion> listFrom(Object? raw) => [
    if (raw is List)
      for (final item in raw) ?fromMap(item),
  ];

  Map<String, dynamic> toMap() => {
    'key': key,
    'regime': regime.name,
    'status': status,
    'service': service,
    'detail': detail,
  };

  @override
  bool operator ==(Object other) =>
      other is UnmetCriterion &&
      other.key == key &&
      other.regime == regime &&
      other.status == status &&
      other.service == service &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(key, regime, status, service, detail);
}

/// Les écarts d'un repas après « Autre suggestion » : ceux du plat proposé,
/// puis ceux des autres services déjà posés sur le repas, qui n'ont pas
/// changé.
List<UnmetCriterion> unmetWithNewDish({
  required List<UnmetCriterion> current,
  required List<UnmetCriterion> proposed,
}) => [
  for (final u in proposed)
    if (u.service == 'plat') u,
  for (final u in current)
    if (u.service != 'plat') u,
];

/// Le contenu du premier service de [role] : sa source, ou `null` s'il est
/// absent ou « à choisir ».
String? _firstCourseKey(
  List<MealComponent> components,
  MealComponentRole role,
) {
  for (final c in components) {
    if (c.role != role) continue;
    return c.isEmptyCourse ? null : c.sourceId;
  }
  return null;
}

/// Les écarts qui restent après un geste à la main sur les services d'un
/// repas : l'entrée ou le dessert dont le contenu a changé — rempli, remplacé,
/// vidé ou retiré — perd ses écarts : le choix est celui de la personne. Un
/// service resté identique, « à choisir » compris, garde les siens. Le
/// premier service de chaque type compte : c'est celui que le planning
/// propose.
List<UnmetCriterion> unmetAfterManualCourses({
  required List<UnmetCriterion> unmet,
  required List<MealComponent> before,
  required List<MealComponent> after,
}) {
  if (unmet.isEmpty) return unmet;
  final filled = <String>{
    for (final (role, service) in const [
      (MealComponentRole.entree, 'entree'),
      (MealComponentRole.dessert, 'dessert'),
    ])
      if (_firstCourseKey(after, role) != _firstCourseKey(before, role))
        service,
  };
  if (filled.isEmpty) return unmet;
  return [
    for (final u in unmet)
      if (!filled.contains(u.service)) u,
  ];
}
