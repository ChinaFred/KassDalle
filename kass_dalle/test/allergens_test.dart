import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/allergens.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Les allergènes côté client : la liste affichée et la lecture du champ
/// `allergens` d'une recette. Les clés sont celles du serveur, qui seul lit la
/// réponse du modèle ; un écart ferait afficher une clé technique ou perdre
/// un libellé, sans lever d'erreur. La fixture partagée les verrouille.
void main() {
  final file = File('test-fixtures/allergens.json');
  if (!file.existsSync()) {
    fail(
      'Fixture introuvable : ${file.absolute.path}. '
      'Les tests doivent être lancés depuis le dossier kass_dalle/.',
    );
  }
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final entries = (fixture['allergens'] as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();

  test('mêmes clés que le serveur, dans l\'ordre du règlement', () {
    expect(kAllergenKeys, entries.map((e) => e['key'] as String).toList());
  });

  test('mêmes libellés que le serveur', () {
    for (final e in entries) {
      expect(allergenLabel(e['key'] as String), e['label'], reason: e['key']);
    }
    expect(kAllergenLabels.length, kAllergenKeys.length);
  });

  test('une clé inconnue reste lisible, en fin de liste', () {
    expect(allergenLabel('lactose'), 'lactose');
    expect(sortAllergenKeys(['lait', 'lactose', 'gluten', 'lait']), [
      'gluten',
      'lait',
      'lactose',
    ]);
  });

  group('champ allergens d\'une recette', () {
    Map<String, dynamic> base() => {
      'titre': 'Sablés',
      'created_by': 'u1',
      'created_at': Timestamp.fromDate(DateTime(2026, 10, 1)),
      'updated_at': Timestamp.fromDate(DateTime(2026, 10, 1)),
    };

    test('absent : null', () {
      expect(Recipe.fromFirestore('r1', base()).allergens, isNull);
    });

    test('présent : lu, trié, ingrédients en cause par clé', () {
      final recipe = Recipe.fromFirestore('r1', {
        ...base(),
        'allergens': {
          'present': ['lait', 'gluten'],
          'complete': true,
          'by_ingredient': {
            'gluten': ['farine'],
            'lait': ['beurre', 'crème'],
          },
          'computed_at': Timestamp.fromDate(DateTime(2026, 10, 11)),
        },
      });
      final a = recipe.allergens!;
      expect(a.present, ['gluten', 'lait']);
      expect(a.complete, isTrue);
      expect(a.ingredientsFor('lait'), ['beurre', 'crème']);
      expect(a.ingredientsFor('oeuf'), isEmpty);
      expect(a.computedAt, DateTime(2026, 10, 11));
    });

    test('le client ne l\'écrit jamais', () {
      final recipe = Recipe.fromFirestore('r1', {
        ...base(),
        'allergens': {'present': <String>[], 'complete': false},
      });
      expect(recipe.toFirestore().containsKey('allergens'), isFalse);
      expect(recipe.copyWith(titre: 'Autre').allergens, isNotNull);
    });
  });
}
