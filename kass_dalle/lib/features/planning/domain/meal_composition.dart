/// La composition d'un repas : un plat, ou un menu de services ordonnés.
///
/// Un repas planifié stocke son plat principal dans `recipe_id` /
/// `recipe_titre`, et tout le reste dans `components`, une liste plate. Ce
/// fichier lit cette liste en services — l'entrée, le plat principal avec ses
/// accompagnements, un plat secondaire avec les siens, le fromage — et la
/// réécrit. Rien ici n'appelle Firestore ni un modèle : des fonctions pures,
/// testées dans `meal_composition_test.dart`.
///
/// Écriture d'un menu (v0.24.14) : chaque service dans l'ordre ; le plat
/// principal par un marqueur `{role: plat, id: 'main', label: <titre>}`
/// suivi de ses accompagnements ; un plat secondaire par son composant
/// (`id` court) suivi des siens (`side_of: <id>`). Un plat s'écrit comme
/// avant : ses accompagnements seuls.
library;

import 'meal_component.dart';
import 'meal_format.dart';
import 'meal_kind.dart';
import 'planned_meal.dart';
import 'side_chooser.dart' show kMaxSidesPerDish;

/// Services au plus dans un menu : au-delà, « + Ajouter un service » laisse la
/// place à « 10 services au plus ».
const int kMaxCoursesPerMenu = 10;

/// Longueur maximale du libellé d'un service « Autre… » (`course_label`).
const int kCourseLabelMaxChars = 30;

/// Titre d'un repas sans plat : « Remettre à blanc ».
const String kFreeMealTitle = 'Repas libre';

/// Les types de service qu'on peut ajouter à un menu, dans l'ordre du menu
/// « + Ajouter un service ». Aucun n'est un rôle de recette : une recette
/// garde son `meal_role`, le service dit où elle se sert.
const List<MealComponentRole> kCourseRoles = [
  MealComponentRole.entree,
  MealComponentRole.plat,
  MealComponentRole.sorbet,
  MealComponentRole.fromage,
  MealComponentRole.dessert,
  MealComponentRole.autre,
];

/// Rang d'un type de service dans un menu, pour ranger un service ajouté.
int _courseRank(MealComponentRole role) => switch (role) {
  MealComponentRole.entree => 0,
  MealComponentRole.plat => 1,
  MealComponentRole.sorbet => 2,
  MealComponentRole.fromage => 3,
  MealComponentRole.dessert => 4,
  MealComponentRole.autre => 5,
  MealComponentRole.accompagnement => 1,
};

/// Le libellé d'un service « Autre… », tel qu'il sera posé : espaces réduites,
/// 30 caractères au plus ; `null` si rien d'utile.
String? courseLabelFrom(String input) {
  final s = input.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (s.isEmpty) return null;
  return s.length > kCourseLabelMaxChars
      ? s.substring(0, kCourseLabelMaxChars).trimRight()
      : s;
}

/// Les modèles de départ d'un menu, proposés quand un plat passe en menu.
enum MenuTemplate {
  entreePlatDessert,
  entreePlat,
  platDessert;

  String get label => switch (this) {
    MenuTemplate.entreePlatDessert => 'Entrée, plat, dessert',
    MenuTemplate.entreePlat => 'Entrée et plat',
    MenuTemplate.platDessert => 'Plat et dessert',
  };

  /// Les types de service du modèle, dans l'ordre.
  List<MealComponentRole> get roles => switch (this) {
    MenuTemplate.entreePlatDessert => const [
      MealComponentRole.entree,
      MealComponentRole.plat,
      MealComponentRole.dessert,
    ],
    MenuTemplate.entreePlat => const [
      MealComponentRole.entree,
      MealComponentRole.plat,
    ],
    MenuTemplate.platDessert => const [
      MealComponentRole.plat,
      MealComponentRole.dessert,
    ],
  };

  /// Le modèle choisi d'office.
  static const MenuTemplate defaultTemplate = MenuTemplate.entreePlatDessert;
}

/// Un service du repas.
class MealCourse {
  /// Ce qui est servi : la recette, la garniture ou le texte, avec son rôle
  /// de service ; un composant vide pour un service « à choisir ». Pour le
  /// plat principal, son marqueur ([MealComponent.isMainMarker]).
  final MealComponent component;

  /// Les accompagnements d'un plat (principal ou secondaire), dans l'ordre ;
  /// vide pour les autres services.
  final List<MealComponent> sides;

  const MealCourse(this.component, {this.sides = const []});

  MealComponentRole get role => component.role;

  /// Le plat principal du repas, celui de `recipe_id`.
  bool get isMain => component.isMainMarker;

  /// Un plat, principal ou secondaire : il a des accompagnements.
  bool get isDish => role == MealComponentRole.plat;

  /// « À choisir » : ni recette, ni garniture, ni texte. Le plat principal
  /// n'en est jamais un ici : son contenu est le repas lui-même.
  bool get isEmpty => component.isEmptyCourse;

  /// « Entrée », « Plat », « Trou normand ».
  String get typeLabel => component.courseTypeLabel;

  MealCourse copyWith({MealComponent? component, List<MealComponent>? sides}) =>
      MealCourse(component ?? this.component, sides: sides ?? this.sides);
}

/// Un repas lu en plat ou en menu ordonné.
///
/// Immuable : chaque opération rend une nouvelle composition. [courses]
/// contient toujours exactement un plat principal ([MealCourse.isMain]).
/// Un menu qui repasse en plat dans l'éditeur garde ses autres services en
/// mémoire ([kind] seul change) : revenir sur « Menu » les rend, et
/// [toComponents] ne les écrit pas tant que [kind] vaut plat.
class MealComposition {
  final MealKind kind;
  final List<MealCourse> courses;

  /// Accompagnements dont le plat (`side_of`) n'existe pas dans le repas :
  /// réécrits tels quels, en fin de liste, sans s'afficher.
  final List<MealComponent> detached;

  const MealComposition._(this.kind, this.courses, this.detached);

  /// Un plat sans autre service, avec ses accompagnements.
  factory MealComposition.dish({List<MealComponent> sides = const []}) =>
      MealComposition._(MealKind.plat, [
        MealCourse(_marker(), sides: [for (final s in sides) _asMainSide(s)]),
      ], const []);

  /// Le repas [meal], lu en plat ou en menu.
  factory MealComposition.ofMeal(PlannedMeal meal) =>
      MealComposition.fromComponents(meal.components, stored: meal.mealKind);

  /// Lit `components`.
  ///
  /// - Le marqueur [kMainCourseId] dit où se sert le plat principal. Sans
  ///   marqueur (repas antérieurs), il se place après la dernière entrée de
  ///   tête, avant le premier service qui n'est pas une entrée.
  /// - Un accompagnement sans `side_of` va au plat principal, où qu'il soit
  ///   rangé : des repas P1 portent un accompagnement après le dessert.
  /// - Un accompagnement dont le plat est introuvable va dans [detached].
  /// - Un plat secondaire sans identifiant, ou dont l'identifiant est déjà
  ///   pris, en reçoit un. Un second marqueur est écarté : il ne porte que le
  ///   titre du plat.
  factory MealComposition.fromComponents(
    List<MealComponent> components, {
    MealKind? stored,
  }) {
    final courses = <MealCourse>[];
    final mainSides = <MealComponent>[];
    final otherSides = <MealComponent>[];
    final usedIds = <String>{kMainCourseId};
    MealComponent? marker;
    var mainAt = -1;
    for (final c in components) {
      if (c.role == MealComponentRole.accompagnement) {
        (c.isMainSide ? mainSides : otherSides).add(c);
        continue;
      }
      if (c.isMainMarker) {
        if (marker == null) {
          marker = c;
          mainAt = courses.length;
        }
        continue;
      }
      var course = c;
      if (c.role == MealComponentRole.plat) {
        final id = c.id ?? '';
        if (id.isEmpty || !usedIds.add(id)) {
          final fresh = _freshDishId(usedIds);
          usedIds.add(fresh);
          course = c.copyWith(id: fresh);
        }
      }
      courses.add(MealCourse(course));
    }
    if (mainAt < 0) {
      mainAt = courses.indexWhere((c) => c.role != MealComponentRole.entree);
      if (mainAt < 0) mainAt = courses.length;
    }
    final detached = <MealComponent>[];
    final sidesById = <String, List<MealComponent>>{};
    for (final s in otherSides) {
      final owner = courses.where(
        (c) => c.isDish && c.component.id == s.sideOf,
      );
      if (owner.isEmpty) {
        detached.add(s);
      } else {
        sidesById.putIfAbsent(s.sideOf!, () => []).add(s);
      }
    }
    final withSides = [
      for (final c in courses)
        c.isDish ? c.copyWith(sides: sidesById[c.component.id] ?? []) : c,
    ];
    withSides.insert(mainAt, MealCourse(marker ?? _marker(), sides: mainSides));
    return MealComposition._(
      effectiveMealKind(components, stored: stored),
      List.unmodifiable(withSides),
      List.unmodifiable(detached),
    );
  }

  static MealComponent _marker() => const MealComponent(
    role: MealComponentRole.plat,
    id: kMainCourseId,
    label: '',
  );

  static MealComponent _asMainSide(MealComponent s) =>
      s.copyWith(role: MealComponentRole.accompagnement, sideOf: null);

  static String _freshDishId(Set<String> used) {
    var n = 2;
    while (used.contains('p$n')) {
      n++;
    }
    return 'p$n';
  }

  // ── Lecture ──────────────────────────────────────────────────────────────

  bool get isMenu => kind == MealKind.menu;

  int get mainIndex => courses.indexWhere((c) => c.isMain);

  MealCourse get main => courses[mainIndex];

  /// Les accompagnements du plat principal.
  List<MealComponent> get mainSides => main.sides;

  /// Les services affichés : tous pour un menu, le plat seul pour un plat.
  List<MealCourse> get visibleCourses => isMenu ? courses : [main];

  /// Les services retirés si le repas s'enregistre en plat : tous sauf le
  /// plat principal. Vide pour un menu qui le reste.
  List<MealCourse> get droppedAsDish => [
    for (final c in courses)
      if (!c.isMain) c,
  ];

  /// Les services retirés en repassant en plat qui portent quelque chose
  /// (recette, garniture, texte) : ceux que la boîte « Repasser en plat ? »
  /// nomme.
  List<MealCourse> get filledDroppedAsDish => [
    for (final c in droppedAsDish)
      if (!c.isEmpty) c,
  ];

  bool get canAddCourse => courses.length < kMaxCoursesPerMenu;

  /// Vrai quand tous les services autres que le plat principal sont « à
  /// choisir » : un modèle de départ peut encore les remplacer.
  bool get onlyEmptyCourses => courses.every((c) => c.isMain || c.isEmpty);

  /// Le modèle dont ce menu a la forme, services vides compris ; `null` sinon.
  MenuTemplate? get template {
    if (!onlyEmptyCourses) return null;
    final roles = [for (final c in courses) c.role];
    for (final t in MenuTemplate.values) {
      if (_sameRoles(roles, t.roles)) return t;
    }
    return null;
  }

  static bool _sameRoles(List<MealComponentRole> a, List<MealComponentRole> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// La liste `components` à écrire, et [kind] à écrire dans `meal_kind`.
  ///
  /// [mainTitle] est le titre du plat principal (`recipe_titre`), recopié
  /// dans le marqueur. Les accompagnements reprennent leur `side_of` : aucun
  /// pour le plat principal, l'identifiant du plat pour un plat secondaire.
  List<MealComponent> toComponents({required String mainTitle}) {
    if (!isMenu) {
      return [for (final s in mainSides) _asMainSide(s), ...detached];
    }
    return [
      for (final c in courses) ...[
        if (c.isMain) c.component.copyWith(label: mainTitle) else c.component,
        for (final s in c.sides)
          s.copyWith(
            role: MealComponentRole.accompagnement,
            sideOf: c.isMain ? null : c.component.id,
          ),
      ],
      ...detached,
    ];
  }

  // ── Opérations ───────────────────────────────────────────────────────────

  MealComposition _with({MealKind? kind, List<MealCourse>? courses}) =>
      MealComposition._(
        kind ?? this.kind,
        List.unmodifiable(courses ?? this.courses),
        detached,
      );

  /// Plat ou menu, sans rien perdre en mémoire.
  MealComposition withKind(MealKind kind) => _with(kind: kind);

  /// Passe en menu. Un plat sans autre service prend le modèle [template]
  /// (« Entrée, plat, dessert » d'office) : son plat devient le service
  /// « Plat », avec ses accompagnements, et les services ajoutés sont « à
  /// choisir ». Les services gardés en mémoire reviennent tels quels.
  MealComposition toMenu([
    MenuTemplate template = MenuTemplate.defaultTemplate,
  ]) {
    if (courses.length > 1) return _with(kind: MealKind.menu);
    return applyTemplate(template);
  }

  /// Remplace les services « à choisir » par ceux de [template]. Sans effet
  /// dès qu'un service autre que le plat principal porte quelque chose.
  MealComposition applyTemplate(MenuTemplate template) {
    if (!onlyEmptyCourses) return this;
    final main = this.main;
    return _with(
      kind: MealKind.menu,
      courses: [
        for (final r in template.roles)
          if (r == MealComponentRole.plat) main else MealCourse(_empty(r)),
      ],
    );
  }

  /// Repasse en plat : les autres services sont retirés de la composition.
  /// L'éditeur, lui, garde les services en mémoire ([withKind]).
  MealComposition toDish() => _with(kind: MealKind.plat, courses: [main]);

  static MealComponent _empty(MealComponentRole role, {String? courseLabel}) =>
      MealComponent(role: role, label: '', courseLabel: courseLabel);

  Set<String> get _dishIds => {
    for (final c in courses)
      if (c.isDish && (c.component.id ?? '').isNotEmpty) c.component.id!,
  };

  /// Ajoute un service « à choisir » (ou [content]) de type [role], à sa
  /// place : après le dernier service d'un rang inférieur ou égal — une
  /// entrée avant le plat, un fromage avant le dessert. Sans effet au
  /// dixième service, ou pour un accompagnement.
  MealComposition addCourse(
    MealComponentRole role, {
    String? courseLabel,
    MealComponent? content,
  }) {
    if (!canAddCourse || role == MealComponentRole.accompagnement) return this;
    var component = content == null
        ? _empty(role, courseLabel: courseLabel)
        : _asCourse(content, role, courseLabel: courseLabel);
    if (role == MealComponentRole.plat) {
      component = component.copyWith(id: _freshDishId({..._dishIds, 'main'}));
    }
    final rank = _courseRank(role);
    var at = 0;
    for (var i = 0; i < courses.length; i++) {
      if (_courseRank(courses[i].role) <= rank) at = i + 1;
    }
    final next = [...courses]..insert(at, MealCourse(component));
    return _with(kind: MealKind.menu, courses: next);
  }

  /// Retire le service [index] et ses accompagnements. Le plat principal ne
  /// se retire pas.
  MealComposition removeCourse(int index) {
    if (index < 0 || index >= courses.length || courses[index].isMain) {
      return this;
    }
    return _with(courses: [...courses]..removeAt(index));
  }

  /// Déplace le service [from] à la position [to] (après retrait : la
  /// convention de `ReorderableListView.onReorderItem`).
  MealComposition moveCourse(int from, int to) {
    if (from < 0 || from >= courses.length) return this;
    final next = [...courses];
    final moved = next.removeAt(from);
    next.insert(to.clamp(0, next.length), moved);
    return _with(courses: next);
  }

  /// Change le type du service [index]. Le plat principal reste un plat. Un
  /// plat secondaire qui change de type perd ses accompagnements ; un
  /// service qui devient un plat reçoit un identifiant.
  MealComposition changeCourseType(
    int index,
    MealComponentRole role, {
    String? courseLabel,
  }) {
    if (index < 0 || index >= courses.length) return this;
    final course = courses[index];
    if (course.isMain || role == MealComponentRole.accompagnement) return this;
    var component = course.component.copyWith(
      role: role,
      courseLabel: role == MealComponentRole.autre ? courseLabel : null,
    );
    if (role == MealComponentRole.plat) {
      final id = course.isDish ? course.component.id : null;
      component = component.copyWith(
        id: id ?? _freshDishId({..._dishIds, 'main'}),
      );
    } else {
      component = component.copyWith(id: null);
    }
    final next = [...courses];
    next[index] = MealCourse(
      component,
      sides: role == MealComponentRole.plat ? course.sides : const [],
    );
    return _with(courses: next);
  }

  /// Pose [content] dans le service [index] — `null` le remet « à choisir ».
  /// Le contenu prend le rôle du service ; un plat secondaire garde son
  /// identifiant et ses accompagnements. Le plat principal change par sa
  /// recette, pas ici.
  MealComposition setCourseContent(int index, MealComponent? content) {
    if (index < 0 || index >= courses.length) return this;
    final course = courses[index];
    if (course.isMain) return this;
    final component = content == null
        ? _empty(course.role, courseLabel: course.component.courseLabel)
        : _asCourse(
            content,
            course.role,
            courseLabel: course.component.courseLabel,
          );
    final next = [...courses];
    next[index] = MealCourse(
      course.isDish ? component.copyWith(id: course.component.id) : component,
      sides: course.sides,
    );
    return _with(courses: next);
  }

  static MealComponent _asCourse(
    MealComponent content,
    MealComponentRole role, {
    String? courseLabel,
  }) => content.copyWith(
    role: role,
    sideOf: null,
    courseLabel: role == MealComponentRole.autre ? courseLabel : null,
  );

  /// Remplace les accompagnements du plat [index] (principal ou secondaire),
  /// [kMaxSidesPerDish] au plus.
  MealComposition setSides(int index, List<MealComponent> sides) {
    if (index < 0 || index >= courses.length || !courses[index].isDish) {
      return this;
    }
    final next = [...courses];
    next[index] = courses[index].copyWith(
      sides: [
        for (final s in sides.take(kMaxSidesPerDish))
          s.copyWith(role: MealComponentRole.accompagnement, sideOf: null),
      ],
    );
    return _with(courses: next);
  }

  /// Remplace les accompagnements du plat principal.
  MealComposition withMainSides(List<MealComponent> sides) =>
      setSides(mainIndex, sides);
}

/// Le format d'un créneau de Nouveau planning qui montre la composition
/// éditée : une entrée et un dessert, l'un ou l'autre, ou ni l'un ni
/// l'autre — le plat seul, ou « Léger » s'il l'était ([current]). Le
/// serveur continue de ne proposer qu'une entrée et un dessert : sorbet,
/// fromage et services « Autre » restent tels que l'éditeur les a posés.
MealFormat mealFormatForComposition(
  MealComposition composition, {
  required MealFormat current,
}) {
  final roles = composition.isMenu
      ? {for (final c in composition.courses) c.role}
      : const <MealComponentRole>{};
  final starter = roles.contains(MealComponentRole.entree);
  final dessert = roles.contains(MealComponentRole.dessert);
  if (starter && dessert) return MealFormat.entreePlatDessert;
  if (starter) return MealFormat.entreePlat;
  if (dessert) return MealFormat.platDessert;
  return current.isLight ? MealFormat.leger : MealFormat.defaultFormat;
}

/// [components] dont le marqueur du plat principal recopie [title] : changer
/// le plat d'un menu met à jour la ligne « Plat : … » que lit une version
/// antérieure.
List<MealComponent> withMainMarkerTitle(
  List<MealComponent> components,
  String title,
) => [
  for (final c in components)
    c.isMainMarker && c.label != title ? c.copyWith(label: title) : c,
];

/// Les composants d'un menu dont le plat principal est vidé (« Remettre à
/// blanc ») : son marqueur et ses accompagnements sont retirés, les autres
/// services restent. Pour un plat, plus rien.
List<MealComponent> componentsWithoutMain(PlannedMeal meal) {
  if (meal.kind != MealKind.menu) return const [];
  return [
    for (final c in meal.components)
      if (!c.isMainMarker && !c.isMainSide) c,
  ];
}

/// Le plat principal d'un menu est « à choisir » : un repas libre, sans
/// recette ni titre propre.
bool mealMainIsEmpty(PlannedMeal meal) =>
    (meal.recipeId ?? '').isEmpty &&
    (meal.recipeTitre.trim().isEmpty || meal.recipeTitre == kFreeMealTitle);
