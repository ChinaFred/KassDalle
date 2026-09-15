import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/utils/shopping_products.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Regroupement des lignes de courses — rejoue la fixture partagée avec le
/// serveur (`functions/src/tests/shoppingProducts.test.ts`).
///
/// Le serveur regroupe à l'écriture d'une recette ; le client regroupe entre
/// recettes dans le planning et dans la feuille de courses. Un écart entre les
/// deux ne lève rien : le riz d'une garniture ferait une seconde ligne, ou deux
/// kilos deviendraient deux grammes.
void main() {
  final file = File('test-fixtures/shopping_products.json');
  if (!file.existsSync()) {
    fail(
      'Fixture introuvable : ${file.absolute.path}. '
      'Les tests doivent être lancés depuis le dossier kass_dalle/.',
    );
  }
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final families = (fixture['unit_families'] as List)
      .cast<Map<String, dynamic>>();
  final totals = (fixture['totals'] as List).cast<Map<String, dynamic>>();
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

  test('la fixture partagée est non vide', () {
    expect(families, isNotEmpty);
    expect(totals, isNotEmpty);
    expect(cases, isNotEmpty);
  });

  group("famille d'unité", () {
    for (final c in families) {
      final unit = c['unit'] as String;
      test('« ${unit.isEmpty ? '(vide)' : unit} » → ${c['family']}', () {
        final out = shoppingUnitFamily(unit);
        expect(out.family, c['family']);
        expect(out.factor, closeTo((c['factor'] as num).toDouble(), 1e-9));
      });
    }
  });

  group("écriture d'un total", () {
    for (final c in totals) {
      test('${c['total']} ${c['family']} (${c['why']})', () {
        final out = formatShoppingTotal(
          (c['total'] as num).toDouble(),
          c['family'] as String,
        );
        expect(out.qty, c['qty']);
        expect(out.unit, c['unit']);
      });
    }
  });

  group('regroupement', () {
    for (final c in cases) {
      test(c['why'] as String, () {
        // Le produit acheté remplace le nom avant le regroupement : côté
        // serveur, `deriveShoppingProducts` fait cette substitution ; côté
        // client, les produits arrivent déjà nommés par le serveur.
        final inputs = (c['inputs'] as List).cast<Map<String, dynamic>>().map((
          i,
        ) {
          final alias = (i['shopping_product'] as String? ?? '').trim();
          return RecipeShoppingProduct(
            name: alias.isNotEmpty ? alias : i['name'] as String,
            qty: i['qty'] as String,
            unit: i['unit'] as String,
          );
        });
        final out = mergeShoppingProducts(
          inputs,
        ).map((p) => {'name': p.name, 'qty': p.qty, 'unit': p.unit}).toList();
        final expected = (c['expected'] as List)
            .cast<Map<String, dynamic>>()
            .map((e) => {'name': e['name'], 'qty': e['qty'], 'unit': e['unit']})
            .toList();
        expect(out, expected);
      });
    }
  });

  group("identité d'un produit", () {
    test('singulier et pluriel, casse et accents, mots de préparation', () {
      expect(shoppingProductKey('Tomates'), shoppingProductKey('tomate'));
      expect(shoppingProductKey('Œufs'), shoppingProductKey('oeuf'));
      expect(shoppingProductKey('oignon haché'), shoppingProductKey('oignons'));
    });
  });
}
