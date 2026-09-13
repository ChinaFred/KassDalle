import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/meal_staple.dart';
import 'package:kass_dalle/features/planning/domain/side_chooser.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// L'accompagnement d'un plat, choisi par le programme.
///
/// Un mauvais choix ne lève rien : des pâtes avec la blanquette, ou le même
/// riz trois soirs de suite, et personne ne sait d'où ça vient. Ces tests
/// disent ce qui est choisi, dans quel ordre, et quand on ne pose rien.
Recipe _recipe(
  String id,
  String titre, {
  String? role,
  List<String> contains = const [],
  List<String> sides = const [],
}) {
  final t = DateTime(2026, 1, 1);
  return Recipe(
    id: id,
    titre: titre,
    langue: 'fr',
    rawCooklang: '',
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: RecipeTags(mealRole: role, contains: contains, suggestedSides: sides),
    ingredientsIndex: const [],
    createdBy: 'u',
    createdAt: t,
    updatedAt: t,
  );
}

UserStaple _staple(
  String id,
  String name,
  StapleCategory category, {
  int order = 0,
  bool hidden = false,
}) => UserStaple(
  staple: MealStaple(
    id: id,
    name: name,
    category: category,
    quantityPerPortion: 70,
    sortOrder: order,
  ),
  isOwn: false,
  isOverridden: false,
  hidden: hidden,
);

final _staples = [
  _staple('riz', 'Riz', StapleCategory.feculent, order: 10),
  _staple('pates', 'Pâtes', StapleCategory.feculent, order: 20),
  _staple(
    'pommes_de_terre_vapeur',
    'Pommes de terre vapeur',
    StapleCategory.feculent,
    order: 80,
  ),
  _staple(
    'frites_surgelees',
    'Frites surgelées',
    StapleCategory.feculent,
    order: 100,
  ),
  _staple('haricots_verts', 'Haricots verts', StapleCategory.legume, order: 10),
  _staple('salade_verte', 'Salade verte', StapleCategory.salade, order: 10),
];

final _fritesMaison = _recipe(
  'frites',
  'Frites maison',
  role: 'accompagnement',
  contains: ['feculent'],
);

List<SideCandidate> _candidates({List<Recipe> recipes = const []}) =>
    sideCandidatesFrom(staples: _staples, recipes: recipes);

void main() {
  group('ce qui manque à un plat', () {
    test('un plat qui n\'apporte qu\'une protéine manque des deux', () {
      expect(
        sideNeedsFor(
          const RecipeTags(mealRole: 'plat', contains: ['proteine']),
        ),
        [SideNeed.feculent, SideNeed.legume],
      );
    });

    test('un plat complet ne manque de rien', () {
      expect(
        sideNeedsFor(
          const RecipeTags(
            mealRole: 'plat',
            contains: ['proteine', 'feculent', 'legume'],
          ),
        ),
        isEmpty,
      );
    });

    test('un dessert, un accompagnement, une recette non classée : rien', () {
      expect(sideNeedsFor(const RecipeTags(mealRole: 'dessert')), isEmpty);
      expect(
        sideNeedsFor(const RecipeTags(mealRole: 'accompagnement')),
        isEmpty,
      );
      expect(sideNeedsFor(const RecipeTags()), isEmpty);
    });
  });

  group('un nom de garniture en désigne un autre', () {
    test('la variété désigne la garniture', () {
      expect(sideNameMatches('riz basmati', 'Riz'), isTrue);
    });
    test('le nom court désigne la recette qui le complète', () {
      expect(sideNameMatches('frites', 'Frites maison'), isTrue);
    });
    test('accents, casse et pluriel ne comptent pas', () {
      expect(sideNameMatches('haricot vert', 'Haricots verts'), isTrue);
      expect(sideNameMatches('Purée', 'purée de pommes de terre'), isTrue);
    });
    test('un mot au milieu ne suffit pas', () {
      expect(
        sideNameMatches('pommes de terre', 'Salade de pommes de terre'),
        isFalse,
      );
    });
    test('vide ne désigne rien', () {
      expect(sideNameMatches('', 'Riz'), isFalse);
    });
  });

  group('candidats', () {
    test('garnitures visibles et recettes d\'accompagnement seulement', () {
      final out = sideCandidatesFrom(
        staples: [
          _staple('riz', 'Riz', StapleCategory.feculent),
          _staple('cache', 'Cachée', StapleCategory.feculent, hidden: true),
        ],
        recipes: [
          _fritesMaison,
          _recipe('tarte', 'Tarte aux pommes', role: 'dessert'),
          _recipe('', 'Sans identifiant', role: 'accompagnement'),
        ],
      );
      expect(out.map((c) => c.id), ['riz', 'frites']);
    });
  });

  group('choix de l\'accompagnement', () {
    final blanquette = _recipe(
      'blanquette',
      'Blanquette de veau',
      role: 'plat',
      contains: ['proteine'],
      sides: ['riz', 'pommes vapeur'],
    );

    test('la blanquette reçoit du riz, son accompagnement classique', () {
      final choice = chooseSide(main: blanquette, candidates: _candidates())!;
      expect(choice.component.stapleId, 'riz');
      expect(choice.component.quantityPerPortion, 70);
      expect(choice.need, SideNeed.feculent);
      expect(choice.fromSuggestion, isTrue);
      expect(choice.component.justification, contains('féculent'));
      expect(choice.component.justification, contains('classique'));
    });

    test('la recette d\'accompagnement passe avant la garniture', () {
      final steak = _recipe(
        'steak',
        'Steak',
        role: 'plat',
        contains: ['proteine'],
        sides: ['frites'],
      );
      final choice = chooseSide(
        main: steak,
        candidates: _candidates(recipes: [_fritesMaison]),
      )!;
      expect(choice.component.recipeId, 'frites');
      expect(choice.component.label, 'Frites maison');
      expect(choice.fromSuggestion, isTrue);
    });

    test('servi la veille, le riz cède la place : pâtes, par rang', () {
      final choice = chooseSide(
        main: blanquette,
        candidates: _candidates(),
        avoidIds: {'riz'},
      )!;
      expect(choice.component.stapleId, 'pates');
      expect(choice.fromSuggestion, isFalse);
      expect(choice.component.justification, contains('faute'));
    });

    test('déjà posé dans le cycle, on prend autre chose tant qu\'on peut', () {
      final choice = chooseSide(
        main: blanquette,
        candidates: _candidates(),
        usedInCycleIds: {'riz', 'pates'},
      )!;
      expect(choice.component.stapleId, 'pommes_de_terre_vapeur');
    });

    test('tout déjà servi : on ne laisse pas le plat seul', () {
      final choice = chooseSide(
        main: blanquette,
        candidates: _candidates(),
        avoidIds: {
          'riz',
          'pates',
          'pommes_de_terre_vapeur',
          'frites_surgelees',
        },
      )!;
      expect(choice.component.stapleId, 'riz');
    });

    test('un plat sans légume reçoit un légume', () {
      final risotto = _recipe(
        'risotto',
        'Risotto',
        role: 'plat',
        contains: ['proteine', 'feculent'],
        sides: ['haricots verts'],
      );
      final choice = chooseSide(main: risotto, candidates: _candidates())!;
      expect(choice.component.stapleId, 'haricots_verts');
      expect(choice.need, SideNeed.legume);
    });

    test('rien pour un plat complet, un dessert, une recette non classée', () {
      expect(
        chooseSide(
          main: _recipe(
            'couscous',
            'Couscous',
            role: 'plat',
            contains: ['proteine', 'feculent', 'legume'],
          ),
          candidates: _candidates(),
        ),
        isNull,
      );
      expect(
        chooseSide(
          main: _recipe('tarte', 'Tarte', role: 'dessert'),
          candidates: _candidates(),
        ),
        isNull,
      );
      expect(
        chooseSide(
          main: _recipe('x', 'Non classée'),
          candidates: _candidates(),
        ),
        isNull,
      );
    });

    test('rien sans candidat', () {
      expect(chooseSide(main: blanquette, candidates: const []), isNull);
    });
  });

  group('candidats suggérés', () {
    test('dans l\'ordre des suggestions, recette avant garniture', () {
      final main = _recipe(
        'steak',
        'Steak',
        role: 'plat',
        contains: ['proteine'],
        sides: ['frites', 'riz'],
      );
      final out = suggestedCandidatesFor(
        main,
        _candidates(recipes: [_fritesMaison]),
      );
      expect(out.map((c) => c.id), ['frites', 'frites_surgelees', 'riz']);
    });

    test('une suggestion qui n\'apporte pas ce qui manque est ignorée', () {
      final main = _recipe(
        'gratin',
        'Gratin dauphinois garni',
        role: 'plat',
        contains: ['proteine', 'feculent'],
        sides: ['riz'],
      );
      expect(suggestedCandidatesFor(main, _candidates()), isEmpty);
    });
  });
}
