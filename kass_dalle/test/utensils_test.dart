import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/cooklang_parser.dart';
import 'package:kass_dalle/core/utils/utensils.dart';

/// Ustensiles : la liste fermée et sa reconnaissance, rejouées par le serveur
/// (`functions/src/tests/utensils.test.ts`) sur la même fixture. Un écart
/// remettrait le papier sulfurisé dans la liste d'ingrédients d'un côté
/// seulement, sans lever d'erreur.
void main() {
  final file = File('test-fixtures/utensils.json');
  if (!file.existsSync()) {
    fail(
      'Fixture introuvable : ${file.absolute.path}. '
      'Les tests doivent être lancés depuis le dossier kass_dalle/.',
    );
  }
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final names = (fixture['names'] as List).cast<String>();
  final cases = (fixture['cases'] as List)
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();

  test('même liste que le serveur, dans le même ordre', () {
    expect(kUtensilNames, names);
  });

  test('chaque nom de la liste est reconnu', () {
    for (final name in names) {
      expect(isUtensil(name), isTrue, reason: name);
    }
  });

  for (final c in cases) {
    final input = c['input'] as String;
    final expected = c['utensil'] as bool;
    test(
      '« $input » → ${expected ? 'ustensile' : 'ingrédient'} (${c['why']})',
      () {
        expect(isUtensil(input), expected);
      },
    );
  }

  test('l\'éditeur ne remet pas un ustensile écrit avec @ dans la liste', () {
    final ingredients = extractIngredientsStructured(
      'Tapisser de @papier sulfurisé{1%feuille}.\n'
      'Ajouter les @moules{1%kg} et la @farine{200%g}.',
    );
    expect(ingredients.map((i) => i.name).toList(), ['moules', 'farine']);
  });
}
