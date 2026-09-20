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

/// Ce qu'un plat n'apporte pas, et qu'un accompagnement doit apporter.
enum SideNeed {
  feculent,
  legume;

  String get label => switch (this) {
    SideNeed.feculent => 'féculent',
    SideNeed.legume => 'légume',
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

  /// Vrai si ce candidat apporte ce qui manque.
  bool provides(SideNeed need) {
    final s = staple;
    if (s != null) {
      return switch (need) {
        SideNeed.feculent =>
          s.category == StapleCategory.feculent ||
              s.category == StapleCategory.pain,
        SideNeed.legume =>
          s.category == StapleCategory.legume ||
              s.category == StapleCategory.salade,
      };
    }
    final contains = recipe!.tags.contains;
    return switch (need) {
      SideNeed.feculent => contains.contains('feculent'),
      SideNeed.legume => contains.contains('legume'),
    };
  }

  MealComponent toComponent({String? justification}) => staple != null
      ? MealComponent.staple(staple!, justification: justification)
      : MealComponent.recipe(recipe!, justification: justification);
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

/// Choisit UN accompagnement pour [main], ou rien.
///
/// Rien quand la recette n'est pas un plat, n'est pas classée, ou n'a besoin
/// de rien. Sinon : d'abord les accompagnements classiques du plat, dans
/// l'ordre ; à défaut, une garniture de la famille qui manque, par rang.
/// [avoidIds] écarte ce qui a été servi la veille ou le lendemain ;
/// [usedInCycleIds] ce qui a déjà été posé ailleurs dans le cycle. On s'en
/// écarte tant qu'il reste un autre candidat, sans jamais laisser le plat
/// seul pour autant.
SideChoice? chooseSide({
  required Recipe main,
  required List<SideCandidate> candidates,
  Set<String> avoidIds = const {},
  Set<String> usedInCycleIds = const {},
}) {
  final needs = sideNeedsFor(main.tags);
  if (needs.isEmpty || candidates.isEmpty) return null;
  final primary = needs.first;

  final ordered = <SideCandidate>[];
  final seen = <String>{};
  for (final c in suggestedCandidatesFor(main, candidates)) {
    if (seen.add(c.id)) ordered.add(c);
  }
  final suggestedCount = ordered.length;
  final fallback = candidates.where((c) => c.provides(primary)).toList()
    ..sort((x, y) {
      final byOrder = x.sortOrder.compareTo(y.sortOrder);
      return byOrder != 0
          ? byOrder
          : x.name.toLowerCase().compareTo(y.name.toLowerCase());
    });
  for (final c in fallback) {
    if (seen.add(c.id)) ordered.add(c);
  }
  if (ordered.isEmpty) return null;

  SideCandidate? pick;
  for (final c in ordered) {
    if (!avoidIds.contains(c.id) && !usedInCycleIds.contains(c.id)) {
      pick = c;
      break;
    }
  }
  pick ??= ordered.cast<SideCandidate?>().firstWhere(
    (c) => !avoidIds.contains(c!.id),
    orElse: () => null,
  );
  pick ??= ordered.first;

  final fromSuggestion = ordered.indexOf(pick) < suggestedCount;
  final need = needs.firstWhere(pick.provides, orElse: () => primary);
  final justification = fromSuggestion
      ? 'Le plat n\'apporte pas de ${need.label} : ${pick.name}, '
            'accompagnement classique.'
      : 'Le plat n\'apporte pas de ${need.label} : ${pick.name}, faute '
            'd\'accompagnement classique disponible.';
  return SideChoice(
    component: pick.toComponent(justification: justification),
    need: need,
    fromSuggestion: fromSuggestion,
  );
}

/// Choisit un accompagnement par besoin non couvert par [main] — féculent et
/// légume, quand le plat n'apporte ni l'un ni l'autre — sans jamais poser
/// deux fois le même candidat pour deux besoins différents.
///
/// Même logique que [chooseSide], rejouée par besoin : d'abord les
/// accompagnements classiques du plat qui apportent ce besoin précis, à
/// défaut une garniture de la famille qui manque, par rang. Un besoin sans
/// candidat restant se saute — mieux vaut un repas à deux accompagnements
/// qu'un même plat posé deux fois pour faire nombre.
List<SideChoice> chooseSides({
  required Recipe main,
  required List<SideCandidate> candidates,
  Set<String> avoidIds = const {},
  Set<String> usedInCycleIds = const {},
}) {
  final needs = sideNeedsFor(main.tags);
  if (needs.isEmpty || candidates.isEmpty) return const [];
  final suggested = suggestedCandidatesFor(main, candidates);
  final taken = <String>{};
  final out = <SideChoice>[];

  for (final need in needs) {
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
    if (ordered.isEmpty) continue;

    SideCandidate? pick;
    for (final c in ordered) {
      if (!taken.contains(c.id) &&
          !avoidIds.contains(c.id) &&
          !usedInCycleIds.contains(c.id)) {
        pick = c;
        break;
      }
    }
    pick ??= ordered.cast<SideCandidate?>().firstWhere(
      (c) => !taken.contains(c!.id) && !avoidIds.contains(c.id),
      orElse: () => null,
    );
    if (pick == null) continue;

    taken.add(pick.id);
    final fromSuggestion = ordered.indexOf(pick) < suggestedCount;
    final justification = fromSuggestion
        ? 'Le plat n\'apporte pas de ${need.label} : ${pick.name}, '
              'accompagnement classique.'
        : 'Le plat n\'apporte pas de ${need.label} : ${pick.name}, faute '
              'd\'accompagnement classique disponible.';
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
