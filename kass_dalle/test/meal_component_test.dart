import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/meal_component.dart';
import 'package:kass_dalle/features/planning/domain/meal_staple.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Un composant de repas : ce qu'il fige, ce qu'il écrit, ce qu'il compte.
void main() {
  const riz = MealStaple(
    id: 'riz',
    name: 'Riz',
    category: StapleCategory.feculent,
    quantityPerPortion: 70,
    note: 'poids cru',
  );

  group('garniture figée', () {
    test('reprend nom, part, unité, note', () {
      final c = MealComponent.staple(riz, justification: 'pas de féculent');
      expect(c.role, MealComponentRole.accompagnement);
      expect(c.stapleId, 'riz');
      expect(c.isStaple, isTrue);
      expect(c.isRecipe, isFalse);
      expect(c.label, 'Riz');
      expect(c.quantityPerPortion, 70);
      expect(c.unit, 'g');
      expect(c.note, 'poids cru');
      expect(c.shoppingProduct, isNull);
      expect(c.effectiveShoppingProduct, 'Riz');
      expect(c.sourceId, 'riz');
      expect(c.justification, 'pas de féculent');
    });

    test('le produit de courses de la purée est la pomme de terre', () {
      const puree = MealStaple(
        id: 'puree',
        name: 'Purée',
        category: StapleCategory.feculent,
        quantityPerPortion: 250,
        shoppingProduct: 'Pommes de terre',
      );
      expect(
        MealComponent.staple(puree).effectiveShoppingProduct,
        'Pommes de terre',
      );
    });

    test('quantité pour les parts : 4 parts, 280 g ; sans parts, une part', () {
      final c = MealComponent.staple(riz);
      expect(c.totalQuantityFor(4), 280);
      expect(c.totalQuantityFor(null), 70);
      expect(c.totalQuantityFor(0), 70);
      expect(c.quantityLabel, '70 g par part');
    });
  });

  group('recette d\'accompagnement', () {
    test('porte l\'identifiant et le titre, pas de quantité', () {
      final t = DateTime(2026, 1, 1);
      final frites = Recipe(
        id: 'frites',
        titre: 'Frites maison',
        langue: 'fr',
        rawCooklang: '',
        imageUrls: const [],
        reviewStatus: ReviewStatus.validated,
        tags: const RecipeTags(mealRole: 'accompagnement'),
        ingredientsIndex: const [],
        createdBy: 'u',
        createdAt: t,
        updatedAt: t,
      );
      final c = MealComponent.recipe(frites);
      expect(c.isRecipe, isTrue);
      expect(c.recipeId, 'frites');
      expect(c.label, 'Frites maison');
      expect(c.quantityLabel, isNull);
      expect(c.totalQuantityFor(4), isNull);
      expect(c.sourceId, 'frites');
    });
  });

  group('Firestore', () {
    test('aller-retour d\'une garniture', () {
      final c = MealComponent.staple(riz, justification: 'x');
      final back = MealComponent.fromMap(c.toMap());
      expect(back.stapleId, 'riz');
      expect(back.recipeId, isNull);
      expect(back.quantityPerPortion, 70);
      expect(back.unit, 'g');
      expect(back.note, 'poids cru');
      expect(back.justification, 'x');
      expect(c.toMap().containsKey('recipe_id'), isFalse);
      expect(c.toMap().containsKey('shopping_product'), isFalse);
    });

    test('une liste abîmée ne casse pas la lecture', () {
      final out = MealComponent.listFromFirestore([
        {'role': 'accompagnement', 'staple_id': 'riz', 'label': 'Riz'},
        'pas une carte',
        {'role': 'inconnu', 'label': 'Sans rôle connu'},
      ]);
      expect(out, hasLength(2));
      expect(out.first.stapleId, 'riz');
      expect(out.last.role, MealComponentRole.autre);
      expect(out.last.toMap()['role'], 'inconnu');
    });

    test('pas une liste : rien', () {
      expect(MealComponent.listFromFirestore(null), isEmpty);
      expect(MealComponent.listFromFirestore('riz'), isEmpty);
    });
  });

  test('résumé en une ligne', () {
    expect(
      componentsSummary([
        MealComponent.staple(riz),
        const MealComponent(
          role: MealComponentRole.dessert,
          label: 'Tarte aux pommes',
        ),
      ]),
      'Riz · Tarte aux pommes',
    );
  });

  group('lecture tolérante', () {
    test('rôle absent : accompagnement', () {
      final c = MealComponent.fromMap({'label': 'Riz'});
      expect(c.role, MealComponentRole.accompagnement);
      expect(c.toMap()['role'], 'accompagnement');
    });

    test('rôle connu : lu et réécrit', () {
      final c = MealComponent.fromMap({'role': 'fromage', 'label': 'Comté'});
      expect(c.role, MealComponentRole.fromage);
      expect(c.roleKey, isNull);
      expect(c.toMap()['role'], 'fromage');
      expect(c.isMainSide, isFalse);
    });

    test('rôle inconnu : lu « autre », réécrit tel quel', () {
      final c = MealComponent.fromMap({'role': 'trou_normand', 'label': 'x'});
      expect(c.role, MealComponentRole.autre);
      expect(c.isMainSide, isFalse);
      expect(c.toMap()['role'], 'trou_normand');
    });

    test('champs inconnus réécrits, side_of lu', () {
      final data = {
        'role': 'accompagnement',
        'label': 'Frites maison',
        'provides': ['feculent'],
        'side_of': 'p2',
      };
      final c = MealComponent.fromMap(data);
      expect(c.sideOf, 'p2');
      expect(c.isMainSide, isFalse);
      expect(c.toMap(), data);
    });
  });

  group('ordre des composants', () {
    MealComponent c(String role, String label) =>
        MealComponent.fromMap({'role': role, 'label': label});
    List<String> labels(List<MealComponent> l) => [for (final x in l) x.label];

    test('un accompagnement ajouté passe avant le dessert', () {
      final menu = [c('entree', 'Velouté'), c('dessert', 'Tatin')];
      expect(labels(insertMainSide(menu, c('accompagnement', 'Riz'))), [
        'Velouté',
        'Riz',
        'Tatin',
      ]);
    });

    test('après le dernier accompagnement du plat principal', () {
      final menu = [
        c('accompagnement', 'Riz'),
        c('fromage', 'Comté'),
        c('dessert', 'Tatin'),
      ];
      expect(labels(insertMainSide(menu, c('accompagnement', 'Haricots'))), [
        'Riz',
        'Haricots',
        'Comté',
        'Tatin',
      ]);
    });

    test(
      'repas ancien, accompagnement après le dessert : avant le dessert',
      () {
        final legacy = [
          c('entree', 'Velouté'),
          c('accompagnement', 'Riz'),
          c('dessert', 'Tatin'),
          c('accompagnement', 'Salade'),
        ];
        expect(
          labels(insertMainSide(legacy, c('accompagnement', 'Haricots'))),
          ['Velouté', 'Riz', 'Haricots', 'Tatin', 'Salade'],
        );
      },
    );

    test('sans service après le plat : à la fin', () {
      expect(labels(insertMainSide([c('entree', 'Velouté')], c('', 'Riz'))), [
        'Velouté',
        'Riz',
      ]);
    });

    test('changer de plat ne remplace que ses accompagnements', () {
      final menu = [
        c('entree', 'Velouté'),
        c('accompagnement', 'Riz'),
        MealComponent.fromMap({
          'role': 'accompagnement',
          'label': 'Purée',
          'side_of': 'p2',
        }),
        c('accompagnement', 'Haricots'),
        c('sorbet', 'Citron'),
        c('dessert', 'Tatin'),
      ];
      expect(labels(replaceMainSides(menu, [c('accompagnement', 'Pâtes')])), [
        'Velouté',
        'Pâtes',
        'Purée',
        'Citron',
        'Tatin',
      ]);
      expect(labels(replaceMainSides(menu, const [])), [
        'Velouté',
        'Purée',
        'Citron',
        'Tatin',
      ]);
    });

    test("Nouveau planning garde ce qu'il ne montre pas", () {
      final menu = [
        c('entree', 'Velouté'),
        c('entree', 'Œufs mimosa'),
        c('accompagnement', 'Riz'),
        c('accompagnement', 'Haricots'),
        c('fromage', 'Comté'),
        c('dessert', 'Tatin'),
      ];
      final merged = mergeSlotComponents(
        menu,
        starter: menu[0],
        sides: [menu[2], menu[3]],
        dessert: menu[5],
      );
      expect(labels(merged), labels(menu));
    });

    test('Nouveau planning garde tous les accompagnements du plat', () {
      final menu = [
        c('accompagnement', 'Riz'),
        c('accompagnement', 'Haricots'),
        c('accompagnement', 'Salade'),
        c('dessert', 'Tatin'),
      ];
      final merged = mergeSlotComponents(
        menu,
        sides: menu.take(3).toList(),
        dessert: menu[3],
      );
      expect(labels(merged), ['Riz', 'Haricots', 'Salade', 'Tatin']);
    });

    test('Nouveau planning : dessert retiré, entrée remplacée', () {
      final menu = [
        c('entree', 'Velouté'),
        c('accompagnement', 'Riz'),
        c('fromage', 'Comté'),
        c('dessert', 'Tatin'),
      ];
      final merged = mergeSlotComponents(
        menu,
        starter: c('entree', 'Gaspacho'),
        sides: [menu[1]],
      );
      expect(labels(merged), ['Gaspacho', 'Riz', 'Comté']);
    });

    test('Nouveau planning : un autre plat perd tous ses accompagnements', () {
      final menu = [
        c('accompagnement', 'Riz'),
        c('accompagnement', 'Haricots'),
        c('fromage', 'Comté'),
      ];
      final merged = mergeSlotComponents(
        menu,
        sides: [c('accompagnement', 'Pâtes')],
      );
      expect(labels(merged), ['Pâtes', 'Comté']);
    });

    test('repas ancien, accompagnement après le dessert : '
        'le nouveau passe avant le dessert', () {
      final legacy = [
        c('entree', 'Velouté'),
        c('dessert', 'Tatin'),
        c('accompagnement', 'Salade'),
      ];
      expect(
        labels(
          replaceMainSides(legacy, [
            c('accompagnement', 'Riz'),
            c('accompagnement', 'Haricots'),
          ]),
        ),
        ['Velouté', 'Riz', 'Haricots', 'Tatin'],
      );
    });

    test('Nouveau planning : entrée et dessert ajoutés à leur place', () {
      final merged = mergeSlotComponents(
        [c('accompagnement', 'Riz'), c('fromage', 'Comté')],
        starter: c('entree', 'Velouté'),
        sides: [c('accompagnement', 'Riz')],
        dessert: c('dessert', 'Tatin'),
      );
      expect(labels(merged), ['Velouté', 'Riz', 'Comté', 'Tatin']);
    });
  });

  group('apport d\'un texte libre', () {
    test('provides lu, réécrit, absent quand vide', () {
      final free = MealComponent.free(
        'Frites maison',
        provides: const ['feculent'],
      );
      expect(free.toMap()['provides'], ['feculent']);
      final back = MealComponent.fromMap(free.toMap());
      expect(back.provides, ['feculent']);
      expect(
        MealComponent.free('Poêlée').toMap().containsKey('provides'),
        isFalse,
      );
    });

    test('lecture tolérante : seules les chaînes non vides restent', () {
      final c = MealComponent.fromMap({
        'label': 'Poêlée',
        'provides': ['legume', 3, '', 'fibre'],
      });
      expect(c.provides, ['legume', 'fibre']);
      expect(c.extra.containsKey('provides'), isFalse);
    });

    test('« Modifier l\'apport » garde tout le reste', () {
      final c = MealComponent.fromMap({
        'role': 'accompagnement',
        'label': 'Poêlée',
        'justification': 'Choisi à la main.',
        'futur': 1,
      });
      final edited = c.withProvides(const ['legume']);
      expect(edited.toMap(), {
        'futur': 1,
        'role': 'accompagnement',
        'label': 'Poêlée',
        'justification': 'Choisi à la main.',
        'provides': ['legume'],
      });
    });
  });
}
