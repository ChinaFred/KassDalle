import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/meal_component.dart';
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
      contains: ['proteine', 'legume'],
      sides: ['riz', 'pommes vapeur'],
    );

    SideChoice? first(List<SideChoice> out) => out.isEmpty ? null : out.first;

    test('la blanquette reçoit du riz, son accompagnement classique', () {
      final choice = first(
        chooseSides(main: blanquette, candidates: _candidates()),
      )!;
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
        contains: ['proteine', 'legume'],
        sides: ['frites'],
      );
      final choice = first(
        chooseSides(
          main: steak,
          candidates: _candidates(recipes: [_fritesMaison]),
        ),
      )!;
      expect(choice.component.recipeId, 'frites');
      expect(choice.component.label, 'Frites maison');
      expect(choice.fromSuggestion, isTrue);
    });

    test('servi la veille, le riz cède la place : pâtes, par rang', () {
      final choice = first(
        chooseSides(
          main: blanquette,
          candidates: _candidates(),
          avoidIds: {'riz'},
        ),
      )!;
      expect(choice.component.stapleId, 'pates');
      expect(choice.fromSuggestion, isFalse);
      expect(choice.component.justification, contains('faute'));
    });

    test('déjà posé dans le cycle, on prend autre chose tant qu\'on peut', () {
      final choice = first(
        chooseSides(
          main: blanquette,
          candidates: _candidates(),
          usedInCycleIds: {'riz', 'pates'},
        ),
      )!;
      expect(choice.component.stapleId, 'pommes_de_terre_vapeur');
    });

    test('tout déjà servi : on ne laisse pas le besoin sans réponse', () {
      final choice = first(
        chooseSides(
          main: blanquette,
          candidates: _candidates(),
          avoidIds: {
            'riz',
            'pates',
            'pommes_de_terre_vapeur',
            'frites_surgelees',
          },
        ),
      )!;
      expect(choice.component.stapleId, 'riz');
    });

    test('déjà posé sur le repas : jamais reproposé', () {
      final out = chooseSides(
        main: blanquette,
        candidates: _candidates(),
        takenIds: {'riz'},
      );
      expect(out.single.component.stapleId, 'pates');
    });

    test('un besoin donné remplace ce qui manque au plat seul', () {
      final nu = _recipe(
        'nu',
        'Steak nu',
        role: 'plat',
        contains: ['proteine'],
      );
      final out = chooseSides(
        main: nu,
        candidates: _candidates(),
        needs: const [SideNeed.legume],
      );
      expect(out.single.need, SideNeed.legume);
      expect(out.single.component.stapleId, 'haricots_verts');
    });

    test('rien pour un plat complet, un dessert, une recette non classée', () {
      for (final r in [
        _recipe(
          'couscous',
          'Couscous',
          role: 'plat',
          contains: ['proteine', 'feculent', 'legume'],
        ),
        _recipe('tarte', 'Tarte', role: 'dessert'),
        _recipe('x', 'Non classée'),
      ]) {
        expect(chooseSides(main: r, candidates: _candidates()), isEmpty);
      }
    });
  });

  group('ce qui manque à un plat, avec ses accompagnements', () {
    const categories = {
      'riz': StapleCategory.feculent,
      'haricots_verts': StapleCategory.legume,
      'salade_verte': StapleCategory.salade,
    };
    final plat = const RecipeTags(mealRole: 'plat', contains: ['proteine']);
    MealComponent staple(String id) => MealComponent(
      role: MealComponentRole.accompagnement,
      stapleId: id,
      label: id,
    );

    test('sans accompagnement : il manque féculent et légume', () {
      final status = dishSideStatus(mainTags: plat, sides: const []);
      expect(status.state, DishSideState.missing);
      expect(status.missing, [SideNeed.feculent, SideNeed.legume]);
      expect(status.missingLabel, 'Il manque : féculent, légume');
    });

    test('une garniture couvre sa famille, la salade vaut un légume', () {
      final status = dishSideStatus(
        mainTags: plat,
        sides: [staple('riz'), staple('salade_verte')],
        stapleCategories: categories,
      );
      expect(status.state, DishSideState.complete);
    });

    test('une recette couvre ce que dit son contains', () {
      final status = dishSideStatus(
        mainTags: plat,
        sides: [
          const MealComponent(
            role: MealComponentRole.accompagnement,
            recipeId: 'frites',
            label: 'Frites maison',
          ),
        ],
        recipesById: {'frites': _fritesMaison},
      );
      expect(status.missing, [SideNeed.legume]);
      expect(status.missingLabel, 'Il manque : légume');
    });

    test('un texte libre couvre ce qui a été coché, rien sinon', () {
      expect(
        dishSideStatus(
          mainTags: plat,
          sides: [
            MealComponent.free('Poêlée', provides: const ['legume']),
            MealComponent.free('Pain'),
          ],
        ).missing,
        [SideNeed.feculent],
      );
    });

    test('garniture inconnue du référentiel : n\'apporte rien de connu', () {
      expect(
        dishSideStatus(mainTags: plat, sides: [staple('disparue')]).missing,
        [SideNeed.feculent, SideNeed.legume],
      );
    });

    test('plat non classé : apports inconnus ; dessert : rien à dire', () {
      expect(
        dishSideStatus(mainTags: const RecipeTags(), sides: const []).state,
        DishSideState.unknown,
      );
      expect(
        dishSideStatus(
          mainTags: const RecipeTags(mealRole: 'dessert'),
          sides: const [],
        ).state,
        DishSideState.notApplicable,
      );
    });

    test('un plat complet par lui-même est complet', () {
      expect(
        dishSideStatus(
          mainTags: const RecipeTags(
            mealRole: 'plat',
            contains: ['proteine', 'feculent', 'legume'],
          ),
          sides: const [],
        ).isComplete,
        isTrue,
      );
    });
  });

  group('choix de plusieurs accompagnements', () {
    final blanquette = _recipe(
      'blanquette',
      'Blanquette de veau',
      role: 'plat',
      contains: ['proteine'],
      sides: ['riz', 'pommes vapeur'],
    );

    test(
      'un plat qui n\'apporte que la protéine reçoit féculent et légume',
      () {
        final out = chooseSides(main: blanquette, candidates: _candidates());
        expect(out.map((c) => c.need), [SideNeed.feculent, SideNeed.legume]);
        expect(out[0].component.stapleId, 'riz');
        expect(out[1].component.stapleId, 'haricots_verts');
      },
    );

    test('jamais deux fois le même candidat pour deux besoins', () {
      // Une seule recette d'accompagnement au dossier, taguée féculent ET
      // légume : elle ne doit pas se retrouver deux fois dans la sortie.
      final gratin = _recipe(
        'gratin_complet',
        'Gratin complet',
        role: 'accompagnement',
        contains: ['feculent', 'legume'],
      );
      final steakSansCote = _recipe(
        'steak2',
        'Steak',
        role: 'plat',
        contains: ['proteine'],
        sides: ['gratin complet'],
      );
      final out = chooseSides(
        main: steakSansCote,
        candidates: _candidates(recipes: [gratin]),
      );
      final ids = out.map((c) => c.component.recipeId ?? c.component.stapleId);
      expect(ids.toSet().length, out.length);
    });

    test('un plat complet ne reçoit rien', () {
      expect(
        chooseSides(
          main: _recipe(
            'couscous',
            'Couscous',
            role: 'plat',
            contains: ['proteine', 'feculent', 'legume'],
          ),
          candidates: _candidates(),
        ),
        isEmpty,
      );
    });

    test('rien sans candidat', () {
      expect(chooseSides(main: blanquette, candidates: const []), isEmpty);
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
