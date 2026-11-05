/// Le menu de l'atelier repas, tel que le serveur le rend après contrôle.
///
/// Bac à sable, palier 0 : rien n'est enregistré, tout vit en mémoire de
/// l'écran. Ce fichier lit la réponse de `sandboxFn` (`meal_workshop.turn`),
/// compare deux menus pour poser la puce « Modifié » et détecter « Menu
/// inchangé », et met en forme les mesures du tour (coût, jetons, durée).
/// Fonctions pures, testées dans `test/sandbox_meal_workshop_test.dart`.
///
/// Les constantes jumelles vivent dans `functions/src/sandbox/mealWorkshop.ts`.
/// Au portage (palier 1), celles qui existent des deux côtés rejoignent le
/// tableau « Logique dupliquée Dart ↔ TypeScript » avec une fixture.
library;

import 'dart:convert';

import '../../planning/domain/meal_component.dart';
import '../../planning/domain/meal_kind.dart';
import 'sandbox_model_choice.dart';

/// Tours au plus par conversation : le 21e message est refusé par l'écran,
/// et par le serveur (`MEAL_WORKSHOP_MAX_TURNS`).
const int kWorkshopMaxTurns = 20;

/// Services de rôle « plat » au plus en mode plat : le plat, et la recette
/// d'un accompagnement en service secondaire (`MEAL_WORKSHOP_MAX_DISH_COURSES`).
const int kWorkshopMaxDishCourses = 2;

/// Caractères au plus par message (`MEAL_WORKSHOP_MAX_MESSAGE_CHARS`).
const int kWorkshopMaxMessageChars = 1500;

/// Parts du menu à l'ouverture. Constante au palier 0 ; au palier 1, la
/// préférence du planning quand elle est posée.
const int kWorkshopDefaultPortions = 4;

/// Au-delà, le texte d'une réponse se replie sous « Lire la suite ».
const int kWorkshopReplyFoldChars = 1500;

/// Le poste de coût du tour : clé de `SandboxModelPicker` et du catalogue.
const String kWorkshopFeature = 'sandbox_meal_workshop_turn';

/// La clé du `switch` de `sandboxFn`.
const String kWorkshopExperiment = 'meal_workshop.turn';

/// `details.reason` d'une réponse que le contrôle serveur a refusée.
const String kWorkshopUnreadableReason = 'meal_workshop_unreadable';

/// `details.reason` d'un 21e tour refusé par le serveur.
const String kWorkshopMaxTurnsReason = 'meal_workshop_max_turns';

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
  int get toWriteCount => courses.where((c) => !c.isLinked).length;

  int get linkedCount => courses.where((c) => c.isLinked).length;
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

/// Ce que le contrôle serveur a corrigé ou écarté : la mesure du palier 0.
class WorkshopControl {
  final int inventedIds;
  final int unknownStapleIds;
  final bool truncated;
  final List<Map<String, dynamic>> droppedCourses;
  final int droppedSides;
  final int sidesCleared;
  final int clampedFields;
  final bool portionsChangedByModel;

  /// Mode plat : services d'un autre rôle que « plat », écartés par le
  /// serveur et comptés à part des services écartés pour le format.
  final int offKindCourses;

  const WorkshopControl({
    this.inventedIds = 0,
    this.unknownStapleIds = 0,
    this.truncated = false,
    this.droppedCourses = const [],
    this.droppedSides = 0,
    this.sidesCleared = 0,
    this.clampedFields = 0,
    this.portionsChangedByModel = false,
    this.offKindCourses = 0,
  });

  factory WorkshopControl.fromJson(Map<String, dynamic> json) =>
      WorkshopControl(
        inventedIds: _int(json['inventedIds']),
        unknownStapleIds: _int(json['unknownStapleIds']),
        truncated: _bool(json['truncated']),
        droppedCourses: [
          if (json['droppedCourses'] is List)
            for (final d in json['droppedCourses'] as List)
              if (d is Map) Map<String, dynamic>.from(d),
        ],
        droppedSides: _int(json['droppedSides']),
        sidesCleared: _int(json['sidesCleared']),
        clampedFields: _int(json['clampedFields']),
        portionsChangedByModel: _bool(json['portionsChangedByModel']),
        offKindCourses: _int(json['offKindCourses']),
      );

  /// « inventedIds : 1 · services écartés : 1 (role_inconnu) … », une ligne
  /// par champ, pour le volet « Réponse brute ».
  List<String> get lines => [
    'inventedIds : $inventedIds',
    'unknownStapleIds : $unknownStapleIds',
    'truncated : $truncated',
    'services écartés : ${droppedCourses.length}'
        '${droppedCourses.isEmpty ? '' : ' ('
                  '${droppedCourses.map(_describeDrop).join(' ; ')})'}',
    'accompagnements écartés : $droppedSides',
    'accompagnements vidés (hors plat) : $sidesCleared',
    'champs coupés : $clampedFields',
    'parts changées par le modèle : $portionsChangedByModel',
    'services hors plat (mode plat) : $offKindCourses',
  ];

  static String _describeDrop(Map<String, dynamic> drop) {
    final reason = _text(drop['reason']) ?? '?';
    final detail = _text(drop['detail']);
    return '#${_int(drop['index'])} $reason${detail == null ? '' : ' « $detail »'}';
  }
}

/// La consommation d'un tour, telle que le serveur l'a relevée.
class WorkshopUsage {
  /// Coût enregistré par la comptabilité ; `null` : non chiffré (grille en
  /// panne ou modèle absent de la grille). Jamais remplacé par un repli.
  final double? costUsd;

  /// Jetons d'entrée hors cache : chez Anthropic, le préfixe mis en cache
  /// n'y est pas, il est dans les deux compteurs suivants.
  final int inputTokens;
  final int outputTokens;
  final int thinkingTokens;

  /// Jetons du préfixe relus depuis le cache (un dixième du tarif d'entrée).
  final int cacheReadInputTokens;

  /// Jetons du préfixe écrits dans le cache (1,25 fois le tarif d'entrée).
  final int cacheCreationInputTokens;
  final int durationMs;
  final String provider;
  final String model;

  /// Le moteur que la politique voulait, quand ce n'est pas lui qui a répondu.
  final String? requested;

  /// Raison d'arrêt du fournisseur : « MAX_TOKENS » dit une réponse coupée.
  final String? stopReason;

  const WorkshopUsage({
    required this.costUsd,
    required this.inputTokens,
    required this.outputTokens,
    this.thinkingTokens = 0,
    this.cacheReadInputTokens = 0,
    this.cacheCreationInputTokens = 0,
    required this.durationMs,
    required this.provider,
    required this.model,
    this.requested,
    this.stopReason,
  });

  factory WorkshopUsage.fromJson(Map<String, dynamic> json) => WorkshopUsage(
    costUsd: json['costUsd'] is num
        ? (json['costUsd'] as num).toDouble()
        : null,
    inputTokens: _int(json['inputTokens']),
    outputTokens: _int(json['outputTokens']),
    thinkingTokens: _int(json['thinkingTokens']),
    cacheReadInputTokens: _int(json['cacheReadInputTokens']),
    cacheCreationInputTokens: _int(json['cacheCreationInputTokens']),
    durationMs: _int(json['durationMs']),
    provider: _text(json['provider']) ?? '?',
    model: _text(json['model']) ?? '?',
    requested: _text(json['requested']),
    stopReason: _text(json['stopReason']),
  );
}

/// La réponse complète d'un tour.
class WorkshopTurnResult {
  final String reponse;
  final bool reponseTruncated;
  final WorkshopMenu menu;
  final WorkshopControl control;
  final String raw;
  final bool rawTruncated;
  final WorkshopUsage usage;

  /// Taille du prompt envoyé, en caractères.
  final int promptChars;
  final int turn;

  const WorkshopTurnResult({
    required this.reponse,
    this.reponseTruncated = false,
    required this.menu,
    required this.control,
    required this.raw,
    this.rawTruncated = false,
    required this.usage,
    required this.promptChars,
    required this.turn,
  });

  factory WorkshopTurnResult.fromJson(Map<String, dynamic> json) {
    final menu = json['menu'];
    final control = json['control'];
    final usage = json['usage'];
    if (menu is! Map || usage is! Map) {
      throw const FormatException('Réponse sans menu ou sans consommation.');
    }
    return WorkshopTurnResult(
      reponse: (json['reponse'] as String? ?? '').trim(),
      reponseTruncated: _bool(json['reponseTruncated']),
      menu: WorkshopMenu.fromJson(Map<String, dynamic>.from(menu)),
      control: control is Map
          ? WorkshopControl.fromJson(Map<String, dynamic>.from(control))
          : const WorkshopControl(),
      raw: json['raw'] as String? ?? '',
      rawTruncated: _bool(json['rawTruncated']),
      usage: WorkshopUsage.fromJson(Map<String, dynamic>.from(usage)),
      promptChars: _int(json['promptChars']),
      turn: _int(json['turn'], fallback: 1),
    );
  }
}

// ── Mesures ──────────────────────────────────────────────────────────────────

/// Une ligne du tableau récapitulatif des tours.
class WorkshopTurnMeasure {
  /// Rang de la conversation depuis l'ouverture de l'écran : « Nouvelle
  /// conversation » garde les mesures, le compte rendu les distingue.
  final int conversation;

  /// Plat ou menu : le mode de la conversation, fixé pour sa durée.
  final MealKind kind;
  final int turn;
  final double? costUsd;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadInputTokens;
  final int cacheCreationInputTokens;
  final int durationMs;
  final int inventedIds;
  final int droppedCourses;
  final int offKindCourses;
  final bool truncated;

  /// Le contrôle serveur a refusé la réponse : tour facturé, menu inchangé.
  final bool unreadable;
  final String provider;
  final String model;
  final int promptChars;

  const WorkshopTurnMeasure({
    required this.conversation,
    required this.kind,
    required this.turn,
    required this.costUsd,
    required this.inputTokens,
    required this.outputTokens,
    this.cacheReadInputTokens = 0,
    this.cacheCreationInputTokens = 0,
    required this.durationMs,
    this.inventedIds = 0,
    this.droppedCourses = 0,
    this.offKindCourses = 0,
    this.truncated = false,
    this.unreadable = false,
    required this.provider,
    required this.model,
    required this.promptChars,
  });

  factory WorkshopTurnMeasure.fromResult(
    WorkshopTurnResult result, {
    required int conversation,
    required MealKind kind,
  }) => WorkshopTurnMeasure(
    conversation: conversation,
    kind: kind,
    turn: result.turn,
    costUsd: result.usage.costUsd,
    inputTokens: result.usage.inputTokens,
    outputTokens: result.usage.outputTokens,
    cacheReadInputTokens: result.usage.cacheReadInputTokens,
    cacheCreationInputTokens: result.usage.cacheCreationInputTokens,
    durationMs: result.usage.durationMs,
    inventedIds: result.control.inventedIds,
    droppedCourses: result.control.droppedCourses.length,
    offKindCourses: result.control.offKindCourses,
    truncated: result.control.truncated,
    provider: result.usage.provider,
    model: result.usage.model,
    promptChars: result.promptChars,
  );

  /// Un tour refusé par le contrôle : la consommation vient des `details`
  /// de l'erreur, quand le serveur l'a rendue.
  factory WorkshopTurnMeasure.unreadable(
    Map<String, dynamic>? details, {
    required int conversation,
    required MealKind kind,
    required int fallbackTurn,
  }) {
    final usage = details?['usage'] is Map
        ? WorkshopUsage.fromJson(Map<String, dynamic>.from(details!['usage']))
        : null;
    return WorkshopTurnMeasure(
      conversation: conversation,
      kind: kind,
      turn: _int(details?['turn'], fallback: fallbackTurn),
      costUsd: usage?.costUsd,
      inputTokens: usage?.inputTokens ?? 0,
      outputTokens: usage?.outputTokens ?? 0,
      cacheReadInputTokens: usage?.cacheReadInputTokens ?? 0,
      cacheCreationInputTokens: usage?.cacheCreationInputTokens ?? 0,
      durationMs: usage?.durationMs ?? 0,
      unreadable: true,
      provider: usage?.provider ?? '?',
      model: usage?.model ?? '?',
      promptChars: _int(details?['promptChars']),
    );
  }
}

/// « cache : 95 000 lus », « cache : 95 000 écrits », « cache : 95 000 lus,
/// 2 000 écrits » ; `null` quand rien n'est passé par le cache. Sans ce
/// témoin, personne ne voit si le préfixe mis en cache sert.
String? workshopCacheLabel(int readTokens, int creationTokens) {
  if (readTokens <= 0 && creationTokens <= 0) return null;
  final parts = [
    if (readTokens > 0) '${formatWorkshopCount(readTokens)} lus',
    if (creationTokens > 0) '${formatWorkshopCount(creationTokens)} écrits',
  ];
  return 'cache : ${parts.join(', ')}';
}

/// « 0,0123 $ » ; « non chiffré » sans montant. Jamais de valeur de repli.
String formatWorkshopCost(double? usd) {
  if (usd == null) return 'non chiffré';
  return '${usd.toStringAsFixed(4).replaceAll('.', ',')} \$';
}

/// « 11 240 » : séparateur de milliers, sans dépendre de la locale.
String formatWorkshopCount(int n) {
  final digits = n.abs().toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) buffer.write(' ');
    buffer.write(digits[i]);
  }
  return n < 0 ? '-$buffer' : buffer.toString();
}

/// « 4,1 s » ; « 850 ms » sous la seconde.
String formatWorkshopDuration(int ms) {
  if (ms < 1000) return '$ms ms';
  return '${(ms / 1000).toStringAsFixed(1).replaceAll('.', ',')} s';
}

/// « Gemini 2.5 Flash » quand le modèle est une présélection du bac à sable,
/// sinon « gemini/gemini-2.5-pro ».
String workshopEngineLabel(String provider, String model) {
  for (final preset in kSandboxModelPresets) {
    if (preset.provider == provider && preset.model == model) {
      return preset.label;
    }
  }
  return '$provider/$model';
}

/// « 0,0123 $ · 11 240 → 420 jetons · cache : 95 000 lus · 4,1 s · Gemini
/// 2.5 Flash », la ligne sous chaque bulle de l'IA. Le segment « cache »
/// n'apparaît que si des jetons sont passés par le cache.
String workshopUsageLine(WorkshopUsage usage) {
  final cache = workshopCacheLabel(
    usage.cacheReadInputTokens,
    usage.cacheCreationInputTokens,
  );
  final parts = [
    formatWorkshopCost(usage.costUsd),
    '${formatWorkshopCount(usage.inputTokens)} → '
        '${formatWorkshopCount(usage.outputTokens)} jetons',
    ?cache,
    formatWorkshopDuration(usage.durationMs),
    workshopEngineLabel(usage.provider, usage.model),
  ];
  if (usage.requested != null) parts.add('demandé : ${usage.requested}');
  return parts.join(' · ');
}

/// Le tableau récapitulatif des tours, en texte tabulé (une ligne d'en-tête,
/// une ligne par tour), pour « Copier le tableau » et le compte rendu d'une
/// page du cadrage. Les colonnes de cache valent 0 quand rien n'y est passé :
/// un export garde ses colonnes.
String workshopMeasuresTable(List<WorkshopTurnMeasure> turns) {
  final lines = <String>[
    [
      'conversation',
      'mode',
      'tour',
      'cout_usd',
      'jetons_entree',
      'jetons_sortie',
      'cache_lus',
      'cache_ecrits',
      'duree_ms',
      'ids_inventes',
      'services_ecartes',
      'services_hors_plat',
      'tronque',
      'illisible',
      'moteur',
      'prompt_chars',
    ].join('\t'),
  ];
  for (final t in turns) {
    lines.add(
      [
        '${t.conversation}',
        t.kind.key,
        '${t.turn}',
        t.costUsd == null ? '' : t.costUsd!.toStringAsFixed(6),
        '${t.inputTokens}',
        '${t.outputTokens}',
        '${t.cacheReadInputTokens}',
        '${t.cacheCreationInputTokens}',
        '${t.durationMs}',
        '${t.inventedIds}',
        '${t.droppedCourses}',
        '${t.offKindCourses}',
        t.truncated ? '1' : '0',
        t.unreadable ? '1' : '0',
        '${t.provider}/${t.model}',
        '${t.promptChars}',
      ].join('\t'),
    );
  }
  return lines.join('\n');
}

/// Somme des coûts connus, et nombre de tours sans montant.
({double knownUsd, int unpriced}) workshopCostTotal(
  List<WorkshopTurnMeasure> turns,
) {
  var known = 0.0;
  var unpriced = 0;
  for (final t in turns) {
    if (t.costUsd == null) {
      unpriced++;
    } else {
      known += t.costUsd!;
    }
  }
  return (knownUsd: known, unpriced: unpriced);
}
