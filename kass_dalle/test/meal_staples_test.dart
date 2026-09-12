import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/planning/domain/meal_staple.dart';

/// Les garnitures simples : la liste de base, et sa lecture à travers les
/// retouches d'un utilisateur.
///
/// Une fusion fausse ne lève rien : une quantité retouchée revient à la
/// valeur de base, ou une garniture masquée réapparaît dans un repas.
MealStaple _base(
  String id, {
  StapleCategory category = StapleCategory.feculent,
  double quantity = 100,
  bool active = true,
  int sortOrder = 0,
}) => MealStaple(
  id: id,
  name: id,
  category: category,
  quantityPerPortion: quantity,
  active: active,
  sortOrder: sortOrder,
);

void main() {
  group('liste de base', () {
    test('les identifiants sont uniques et en minuscules sans accent', () {
      final ids = kDefaultMealStaples.map((s) => s.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final id in ids) {
        expect(id, matches(RegExp(r'^[a-z0-9_]+$')), reason: id);
      }
    });

    test('chaque part est positive, dans une unité connue', () {
      for (final s in kDefaultMealStaples) {
        expect(s.quantityPerPortion, greaterThan(0), reason: s.id);
        expect(kStapleUnits, contains(s.unit), reason: s.id);
        expect(s.active, isTrue, reason: s.id);
      }
    });

    test('une part de pâtes pèse 125 g secs', () {
      final pates = kDefaultMealStaples.singleWhere((s) => s.id == 'pates');
      expect(pates.quantityPerPortion, 125);
      expect(pates.unit, 'g');
      expect(pates.note, 'poids sec');
      expect(pates.quantityLabel, '125 g');
    });

    test('un féculent sec dit qu\'il est pesé cru', () {
      for (final id in ['riz', 'pates', 'semoule', 'quinoa', 'lentilles']) {
        final s = kDefaultMealStaples.singleWhere((s) => s.id == id);
        expect(s.note, isNotEmpty, reason: id);
      }
    });

    test('la purée s\'achète en pommes de terre', () {
      final puree = kDefaultMealStaples.singleWhere((s) => s.id == 'puree');
      expect(puree.effectiveShoppingProduct, 'Pommes de terre');
      final riz = kDefaultMealStaples.singleWhere((s) => s.id == 'riz');
      expect(riz.effectiveShoppingProduct, 'Riz');
    });
  });

  group('quantité écrite', () {
    test('en grammes', () => expect(formatStapleQuantity(125, 'g'), '125 g'));
    test(
      'une pièce',
      () => expect(formatStapleQuantity(1, 'pièce'), '1 pièce'),
    );
    test(
      'plusieurs pièces',
      () => expect(formatStapleQuantity(2, 'pièce'), '2 pièces'),
    );
    test(
      'une décimale, virgule française',
      () => expect(formatStapleQuantity(0.5, 'g'), '0,5 g'),
    );
  });

  group('identifiant depuis un nom', () {
    test('minuscules, sans accent, tirets bas', () {
      expect(stapleIdFromName('Pâtes fraîches'), 'pates_fraiches');
    });
    test('les espaces autour tombent', () {
      expect(stapleIdFromName('  Riz  '), 'riz');
    });
    test('les ligatures s\'écrivent en deux lettres', () {
      expect(stapleIdFromName('Œufs'), 'oeufs');
    });
    test('rien sans lettre ni chiffre', () {
      expect(stapleIdFromName('!!!'), '');
    });
  });

  group('fusion base et retouches', () {
    test('sans retouche, la base telle quelle', () {
      final out = mergeStaples([_base('riz')], const {});
      expect(out.single.staple.quantityPerPortion, 100);
      expect(out.single.isOverridden, isFalse);
      expect(out.single.isOwn, isFalse);
      expect(out.single.hidden, isFalse);
      expect(out.single.base?.id, 'riz');
    });

    test('une quantité retouchée remplace celle de la base, le reste suit', () {
      final out = mergeStaples(
        [_base('riz')],
        {'riz': const StapleOverride(id: 'riz', quantityPerPortion: 80)},
      );
      expect(out.single.staple.quantityPerPortion, 80);
      expect(out.single.staple.name, 'riz');
      expect(out.single.isOverridden, isTrue);
      expect(out.single.base?.quantityPerPortion, 100);
    });

    test('masquer ne retouche pas', () {
      final out = mergeStaples(
        [_base('riz')],
        {'riz': const StapleOverride(id: 'riz', hidden: true)},
      );
      expect(out.single.hidden, isTrue);
      expect(out.single.isOverridden, isFalse);
    });

    test('une garniture propre à l\'utilisateur s\'ajoute, marquée', () {
      final out = mergeStaples(
        [_base('riz')],
        {
          'gnocchis': const StapleOverride(
            id: 'gnocchis',
            isOwn: true,
            name: 'Gnocchis',
            category: StapleCategory.feculent,
            quantityPerPortion: 150,
          ),
        },
      );
      expect(out.map((u) => u.staple.id), ['gnocchis', 'riz']);
      final own = out.first;
      expect(own.isOwn, isTrue);
      expect(own.base, isNull);
      expect(own.staple.source, 'user');
      expect(own.staple.unit, 'g');
    });

    test('une garniture de base désactivée disparaît, retouchée ou non', () {
      final out = mergeStaples(
        [_base('riz', active: false), _base('pates')],
        {'riz': const StapleOverride(id: 'riz', quantityPerPortion: 80)},
      );
      expect(out.map((u) => u.staple.id), ['pates']);
    });

    test('une retouche orpheline sans garniture propre est ignorée', () {
      final out = mergeStaples(
        [_base('riz')],
        {'disparue': const StapleOverride(id: 'disparue', hidden: true)},
      );
      expect(out.map((u) => u.staple.id), ['riz']);
    });

    test('une garniture propre sans nom ou sans quantité est ignorée', () {
      final out = mergeStaples(const [], {
        'sans_nom': const StapleOverride(
          id: 'sans_nom',
          isOwn: true,
          quantityPerPortion: 10,
        ),
        'sans_quantite': const StapleOverride(
          id: 'sans_quantite',
          isOwn: true,
          name: 'Sans quantité',
        ),
      });
      expect(out, isEmpty);
    });

    test('par famille, puis par rang, puis par nom', () {
      final out = mergeStaples([
        _base('yaourt', category: StapleCategory.laitage),
        _base('pates', sortOrder: 20),
        _base('riz', sortOrder: 10),
        _base('haricots', category: StapleCategory.legume),
      ], const {});
      expect(out.map((u) => u.staple.id), [
        'riz',
        'pates',
        'haricots',
        'yaourt',
      ]);
    });
  });

  group('retouche', () {
    test('vide quand elle ne dit plus rien', () {
      expect(const StapleOverride(id: 'riz').isEmpty, isTrue);
      expect(const StapleOverride(id: 'riz', hidden: true).isEmpty, isFalse);
      expect(const StapleOverride(id: 'riz', unit: 'g').isEmpty, isFalse);
      expect(const StapleOverride(id: 'x', isOwn: true).isEmpty, isFalse);
    });

    test('aller-retour Firestore', () {
      const o = StapleOverride(
        id: 'riz',
        hidden: true,
        quantityPerPortion: 80,
        note: 'poids cru',
      );
      final back = StapleOverride.fromMap('riz', o.toMap());
      expect(back.hidden, isTrue);
      expect(back.quantityPerPortion, 80);
      expect(back.note, 'poids cru');
      expect(back.name, isNull);
      expect(back.isOwn, isFalse);
    });

    test('le document de retouches se lit entrée par entrée', () {
      final parsed = parseStapleOverrides({
        'entries': {
          'riz': {'quantity_per_portion': 80},
          'abime': 'pas une carte',
          'gnocchis': {'own': true, 'name': 'Gnocchis'},
        },
      });
      expect(parsed.keys, containsAll(['riz', 'gnocchis']));
      expect(parsed.containsKey('abime'), isFalse);
      expect(parsed['gnocchis']!.isOwn, isTrue);
    });

    test('un document absent ne donne aucune retouche', () {
      expect(parseStapleOverrides(null), isEmpty);
      expect(parseStapleOverrides({'entries': 'x'}), isEmpty);
    });
  });
}
