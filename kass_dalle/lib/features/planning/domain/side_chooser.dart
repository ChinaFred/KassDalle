/// L'accompagnement d'un plat : choisi par le programme, jamais par le modèle.
///
/// Le modèle a reconnu, une fois par recette, ce qu'elle apporte et ses
/// accompagnements classiques (`meal_role`, `contains`, `suggested_sides`).
/// Ici, on compose : ce qui manque au plat, ce que l'utilisateur a sous la
/// main — ses garnitures, les recettes d'accompagnement du corpus —, et ce
/// qui a déjà été servi la veille. Aucun appel, un résultat testable.
///
/// « Pas de pâtes au hasard avec la blanquette » : le choix se fait d'abord
/// dans les accompagnements classiques du plat, et seulement à défaut dans la
/// famille de garnitures qui manque.
library;

import '../../recipes/domain/recipe.dart';
import 'meal_component.dart';
import 'meal_staple.dart';
import 'planning_criteria.dart';

/// Accompagnements au plus pour un plat : au-delà, l'éditeur ne propose plus
/// d'en ajouter (« 6 accompagnements au plus »).
const int kMaxSidesPerDish = 6;

/// Ce qu'un plat n'apporte pas, et qu'un accompagnement doit apporter.
enum SideNeed {
  feculent,
  legume;

  String get label => switch (this) {
    SideNeed.feculent => 'féculent',
    SideNeed.legume => 'légume',
  };

  /// Libellé d'une pastille : « Féculent », « Légume ».
  String get chipLabel => switch (this) {
    SideNeed.feculent => 'Féculent',
    SideNeed.legume => 'Légume',
  };
}

/// Ce qui manque à un plat pour faire un repas, le féculent d'abord.
///
/// Vide pour tout ce qui n'est pas un plat, et pour une recette pas encore
/// classée : sans rôle connu, on ne pose rien plutôt que de poser au hasard.
List<SideNeed> sideNeedsFor(RecipeTags tags) {
  if (tags.mealRole != 'plat') return const [];
  return [
    if (!tags.contains.contains('feculent')) SideNeed.feculent,
    if (!tags.contains.contains('legume')) SideNeed.legume,
  ];
}

/// Un accompagnement possible : une garniture, ou une recette d'accompagnement.
class SideCandidate {
  final MealStaple? staple;
  final Recipe? recipe;

  const SideCandidate.staple(MealStaple this.staple) : recipe = null;
  const SideCandidate.recipe(Recipe this.recipe) : staple = null;

  bool get isRecipe => recipe != null;
  String get id => staple?.id ?? recipe!.id;
  String get name => staple?.name ?? recipe!.titre;
  int get sortOrder => staple?.sortOrder ?? 0;

  /// Ce que le prédicat des critères sait de ce candidat : allergènes saisis
  /// d'une garniture, allergènes calculés d'une recette.
  CriteriaItem get criteriaItem => staple != null
      ? CriteriaItem.ofStaple(staple!)
      : CriteriaItem.ofRecipe(recipe!);

  /// Vrai si ce candidat apporte ce qui manque.
  bool provides(SideNeed need) {
    final s = staple;
    if (s != null) return stapleCategoryProvides(s.category, need);
    final contains = recipe!.tags.contains;
    return switch (need) {
      SideNeed.feculent => contains.contains('feculent'),
      SideNeed.legume => contains.contains('legume'),
    };
  }

  /// Le composant à poser, accompagnement par défaut, ou service d'un menu
  /// ([role]).
  MealComponent toComponent({
    String? justification,
    MealComponentRole role = MealComponentRole.accompagnement,
  }) => staple != null
      ? MealComponent.staple(staple!, role: role, justification: justification)
      : MealComponent.recipe(recipe!, role: role, justification: justification);
}

/// Les candidats depuis ce que l'utilisateur voit : ses garnitures non
/// masquées, et les recettes d'accompagnement du corpus.
List<SideCandidate> sideCandidatesFrom({
  required Iterable<UserStaple> staples,
  required Iterable<Recipe> recipes,
}) => [
  for (final u in staples)
    if (!u.hidden) SideCandidate.staple(u.staple),
  for (final r in recipes)
    if (r.id.isNotEmpty && r.tags.mealRole == 'accompagnement')
      SideCandidate.recipe(r),
];

/// Les candidats d'un service de menu, par type :
///
/// - entrée : recettes de rôle entrée, garnitures « Salade et crudités » ;
/// - sorbet : recettes de rôle dessert, garnitures « Fruit » ;
/// - fromage : garnitures « Fromage » ;
/// - dessert : recettes de rôle dessert, garnitures « Fruit » et « Laitage » ;
/// - autre : toutes les garnitures et toutes les recettes ;
/// - accompagnement : [sideCandidatesFrom].
///
/// Un plat se choisit dans la feuille des recettes, pas ici : rien pour
/// [MealComponentRole.plat]. Les garnitures masquées ne sont jamais
/// proposées.
List<SideCandidate> courseCandidatesFor(
  MealComponentRole role, {
  required Iterable<UserStaple> staples,
  required Iterable<Recipe> recipes,
}) {
  if (role == MealComponentRole.accompagnement) {
    return sideCandidatesFrom(staples: staples, recipes: recipes);
  }
  final (
    Set<String> recipeRoles,
    Set<StapleCategory>? categories,
  ) = switch (role) {
    MealComponentRole.entree => (
      const {'entree'},
      const {StapleCategory.salade},
    ),
    MealComponentRole.sorbet => (
      const {'dessert'},
      const {StapleCategory.fruit},
    ),
    MealComponentRole.fromage => (
      const <String>{},
      const {StapleCategory.fromage},
    ),
    MealComponentRole.dessert => (
      const {'dessert'},
      const {StapleCategory.fruit, StapleCategory.laitage},
    ),
    MealComponentRole.autre => (const <String>{}, null),
    MealComponentRole.plat ||
    MealComponentRole.accompagnement => (const <String>{}, const {}),
  };
  if (role == MealComponentRole.plat) return const [];
  final anyRecipe = role == MealComponentRole.autre;
  return [
    for (final u in staples)
      if (!u.hidden &&
          (categories == null || categories.contains(u.staple.category)))
        SideCandidate.staple(u.staple),
    for (final r in recipes)
      if (r.id.isNotEmpty &&
          (anyRecipe || recipeRoles.contains(r.tags.mealRole)))
        SideCandidate.recipe(r),
  ];
}

/// Clé de comparaison d'un nom de garniture : minuscules, sans accent, au
/// singulier mot à mot. « Haricots verts » et « haricot vert » se valent.
String sideNameKey(String name) => stapleIdFromName(name)
    .split('_')
    .where((w) => w.isNotEmpty)
    .map(
      (w) => w.length > 3 && w.endsWith('s') ? w.substring(0, w.length - 1) : w,
    )
    .join(' ');

/// Vrai si un accompagnement suggéré désigne ce candidat.
///
/// « riz basmati » désigne le riz, « frites » désigne les frites maison,
/// « purée de pommes de terre » désigne la purée. Un mot au milieu ne suffit
/// pas : « pommes de terre » ne désigne pas « salade de pommes de terre ».
bool sideNameMatches(String suggested, String candidate) {
  final a = sideNameKey(suggested);
  final b = sideNameKey(candidate);
  if (a.isEmpty || b.isEmpty) return false;
  return a == b || a.startsWith('$b ') || b.startsWith('$a ');
}

/// Les candidats que le plat suggère, dans l'ordre de ses suggestions ; pour
/// une même suggestion, la recette avant la garniture — « frites » va aux
/// frites maison quand la recette existe.
List<SideCandidate> suggestedCandidatesFor(
  Recipe main,
  List<SideCandidate> candidates,
) {
  final needs = sideNeedsFor(main.tags);
  if (needs.isEmpty) return const [];
  final out = <SideCandidate>[];
  final seen = <String>{};
  for (final suggestion in main.tags.suggestedSides) {
    final matches =
        candidates
            .where(
              (c) =>
                  sideNameMatches(suggestion, c.name) && needs.any(c.provides),
            )
            .toList()
          ..sort((x, y) => (x.isRecipe ? 0 : 1).compareTo(y.isRecipe ? 0 : 1));
    for (final m in matches) {
      if (seen.add(m.id)) out.add(m);
    }
  }
  return out;
}

/// Ce que le programme a choisi, et pourquoi.
class SideChoice {
  final MealComponent component;

  /// Ce que l'accompagnement apporte au plat.
  final SideNeed need;

  /// Vrai s'il vient des accompagnements classiques du plat ; faux s'il a
  /// fallu se rabattre sur la famille de garnitures qui manquait.
  final bool fromSuggestion;

  const SideChoice({
    required this.component,
    required this.need,
    required this.fromSuggestion,
  });
}

/// Choisit un accompagnement par besoin non couvert par [main] — féculent et
/// légume, quand le plat n'apporte ni l'un ni l'autre — sans jamais poser
/// deux fois le même candidat pour deux besoins différents.
///
/// Pour chaque besoin : d'abord les accompagnements classiques du plat qui
/// l'apportent, à défaut une garniture de la famille qui manque, par rang.
/// [avoidIds] écarte ce qui a été servi la veille ou le lendemain ;
/// [usedInCycleIds] ce qui a déjà été posé ailleurs dans le cycle. On s'en
/// écarte tant qu'il reste un autre candidat, sans jamais laisser le besoin
/// sans réponse pour autant. [takenIds] — les accompagnements déjà posés —
/// ne sont jamais reproposés. Un besoin sans candidat restant se saute :
/// mieux vaut un repas à deux accompagnements qu'un même plat posé deux fois
/// pour faire nombre.
///
/// [needs] remplace ce qui manque au plat seul : l'éditeur du repas ne
/// propose que pour ce que ses accompagnements ne couvrent pas encore.
///
/// [criteria] : les critères compris des préférences du jour. Un candidat qui
/// viole une exclusion (« contient : gluten ») n'est jamais proposé ; parmi
/// les autres, ceux dont les exclusions sont vérifiées passent avant ceux
/// aux allergènes non renseignés, dont la justification le dit.
List<SideChoice> chooseSides({
  required Recipe main,
  required List<SideCandidate> candidates,
  Set<String> avoidIds = const {},
  Set<String> usedInCycleIds = const {},
  Set<String> takenIds = const {},
  List<SideNeed>? needs,
  PlanningCriteria criteria = PlanningCriteria.empty,
}) {
  final wanted = needs ?? sideNeedsFor(main.tags);
  if (criteria.hasExclusions) {
    candidates = [
      for (final c in candidates)
        if (!violatesExclusion(criteria, c.criteriaItem)) c,
    ];
  }
  if (wanted.isEmpty || candidates.isEmpty) return const [];
  bool verified(SideCandidate c) =>
      !criteria.hasExclusions || exclusionsVerified(criteria, c.criteriaItem);
  final suggested = suggestedCandidatesFor(main, candidates);
  final taken = {...takenIds};
  final out = <SideChoice>[];

  for (final need in wanted) {
    final ordered = <SideCandidate>[];
    final seen = <String>{};
    for (final c in suggested) {
      if (c.provides(need) && seen.add(c.id)) ordered.add(c);
    }
    final suggestedCount = ordered.length;
    final fallback = candidates.where((c) => c.provides(need)).toList()
      ..sort((x, y) {
        final byOrder = x.sortOrder.compareTo(y.sortOrder);
        return byOrder != 0
            ? byOrder
            : x.name.toLowerCase().compareTo(y.name.toLowerCase());
      });
    for (final c in fallback) {
      if (seen.add(c.id)) ordered.add(c);
    }
    final open = [
      for (final c in ordered)
        if (!taken.contains(c.id)) c,
    ];
    if (open.isEmpty) continue;
    final free = [...open.where(verified), ...open.where((c) => !verified(c))];

    SideCandidate? pick;
    for (final c in free) {
      if (!avoidIds.contains(c.id) && !usedInCycleIds.contains(c.id)) {
        pick = c;
        break;
      }
    }
    pick ??= free.cast<SideCandidate?>().firstWhere(
      (c) => !avoidIds.contains(c!.id),
      orElse: () => null,
    );
    pick ??= free.first;

    taken.add(pick.id);
    final fromSuggestion = ordered.indexOf(pick) < suggestedCount;
    final unverified = verified(pick) ? '' : ' Allergènes non renseignés.';
    final justification = fromSuggestion
        ? 'Le plat n\'apporte pas de ${need.label} : ${pick.name}, '
              'accompagnement classique.$unverified'
        : 'Le plat n\'apporte pas de ${need.label} : ${pick.name}, faute '
              'd\'accompagnement classique disponible.$unverified';
    out.add(
      SideChoice(
        component: pick.toComponent(justification: justification),
        need: need,
        fromSuggestion: fromSuggestion,
      ),
    );
  }
  return out;
}

/// Ce qu'on sait de ce que le plat et ses accompagnements apportent.
enum DishSideState {
  /// Féculent et légume couverts : « Plat complet » dans l'éditeur.
  complete,

  /// Il manque au moins un féculent ou un légume : « Il manque : légume ».
  missing,

  /// Le plat n'est pas classé : « Apports du plat inconnus ».
  unknown,

  /// Pas un plat (accompagnement, entrée, dessert, snack) : rien à dire.
  notApplicable,
}

/// Le bilan d'un plat et de ses accompagnements.
class DishSideStatus {
  final DishSideState state;

  /// Ce qui manque encore, le féculent d'abord. Vide hors [DishSideState.missing].
  final List<SideNeed> missing;

  const DishSideStatus(this.state, {this.missing = const []});

  bool get isComplete => state == DishSideState.complete;

  /// « Il manque : légume », « Il manque : féculent, légume ».
  String get missingLabel =>
      'Il manque : ${missing.map((n) => n.label).join(', ')}';
}

/// La famille de garniture qui apporte [need] : féculent ou pain pour le
/// féculent, légume ou salade pour le légume.
bool stapleCategoryProvides(StapleCategory category, SideNeed need) =>
    switch (need) {
      SideNeed.feculent =>
        category == StapleCategory.feculent || category == StapleCategory.pain,
      SideNeed.legume =>
        category == StapleCategory.legume || category == StapleCategory.salade,
    };

/// Ce qu'apporte un accompagnement posé : une garniture par sa famille
/// ([stapleCategories], par identifiant), une recette par son `contains`
/// ([recipesById]), un texte libre par son `provides`. Vide quand on ne sait
/// pas : garniture ou recette introuvables, texte libre sans apport coché.
Set<SideNeed> sideComponentProvides(
  MealComponent component, {
  Map<String, StapleCategory> stapleCategories = const {},
  Map<String, Recipe> recipesById = const {},
}) {
  if (component.isStaple) {
    final category = stapleCategories[component.stapleId];
    if (category == null) return const {};
    return {
      for (final n in SideNeed.values)
        if (stapleCategoryProvides(category, n)) n,
    };
  }
  final keys = component.isRecipe
      ? (recipesById[component.recipeId]?.tags.contains ?? const <String>[])
      : component.provides;
  return {
    for (final n in SideNeed.values)
      if (keys.contains(n.name)) n,
  };
}

/// Ce qui manque à un plat, en comptant ses accompagnements déjà posés.
///
/// Plat non classé ([RecipeTags.mealRole] absent) : apports inconnus. Autre
/// rôle qu'un plat : rien à dire. Sinon, chaque besoin que le plat n'apporte
/// pas ([sideNeedsFor]) doit être couvert par au moins un accompagnement
/// ([sideComponentProvides]).
DishSideStatus dishSideStatus({
  required RecipeTags mainTags,
  required Iterable<MealComponent> sides,
  Map<String, StapleCategory> stapleCategories = const {},
  Map<String, Recipe> recipesById = const {},
}) {
  if (!mainTags.hasMealRole) return const DishSideStatus(DishSideState.unknown);
  if (mainTags.mealRole != 'plat') {
    return const DishSideStatus(DishSideState.notApplicable);
  }
  final covered = <SideNeed>{
    for (final c in sides)
      ...sideComponentProvides(
        c,
        stapleCategories: stapleCategories,
        recipesById: recipesById,
      ),
  };
  final missing = [
    for (final n in sideNeedsFor(mainTags))
      if (!covered.contains(n)) n,
  ];
  return missing.isEmpty
      ? const DishSideStatus(DishSideState.complete)
      : DishSideStatus(DishSideState.missing, missing: missing);
}
