import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/meal_staple.dart';
import 'package:kass_dalle/features/planning/domain/planning_criteria.dart';

/// Critères structurés du planning, côté client : lecture du cache, réunion
/// des critères d'un créneau, prédicat d'exclusion des accompagnements et des
/// choix faits à la main. Le serveur rejoue la même fixture
/// (`functions/src/tests/planningCriteria.test.ts`) ; un écart laisserait le
/// programme proposer un accompagnement que le serveur aurait écarté.
void main() {
  final file = File('test-fixtures/planning_criteria.json');
  if (!file.existsSync()) {
    fail(
      'Fixture introuvable : ${file.absolute.path}. '
      'Les tests doivent être lancés depuis le dossier kass_dalle/.',
    );
  }
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

  CriteriaItem itemOf(Map<String, dynamic> raw) {
    final a = raw['allergens'];
    return CriteriaItem(
      allergens: a is Map
          ? (
              present: (a['present'] as List).cast<String>(),
              complete: a['complete'] == true,
            )
          : null,
      mainProtein: raw['main_protein'] as String?,
      mainStarch: raw['main_starch'] as String?,
    );
  }

  test('mêmes clés, même ordre, mêmes régimes que le serveur', () {
    final criteria = (fixture['criteria'] as List).cast<Map>();
    expect(
      CriterionKey.values.map((k) => k.key).toList(),
      criteria.map((c) => c['key']).toList(),
    );
    for (final c in criteria) {
      expect(CriterionKey.fromKey(c['key'])!.regime.name, c['regime']);
    }
    final bounds = fixture['max_duration_bounds'] as Map;
    expect(kMaxDurationMin, bounds['min']);
    expect(kMaxDurationMax, bounds['max']);
  });

  group('lecture d\'un objet de critères', () {
    for (final c in (fixture['read_cases'] as List).cast<Map>()) {
      test(c['name'] as String, () {
        expect(PlanningCriteria.fromMap(c['raw']).toMap(), c['expected']);
      });
    }
  });

  group('réunion des critères d\'un créneau', () {
    for (final c in (fixture['merge_cases'] as List).cast<Map>()) {
      test(c['name'] as String, () {
        final merged = PlanningCriteria.merge([
          for (final p in c['parts'] as List) PlanningCriteria.fromMap(p),
        ]);
        expect(merged.toMap(), c['expected']);
      });
    }
  });

  group('prédicat d\'exclusion', () {
    for (final c in (fixture['exclusion_cases'] as List).cast<Map>()) {
      test(c['name'] as String, () {
        final results = checkExclusions(
          PlanningCriteria.fromMap(c['criteria']),
          itemOf(Map<String, dynamic>.from(c['item'] as Map)),
        );
        expect([
          for (final r in results)
            {'key': r.key.key, 'verdict': r.verdict.name, 'values': r.values},
        ], c['expected']);
        for (final r in results) {
          expect(r.key.regime, CriterionRegime.exclusion);
        }
      });
    }
  });

  group('choix à la main', () {
    const glutenFree = PlanningCriteria(excludedAllergens: ['gluten']);

    test('une garniture qui contient l\'allergène est signalée', () {
      const staple = MealStaple(
        id: 'pates',
        name: 'Pâtes',
        category: StapleCategory.feculent,
        quantityPerPortion: 80,
        allergens: ['gluten', 'oeuf'],
      );
      expect(
        exclusionWarning(glutenFree, CriteriaItem.ofStaple(staple)),
        'contient : gluten',
      );
    });

    test('allergènes non renseignés : dit, sans écarter', () {
      const staple = MealStaple(
        id: 'riz',
        name: 'Riz',
        category: StapleCategory.feculent,
        quantityPerPortion: 70,
      );
      final item = CriteriaItem.ofStaple(staple);
      expect(exclusionWarning(glutenFree, item), 'allergènes non renseignés');
      expect(violatesExclusion(glutenFree, item), isFalse);
      expect(exclusionsVerified(glutenFree, item), isFalse);
    });

    test('aucun allergène saisi : vérifié', () {
      const staple = MealStaple(
        id: 'riz',
        name: 'Riz',
        category: StapleCategory.feculent,
        quantityPerPortion: 70,
        allergens: [],
      );
      final item = CriteriaItem.ofStaple(staple);
      expect(exclusionWarning(glutenFree, item), isNull);
      expect(exclusionsVerified(glutenFree, item), isTrue);
    });

    test('le féculent d\'une garniture se lit dans son nom', () {
      MealStaple s(String name, StapleCategory c) =>
          MealStaple(id: name, name: name, category: c, quantityPerPortion: 1);
      expect(
        stapleMainStarch(s('Pâtes fraîches', StapleCategory.feculent)),
        'pates',
      );
      expect(
        stapleMainStarch(s('Riz basmati', StapleCategory.feculent)),
        'riz',
      );
      expect(
        stapleMainStarch(s('Pommes de terre vapeur', StapleCategory.feculent)),
        'pommes_de_terre',
      );
      expect(stapleMainStarch(s('Purée', StapleCategory.feculent)), isNull);
      expect(stapleMainStarch(s('Baguette', StapleCategory.pain)), 'pain');
      expect(
        stapleMainStarch(s('Haricots verts', StapleCategory.legume)),
        'aucun',
      );
      const noPasta = PlanningCriteria(excludedStarches: ['pates']);
      expect(
        exclusionWarning(
          noPasta,
          CriteriaItem.ofStaple(s('Pâtes fraîches', StapleCategory.feculent)),
        ),
        'contient : pâtes',
      );
    });
  });

  group('cache des traductions', () {
    test('lecture tolérante, par texte', () {
      final translations = readConstraintTranslations({
        'entries': {
          'h1': {
            'text': '  Pas de porc, 30 min max ',
            'criteria': {
              'excluded_proteins': ['porc'],
              'max_duration': 30,
            },
            'untranslated': '',
          },
          'h2': {'text': 'pas trop gras', 'untranslated': 'pas trop gras'},
          'h3': 'abîmée',
          'h4': {'criteria': {}},
        },
      });
      expect(translations.keys, ['Pas de porc, 30 min max', 'pas trop gras']);
      final t = translations['Pas de porc, 30 min max']!;
      expect(t.criteria.labels, ['sans porc', '30 min max']);
      expect(translations['pas trop gras']!.criteria.labels, isEmpty);
    });

    test('critères d\'un créneau : texte général et note du jour', () {
      final translations = {
        'général': const ConstraintTranslation(
          text: 'général',
          criteria: PlanningCriteria(excludedAllergens: ['lait']),
          untranslated: '',
        ),
        'mardi': const ConstraintTranslation(
          text: 'mardi',
          criteria: PlanningCriteria(maxDuration: 20),
          untranslated: '',
        ),
      };
      final c = criteriaForTexts(translations, ['général', ' mardi ', 'x']);
      expect(c.excludedAllergens, ['lait']);
      expect(c.maxDuration, 20);
    });

    test('une traduction en échec garde tout le texte non vérifié', () {
      final t = ConstraintTranslation.fromMap({
        'text': 'sans gluten',
        'status': 'failed',
      })!;
      expect(t.translated, isFalse);
      expect(t.untranslated, 'sans gluten');
      expect(t.criteria.labels, isEmpty);
    });
  });

  group('écarts stockés sur le repas', () {
    test('lecture tolérante', () {
      final list = UnmetCriterion.listFrom([
        {
          'key': 'max_duration',
          'regime': 'preference',
          'status': 'relaxed',
          'service': 'plat',
          'detail':
              '1 h 10, au-delà des 45 min demandées : peu d\'autres choix',
        },
        {'key': 'x', 'regime': 'autre', 'detail': 'ignoré'},
        {'key': 'light', 'regime': 'preference', 'detail': ''},
        'abîmé',
      ]);
      expect(list, hasLength(1));
      expect(list.single.toMap()['regime'], 'preference');
      expect(UnmetCriterion.fromMap(list.single.toMap()), list.single);
    });
  });
}
