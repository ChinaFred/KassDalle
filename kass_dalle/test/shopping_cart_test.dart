import 'dart:convert';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/domain/planning_week.dart';
import 'package:kass_dalle/features/recipes/data/shopping_cart_repository.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/domain/shopping_cart.dart';
import 'package:shared_preferences/shared_preferences.dart';

ShoppingItem item(
  String name,
  String qty,
  String unit, {
  String? source,
  bool checked = false,
}) => ShoppingItem(
  name: name,
  quantities: [(qty: qty, unit: unit)],
  category: 'Autres',
  source: source,
  checked: checked,
);

/// Le panier de courses personnel : `users/{uid}/shopping/current`.
void main() {
  group('ShoppingCart — lecture et écriture du document', () {
    test('les articles se relisent dans l\'ordre d\'écriture', () {
      final items = [item('Riz', '200', 'g'), item('Ail', '2', '')];
      final cart = ShoppingCart.fromFirestore({
        'items': ShoppingCart.itemsToFirestore(items),
      });
      expect(cart.items.map((i) => i.name), ['Riz', 'Ail']);
      expect(cart.items.first.quantities.single, (qty: '200', unit: 'g'));
    });

    test('une entrée sans nom est écartée, le reste se lit', () {
      final cart = ShoppingCart.fromFirestore({
        'items': {
          'riz': {'name': 'Riz', 'pos': 0, 'checked': true},
          'x': {'pos': 1},
          'y': 'illisible',
        },
      });
      expect(cart.length, 1);
      expect(cart.checkedCount, 1);
      expect(cart.uncheckedCount, 0);
    });

    test('document absent : panier vide', () {
      expect(ShoppingCart.fromFirestore(null).isEmpty, isTrue);
      expect(ShoppingCart.fromFirestore({'items': []}).isEmpty, isTrue);
    });

    test('les longueurs sont bornées à l\'écriture', () {
      final long = 'a' * 1000;
      final map = item('Riz', '1', 'g', source: long).toFirestore();
      expect((map['source'] as String).length, kShoppingSourceMax);
    });

    test('ancienne liste locale : clés courtes, et `q`/`u` à plat', () {
      final recent = ShoppingItem.fromLegacyJson({
        'n': 'Lait de coco',
        'qs': [
          {'q': '400', 'u': 'ml'},
          {'q': '250', 'u': 'g'},
        ],
        'c': 'Épicerie',
        's': 'Curry',
        'x': true,
      })!;
      expect(recent.quantities.length, 2);
      expect(recent.checked, isTrue);
      final old = ShoppingItem.fromLegacyJson({
        'n': 'Riz',
        'q': '1',
        'u': 'kg',
      });
      expect(old!.quantities.single, (qty: '1', unit: 'kg'));
      expect(ShoppingItem.fromLegacyJson({'q': '1'}), isNull);
    });
  });

  group('mergeShoppingItems — « Ajouter »', () {
    test(
      'même produit : une ligne, quantités additionnées, sources réunies',
      () {
        final merged = mergeShoppingItems(
          [item('Riz', '200', 'g', source: 'Curry')],
          [item('riz', '300', 'g', source: 'Poulet basquaise')],
        );
        expect(merged.length, 1);
        expect(merged.single.quantities.single.unit, 'g');
        expect(merged.single.quantities.single.qty, '500');
        expect(merged.single.source, 'Curry · Poulet basquaise');
      },
    );

    test('une ligne cochée qui reçoit une quantité redevient à acheter', () {
      final merged = mergeShoppingItems(
        [
          item('Riz', '200', 'g', checked: true),
          item('Sel', '', '', checked: true),
        ],
        [item('Riz', '100', 'g')],
      );
      expect(merged[0].checked, isFalse);
      expect(merged[1].checked, isTrue);
    });
  });

  test('shoppingItemsForRecipe : ingrédients bruts sans produits d\'achat', () {
    final items = shoppingItemsForRecipe(
      products: const [],
      fallbackIngredients: const [
        RecipeIngredient(name: 'Farine', qty: '200', unit: 'g'),
      ],
      recipeTitre: 'Crêpes',
    );
    expect(items.single.name, 'Farine');
    expect(items.single.source, 'Crêpes');
  });

  group('ShoppingCartRepository', () {
    late FakeFirebaseFirestore firestore;
    late ShoppingCartRepository repo;
    const uid = 'u1';

    ShoppingCartRepository build() => ShoppingCartRepository(
      firestore: firestore,
      errorReportService: ErrorReportService(firestore: firestore),
    );

    Future<ShoppingCart> stored() => repo.load(uid);

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      firestore = FakeFirebaseFirestore();
      repo = build();
    });

    test('panier vide : « Ajouter » écrit les articles', () async {
      final result = await repo.addItems(uid, [
        item('Riz', '200', 'g'),
      ], mode: ShoppingAddMode.add);
      expect(result.previous, isEmpty);
      expect((await stored()).items.single.name, 'Riz');
    });

    test('« Ajouter » fusionne avec la liste en place', () async {
      await repo.addItems(uid, [
        item('Riz', '200', 'g'),
        item('Ail', '2', ''),
      ], mode: ShoppingAddMode.add);
      await repo.addItems(uid, [
        item('Riz', '100', 'g'),
        item('Oignon', '1', ''),
      ], mode: ShoppingAddMode.add);
      final cart = await stored();
      expect(cart.items.map((i) => i.name), ['Riz', 'Ail', 'Oignon']);
      expect(cart.items.first.quantities.single.qty, '300');
    });

    test(
      '« Remplacer » efface la liste et rend l\'ancienne pour Annuler',
      () async {
        await repo.addItems(uid, [
          item('Riz', '200', 'g'),
        ], mode: ShoppingAddMode.add);
        final result = await repo.addItems(uid, [
          item('Pâtes', '500', 'g'),
        ], mode: ShoppingAddMode.replace);
        expect((await stored()).items.map((i) => i.name), ['Pâtes']);
        expect(result.previous.single.name, 'Riz');

        await repo.restore(uid, result.previous);
        expect((await stored()).items.map((i) => i.name), ['Riz']);
      },
    );

    test('au-delà de la borne : rien n\'est écrit', () async {
      final many = [
        for (var i = 0; i <= kShoppingCartMaxItems; i++)
          item('Produit $i', '1', ''),
      ];
      await expectLater(
        repo.addItems(uid, many, mode: ShoppingAddMode.add),
        throwsA(isA<ShoppingCartFullException>()),
      );
      expect((await stored()).isEmpty, isTrue);
    });

    test('cocher n\'écrit que la case, retirer les cochés, vider', () async {
      await repo.addItems(uid, [
        item('Riz', '200', 'g'),
        item('Ail', '2', ''),
      ], mode: ShoppingAddMode.add);
      final riz = (await stored()).items.first;
      await repo.setChecked(uid, riz.key, true);
      var cart = await stored();
      expect(cart.items.first.checked, isTrue);
      expect(cart.items.first.quantities.single.qty, '200');
      expect(cart.items.map((i) => i.name), ['Riz', 'Ail']);

      await repo.removeItems(uid, [riz.key]);
      cart = await stored();
      expect(cart.items.map((i) => i.name), ['Ail']);

      await repo.clear(uid);
      expect((await stored()).isEmpty, isTrue);
    });

    test('le flux suit les écritures', () async {
      final seen = <int>[];
      final sub = repo.watch(uid).listen((c) => seen.add(c.length));
      await repo.addItems(uid, [
        item('Riz', '200', 'g'),
      ], mode: ShoppingAddMode.add);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(seen.last, 1);
    });

    group('reprise de l\'ancienne liste locale', () {
      String legacy(List<Map<String, dynamic>> items) => json.encode(items);

      test(
        'panier vide : la liste locale est reprise, les clés effacées',
        () async {
          SharedPreferences.setMockInitialValues({
            'sl_items_$uid': legacy([
              {
                'n': 'Riz',
                'qs': [
                  {'q': '200', 'u': 'g'},
                ],
                'c': 'Épicerie',
                'x': true,
              },
              {'n': 'Ail', 'q': '2', 'u': ''},
            ]),
            'sl_date_$uid': '2026-10-01',
          });
          repo = build();
          expect(await repo.migrateLocalList(uid), isTrue);
          final cart = await stored();
          expect(cart.items.map((i) => i.name), ['Riz', 'Ail']);
          expect(cart.items.first.checked, isTrue);
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getString('sl_items_$uid'), isNull);
          expect(prefs.getString('sl_date_$uid'), isNull);
        },
      );

      test(
        'panier déjà rempli : il fait foi, la liste locale est effacée',
        () async {
          await repo.addItems(uid, [
            item('Pâtes', '500', 'g'),
          ], mode: ShoppingAddMode.add);
          SharedPreferences.setMockInitialValues({
            'sl_items_$uid': legacy([
              {'n': 'Riz', 'q': '1', 'u': 'kg'},
            ]),
          });
          repo = build();
          expect(await repo.migrateLocalList(uid), isFalse);
          expect((await stored()).items.map((i) => i.name), ['Pâtes']);
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getString('sl_items_$uid'), isNull);
        },
      );

      test(
        'texte illisible : rien n\'est repris, la clé est effacée',
        () async {
          SharedPreferences.setMockInitialValues({'sl_items_$uid': '{pas du'});
          repo = build();
          expect(await repo.migrateLocalList(uid), isFalse);
          expect((await stored()).isEmpty, isTrue);
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getString('sl_items_$uid'), isNull);
          // L'erreur de lecture est remontée.
          final reports = await firestore.collection('error_reports').get();
          expect(reports.docs, isNotEmpty);
        },
      );

      test('pas de liste locale : rien à faire', () async {
        expect(await repo.migrateLocalList(uid), isFalse);
        expect((await stored()).isEmpty, isTrue);
      });

      test('le flux reprend la liste avant de lire le panier', () async {
        SharedPreferences.setMockInitialValues({
          'sl_items_$uid': legacy([
            {'n': 'Riz', 'q': '1', 'u': 'kg'},
          ]),
        });
        repo = build();
        final first = await repo.watchAfterMigration(uid).first;
        expect(first.items.single.name, 'Riz');
      });
    });
  });

  group('planningShoppingBreakdown — décompte par planning', () {
    PlannedMeal meal(String id, String uid) => PlannedMeal(
      id: id,
      uid: uid,
      recipeTitre: 'Plat',
      plannedAt: DateTime(2026, 10, 20, 19),
      durationMinutes: 0,
      createdAt: DateTime(2026, 10, 1),
    );
    String nameOf(String uid) =>
        {'me': 'Vous', 'm': 'Marie', 'a': 'Alain'}[uid]!;

    test('un seul planning : pas de décompte', () {
      expect(
        planningShoppingBreakdown(
          [meal('1', 'm'), meal('2', 'm')],
          myUid: 'me',
          nameOf: nameOf,
        ),
        isNull,
      );
    });

    test('Mon planning d\'abord, puis les autres par prénom', () {
      expect(
        planningShoppingBreakdown(
          [meal('1', 'm'), meal('2', 'me'), meal('3', 'a'), meal('4', 'm')],
          myUid: 'me',
          nameOf: nameOf,
        ),
        '1 de Mon planning, 1 du planning de Alain, 2 du planning de Marie',
      );
    });
  });
}
