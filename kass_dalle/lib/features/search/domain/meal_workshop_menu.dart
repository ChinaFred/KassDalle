/// Le menu de l'atelier repas (Explorer › « Composer un repas avec l'IA »),
/// tel que le serveur le rend après contrôle, et les bornes de la
/// conversation.
///
/// Rien n'est enregistré avant le figement : le menu vit en mémoire de
/// l'écran. Ce fichier lit la réponse de `mealWorkshopTurnFn`, compare deux
/// menus pour poser la puce « Modifié » et détecter « Menu inchangé », lit le
/// compteur du jour, et décide des parts par défaut. Fonctions pures, testées
/// dans `test/meal_workshop_menu_test.dart`.
///
/// Les bornes existent aussi côté serveur (`functions/src/gemini/mealWorkshop.ts`) :
/// `test-fixtures/meal_workshop_rules.json` les verrouille des deux côtés
/// (tableau « Logique dupliquée Dart ↔ TypeScript » de `CLAUDE.md`).
library;

import 'dart:convert';
import 'dart:math';

import '../../groups/domain/family_group.dart';
import '../../planning/domain/meal_component.dart';
import '../../planning/domain/planning_target.dart';

/// Tours au plus par conversation : le 21e message est refusé par l'écran,
/// et par le serveur (`MEAL_WORKSHOP_MAX_TURNS`).
const int kWorkshopMaxTurns = 20;

/// Services de rôle « plat » au plus en mode plat : le plat, et la recette
/// d'un accompagnement en service secondaire (`MEAL_WORKSHOP_MAX_DISH_COURSES`).
const int kWorkshopMaxDishCourses = 2;

/// Caractères au plus par message de la personne
/// (`MEAL_WORKSHOP_MAX_MESSAGE_CHARS`).
const int kWorkshopMaxMessageChars = 1500;

/// Caractères au plus par réponse du modèle rejouée dans l'historique
/// (`MEAL_WORKSHOP_MAX_ASSISTANT_CHARS`). Le serveur coupe sa réponse à cette
/// taille ; le client ne rejoue que ce qu'il a reçu.
const int kWorkshopMaxAssistantChars = 6000;

/// Tours par jour et par compte, avant multiplicateur de budget
/// (`MEAL_WORKSHOP_DAILY_LIMIT`). Affiché tant que le compteur du jour
/// n'existe pas encore.
const int kWorkshopDailyLimit = 30;

/// Parts du menu sans groupe familial actif ([defaultMealWorkshopPortions]).
const int kWorkshopDefaultPortions = 4;

/// Au-delà, le texte d'une réponse se replie sous « Lire la suite ».
const int kWorkshopReplyFoldChars = 1500;

/// `details.reason` d'une réponse que le contrôle serveur a refusée : le
/// tour a été facturé et compté.
const String kWorkshopUnreadableReason = 'meal_workshop_unreadable';

/// `details.reason` d'un 21e tour refusé par le serveur.
const String kWorkshopMaxTurnsReason = 'meal_workshop_max_turns';

/// `details.reason` du plafond de tours du jour.
const String kWorkshopDailyQuotaReason = 'meal_workshop_daily_quota';

/// `details.reason` d'une rédaction de plat figé dont le modèle n'a pas
/// rendu de recette lisible : « Non rédigée. L'IA n'a pas rendu de
/// recette. »
const String kWorkshopRecipeUnreadableReason =
    'meal_workshop_recipe_unreadable';

/// Caractères admis dans un identifiant de conversation, et sa longueur :
/// le serveur refuse hors de `[A-Za-z0-9_-]{8,64}`.
const String _conversationIdAlphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-';
const int kWorkshopConversationIdLength = 24;

/// Un identifiant de conversation, tiré par le client à chaque nouvelle
/// conversation : c'est l'`entity_id` des lignes `ai_usage` des deux postes,
/// qui relie les tours et les plats figés d'une même conversation.
String newWorkshopConversationId([Random? random]) {
  final rng = random ?? Random.secure();
  final buffer = StringBuffer();
  for (var i = 0; i < kWorkshopConversationIdLength; i++) {
    buffer.write(
      _conversationIdAlphabet[rng.nextInt(_conversationIdAlphabet.length)],
    );
  }
  return buffer.toString();
}

String? _text(Object? raw) {
  if (raw is! String) return null;
  final value = raw.trim();
  return value.isEmpty ? null : value;
}

int _int(Object? raw, {int fallback = 0}) =>
    raw is num ? raw.round() : fallback;

bool _bool(Object? raw) => raw == true;

/// Un accompagnement d'un plat : texte, garniture ou recette existante.
class WorkshopSide {
  final String label;
  final String? stapleId;
  final String? recipeId;

  /// Le modèle avait cité une recette absente du périmètre.
  final bool unknownRecipeId;

  /// Le modèle avait cité une garniture absente de l'envoi.
  final bool unknownStapleId;

  const WorkshopSide({
    required this.label,
    this.stapleId,
    this.recipeId,
    this.unknownRecipeId = false,
    this.unknownStapleId = false,
  });

  factory WorkshopSide.fromJson(Map<String, dynamic> json) => WorkshopSide(
    label: _text(json['label']) ?? '',
    stapleId: _text(json['staple_id']),
    recipeId: _text(json['recipe_id']),
    unknownRecipeId: _bool(json['unknown_recipe_id']),
    unknownStapleId: _bool(json['unknown_staple_id']),
  );

  /// Ce que le serveur relit au tour suivant : sans les marqueurs du contrôle.
  Map<String, dynamic> toJson() => {
    'label': label,
    'staple_id': stapleId,
    'recipe_id': recipeId,
  };

  /// Ce qui compte pour la puce « Modifié ».
  String get signature => '$label/${stapleId ?? ''}/${recipeId ?? ''}';
}

/// Un service du menu : entrée, plat et ses accompagnements, fromage…
class WorkshopCourse {
  final MealComponentRole role;

  /// Libellé d'un service « Autre » (« Trou normand »).
  final String? courseLabel;
  final String title;
  final String? description;

  /// Une recette du périmètre ; `null` : plat à rédiger.
  final String? recipeId;

  /// La raison de l'accord, lue par la personne.
  final String? why;
  final List<WorkshopSide> sides;

  /// Le modèle avait cité une recette absente du périmètre : « Recette
  /// inconnue : à rédiger ».
  final bool unknownRecipeId;

  const WorkshopCourse({
    required this.role,
    this.courseLabel,
    required this.title,
    this.description,
    this.recipeId,
    this.why,
    this.sides = const [],
    this.unknownRecipeId = false,
  });

  factory WorkshopCourse.fromJson(Map<String, dynamic> json) => WorkshopCourse(
    role: MealComponentRole.fromKey(_text(json['role']) ?? 'autre'),
    courseLabel: _text(json['course_label']),
    title: _text(json['title']) ?? '',
    description: _text(json['description']),
    recipeId: _text(json['recipe_id']),
    why: _text(json['why']),
    sides: [
      if (json['sides'] is List)
        for (final side in json['sides'] as List)
          if (side is Map)
            WorkshopSide.fromJson(Map<String, dynamic>.from(side)),
    ],
    unknownRecipeId: _bool(json['unknown_recipe_id']),
  );

  Map<String, dynamic> toJson() => {
    'role': role.name,
    'course_label': courseLabel,
    'title': title,
    'description': description,
    'recipe_id': recipeId,
    'why': why,
    'sides': [for (final side in sides) side.toJson()],
  };

  /// Le type tel qu'on le lit : « Entrée », ou le libellé d'un « Autre ».
  String get typeLabel {
    final custom = courseLabel?.trim() ?? '';
    return role == MealComponentRole.autre && custom.isNotEmpty
        ? custom
        : role.label;
  }

  /// Une recette existante, liée telle quelle.
  bool get isLinked => recipeId != null;

  /// Un plat que le figement rédige : un titre, sans recette liée.
  bool get isToWrite => !isLinked && title.trim().isNotEmpty;

  /// Le même service, lié à la recette [recipeId] sous son titre
  /// ([title]) : « Lier la recette existante » d'un doublon de titre.
  WorkshopCourse linkedTo({required String recipeId, required String title}) =>
      WorkshopCourse(
        role: role,
        courseLabel: courseLabel,
        title: title,
        description: description,
        recipeId: recipeId,
        why: why,
        sides: sides,
      );

  /// Le même service, sans recette liée : « Rédiger à la place » d'une
  /// recette devenue inaccessible.
  WorkshopCourse unlinked() => WorkshopCourse(
    role: role,
    courseLabel: courseLabel,
    title: title,
    description: description,
    why: why,
    sides: sides,
  );

  /// Ce qui compte pour la puce « Modifié » : rôle, type, titre, recette,
  /// accompagnements. Ni la description ni la raison : les reformuler n'est
  /// pas changer le menu.
  String get signature =>
      '${role.name}|${courseLabel ?? ''}|$title|${recipeId ?? ''}|'
      '${sides.map((s) => s.signature).join(',')}';
}

/// L'état du menu après un tour.
class WorkshopMenu {
  final int portions;
  final List<WorkshopCourse> courses;

  const WorkshopMenu({required this.portions, required this.courses});

  factory WorkshopMenu.fromJson(Map<String, dynamic> json) => WorkshopMenu(
    portions: _int(json['portions'], fallback: kWorkshopDefaultPortions),
    courses: [
      if (json['courses'] is List)
        for (final course in json['courses'] as List)
          if (course is Map)
            WorkshopCourse.fromJson(Map<String, dynamic>.from(course)),
    ],
  );

  Map<String, dynamic> toJson() => {
    'portions': portions,
    'courses': [for (final course in courses) course.toJson()],
  };

  bool get isEmpty => courses.isEmpty;

  /// Les services sans recette liée : ceux qu'un figement rédigerait.
  int get toWriteCount => courses.where((c) => c.isToWrite).length;

  int get linkedCount => courses.where((c) => c.isLinked).length;

  /// Vrai quand « Figer le repas » a quelque chose à rédiger.
  bool get canFreeze => toWriteCount > 0;

  /// Le même menu, le service [index] remplacé.
  WorkshopMenu withCourse(int index, WorkshopCourse course) => WorkshopMenu(
    portions: portions,
    courses: [for (final (i, c) in courses.indexed) i == index ? course : c],
  );

  /// Le même menu, sans le service [index] : « Retirer du repas ».
  WorkshopMenu withoutCourse(int index) => WorkshopMenu(
    portions: portions,
    courses: [
      for (final (i, c) in courses.indexed)
        if (i != index) c,
    ],
  );
}

/// Les services de [next] qu'aucun service de [previous] n'égale : titre,
/// rôle, recette ou accompagnements changés, ou service ajouté. L'ordre ne
/// compte pas : un sorbet inséré au milieu ne marque pas tout ce qui suit.
/// Sans menu précédent, tout est nouveau.
Set<int> changedCourseIndexes(WorkshopMenu? previous, WorkshopMenu next) {
  final known = {for (final c in previous?.courses ?? const []) c.signature};
  return {
    for (final (index, course) in next.courses.indexed)
      if (!known.contains(course.signature)) index,
  };
}

/// Vrai quand le JSON relu par le serveur est identique au tour précédent :
/// « Menu inchangé ». Un menu précédent absent n'est jamais « inchangé ».
bool sameMenu(WorkshopMenu? previous, WorkshopMenu next) =>
    previous != null &&
    jsonEncode(previous.toJson()) == jsonEncode(next.toJson());

/// Ce que le contrôle serveur a corrigé ou écarté, dont l'écran parle : un
/// menu tronqué (« Menu limité à 10 services. ») et, en mode plat, les
/// services d'un autre rôle écartés (« Plat seul : 2 services écartés. »).
class WorkshopControl {
  final bool truncated;

  /// Mode plat : services d'un autre rôle que « plat », écartés par le
  /// serveur.
  final int offKindCourses;

  const WorkshopControl({this.truncated = false, this.offKindCourses = 0});

  factory WorkshopControl.fromJson(Map<String, dynamic> json) =>
      WorkshopControl(
        truncated: _bool(json['truncated']),
        offKindCourses: _int(json['offKindCourses']),
      );
}

/// Le compteur de tours du jour : le plafond du compte et ce qu'il en
/// reste. Rendu par le serveur à chaque tour, lu une fois à l'ouverture dans
/// `meal_workshop_daily/{uid}_{AAAA-MM-JJ}`.
class WorkshopQuota {
  final int limit;
  final int remaining;

  const WorkshopQuota({required this.limit, required this.remaining});

  /// Le compteur rendu par le serveur (`quota: {limit, remaining}`) ; `null`
  /// s'il manque ou s'il est illisible : le nombre restant devient inconnu
  /// plutôt que faux.
  static WorkshopQuota? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final limit = raw['limit'];
    final remaining = raw['remaining'];
    if (limit is! num || remaining is! num) return null;
    return WorkshopQuota(
      limit: limit.round(),
      remaining: remaining.round().clamp(0, limit.round()),
    );
  }

  /// Le compteur lu dans `meal_workshop_daily/{uid}_{jour}` : `limit - count`.
  /// Document absent ([data] nul) : le plafond par défaut, entier. Un champ
  /// mal formé vaut `null` : inconnu, jamais une valeur plausible.
  static WorkshopQuota? fromDaily(Map<String, dynamic>? data) {
    if (data == null) {
      return const WorkshopQuota(
        limit: kWorkshopDailyLimit,
        remaining: kWorkshopDailyLimit,
      );
    }
    final count = data['count'];
    final limit = data['limit'];
    if (count is! num) return null;
    final max = limit is num ? limit.round() : kWorkshopDailyLimit;
    return WorkshopQuota(
      limit: max,
      remaining: (max - count.round()).clamp(0, max),
    );
  }

  bool get exhausted => remaining <= 0;
}

/// `AAAA-MM-JJ` du jour **UTC** de [when] : la clé du compteur du jour.
///
/// Le serveur réserve la place sur `meal_workshop_daily/{uid}_{jour}` avec
/// le jour UTC (`spendDay`, `ai/budget.ts`). Lue en heure locale, la clé
/// désignerait un autre document entre minuit et 2 h à Paris, et l'écran
/// afficherait 30 tours restants alors que le compteur du serveur est
/// entamé.
String workshopDayKey(DateTime when) {
  final utc = when.toUtc();
  String two(int n) => n < 10 ? '0$n' : '$n';
  return '${utc.year}-${two(utc.month)}-${two(utc.day)}';
}

/// La réponse complète d'un tour.
class WorkshopTurnResult {
  final String reponse;
  final bool reponseTruncated;
  final WorkshopMenu menu;
  final WorkshopControl control;
  final int turn;

  /// Le compteur du jour après ce tour ; `null` si le serveur ne l'a pas dit.
  final WorkshopQuota? quota;

  const WorkshopTurnResult({
    required this.reponse,
    this.reponseTruncated = false,
    required this.menu,
    required this.control,
    required this.turn,
    this.quota,
  });

  factory WorkshopTurnResult.fromJson(Map<String, dynamic> json) {
    final menu = json['menu'];
    final control = json['control'];
    if (menu is! Map) {
      throw const FormatException('Réponse sans menu.');
    }
    return WorkshopTurnResult(
      reponse: (json['reponse'] as String? ?? '').trim(),
      reponseTruncated: _bool(json['reponseTruncated']),
      menu: WorkshopMenu.fromJson(Map<String, dynamic>.from(menu)),
      control: control is Map
          ? WorkshopControl.fromJson(Map<String, dynamic>.from(control))
          : const WorkshopControl(),
      turn: _int(json['turn'], fallback: 1),
      quota: WorkshopQuota.fromJson(json['quota']),
    );
  }
}

// ── Parts par défaut ─────────────────────────────────────────────────────────

/// Les parts du menu à l'ouverture : celles du premier groupe familial
/// actif du compte — le plus ancien par `createdAt`, propriétaire ou membre,
/// hors groupes en pause ([pausedGroupIds]) —, lues par
/// [groupDefaultPortions] (« Parts des groupes » si réglées, sinon le
/// nombre de membres). Sans groupe actif : [kWorkshopDefaultPortions].
int defaultMealWorkshopPortions({
  required List<FamilyGroup> groups,
  required Set<String> pausedGroupIds,
  required Map<String, int> groupPortions,
}) {
  final active = [
    for (final g in groups)
      if (!pausedGroupIds.contains(g.id)) g,
  ];
  if (active.isEmpty) return kWorkshopDefaultPortions;
  active.sort((a, b) {
    final byDate = a.createdAt.compareTo(b.createdAt);
    return byDate != 0 ? byDate : a.id.compareTo(b.id);
  });
  return groupDefaultPortions(
    groupPortions: groupPortions,
    group: active.first,
  );
}

// ── Libellés du compteur ─────────────────────────────────────────────────────

/// « Il vous reste 27 tours aujourd'hui. », accordé ; à zéro, la phrase du
/// plafond atteint ([exhaustedTurnsLine]).
String remainingTurnsLine(WorkshopQuota quota) => switch (quota.remaining) {
  0 => exhaustedTurnsLine(quota.limit),
  1 => 'Il vous reste 1 tour aujourd\'hui.',
  final n => 'Il vous reste $n tours aujourd\'hui.',
};

/// « Vous avez fait vos 30 tours d'aujourd'hui. Le compteur repart demain. »
String exhaustedTurnsLine(int limit) =>
    'Vous avez fait vos $limit tours d\'aujourd\'hui. Le compteur repart '
    'demain.';

/// « 4 parts », « 1 part ».
String workshopPortionsLabel(int portions) =>
    '$portions ${portions > 1 ? 'parts' : 'part'}';
