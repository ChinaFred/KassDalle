import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/data/ai_budget_repository.dart';
import 'package:kass_dalle/features/admin/presentation/ai_services_tab.dart'
    show ServicesGrouping;
import 'package:kass_dalle/features/admin/presentation/ai_spend_screen.dart';

/// Le détail d'un compte dans « Dépense par utilisateur ».
///
/// Ce que ces tests gardent : un groupe affiche la somme de ce qu'il montre.
/// Un total qui ne correspond pas à ses lignes ne lève aucune erreur et
/// s'affiche comme un montant juste.
void main() {
  UserSpend compte(String label, Map<String, (double, int)> postes) {
    final byFeature = [
      for (final entry in postes.entries)
        FeatureSpend(
          feature: entry.key,
          costUsd: entry.value.$1,
          calls: entry.value.$2,
        ),
    ];
    return UserSpend(
      uid: label,
      label: label,
      costUsd: byFeature.fold(0, (s, f) => s + f.costUsd),
      calls: byFeature.fold(0, (s, f) => s + f.calls),
      byFeature: byFeature,
    );
  }

  // Deux processus : « Numérisation d'un livre » et « Valeurs nutritionnelles ».
  final frederic = compte('Frédéric', {
    'transcription_page': (3.0, 31),
    'recipe_tagging': (6.0, 33),
    'book_cover': (1.0, 4),
    'estimate_piece_weights': (0.5, 200),
    'detect_not_consumed': (0.25, 100),
  });

  List<SpendDetailRow> detail({
    String filtre = '',
    ServicesGrouping groupement = ServicesGrouping.process,
    SpendSort tri = SpendSort.cout,
    bool croissant = false,
    bool tousGardes = true,
  }) => spendDetail(
    frederic,
    filtre: filtre,
    groupement: groupement,
    tri: tri,
    croissant: croissant,
    tousGardes: tousGardes,
  );

  List<String> labels(List<SpendDetailRow> lignes) =>
      lignes.map((l) => l.label).toList();

  group('groupement par processus', () {
    test('un groupe porte la somme de ses postes', () {
      final lignes = detail();
      final numerisation = lignes.firstWhere(
        (l) => l.label == 'Numérisation d\'un livre',
      );
      expect(numerisation.costUsd, closeTo(10.0, 1e-9));
      expect(numerisation.calls, 68);
      expect(numerisation.enfants.length, 3);
    });

    test(
      'les groupes sont triés comme les postes, du plus cher au moins cher',
      () {
        expect(labels(detail()), [
          'Numérisation d\'un livre',
          'Valeurs nutritionnelles',
        ]);
      },
    );

    test('le tri par appels ne classe pas comme le tri par coût', () {
      // 300 appels pour 0,75 $ contre 68 appels pour 10 $ : les deux clés
      // rendent l'ordre inverse l'une de l'autre.
      expect(labels(detail(tri: SpendSort.appels)), [
        'Valeurs nutritionnelles',
        'Numérisation d\'un livre',
      ]);
    });

    test('le sens croissant renverse l\'ordre', () {
      expect(labels(detail(croissant: true)), [
        'Valeurs nutritionnelles',
        'Numérisation d\'un livre',
      ]);
    });

    test('les postes d\'un groupe sont triés eux aussi', () {
      final numerisation = detail().first;
      expect(labels(numerisation.enfants), [
        'Balisage et normalisation',
        'Transcription d\'une page',
        'Couverture de livre',
      ]);
    });

    test('sans groupement, chaque poste est une ligne sans enfant', () {
      final lignes = detail(groupement: ServicesGrouping.feature);
      expect(lignes.length, 5);
      expect(lignes.every((l) => l.enfants.isEmpty), isTrue);
      expect(lignes.first.label, 'Balisage et normalisation');
    });
  });

  group('filtre', () {
    test('un filtre sur le nom du processus garde tous ses postes', () {
      final lignes = detail(filtre: 'numérisation', tousGardes: false);
      expect(labels(lignes), ['Numérisation d\'un livre']);
      expect(lignes.single.enfants.length, 3);
      // Gardé pour son propre nom : le détail n'a pas à s'ouvrir tout seul.
      expect(lignes.single.ouvertParDefaut, isFalse);
    });

    test(
      'un filtre sur un poste ne garde que ce poste, et déplie le groupe',
      () {
        final lignes = detail(filtre: 'couverture', tousGardes: false);
        expect(labels(lignes), ['Numérisation d\'un livre']);
        expect(labels(lignes.single.enfants), ['Couverture de livre']);
        expect(lignes.single.ouvertParDefaut, isTrue);
      },
    );

    test('le total du groupe suit ce qui reste affiché', () {
      // 1 $ pour la seule couverture, et non les 10 $ du processus entier :
      // un groupe dont les lignes ne font pas la somme fait mentir le tableau.
      final numerisation = detail(
        filtre: 'couverture',
        tousGardes: false,
      ).single;
      expect(numerisation.costUsd, closeTo(1.0, 1e-9));
      expect(numerisation.calls, 4);
    });

    test('un groupe sans poste correspondant disparaît', () {
      final lignes = detail(filtre: 'couverture', tousGardes: false);
      expect(lignes.length, 1);
    });

    test('un filtre qui ne correspond à rien ne rend aucune ligne', () {
      expect(detail(filtre: 'zzz', tousGardes: false), isEmpty);
      expect(
        detail(
          filtre: 'zzz',
          groupement: ServicesGrouping.feature,
          tousGardes: false,
        ),
        isEmpty,
      );
    });

    test('le nom du compte trouvé montre tout le détail', () {
      // `tousGardes` : c'est le compte qui a répondu au filtre, pas ses postes.
      final lignes = detail(filtre: 'frédéric');
      expect(lignes.length, 2);
      expect(lignes.every((l) => l.ouvertParDefaut), isFalse);
    });
  });

  test('un poste hors catalogue tombe dans « Autres » sans disparaître', () {
    final inconnu = compte('X', {'poste_qui_n_existe_pas': (2.0, 7)});
    final lignes = spendDetail(
      inconnu,
      filtre: '',
      groupement: ServicesGrouping.process,
      tri: SpendSort.cout,
      croissant: false,
      tousGardes: true,
    );
    expect(labels(lignes), ['Autres']);
    expect(lignes.single.costUsd, closeTo(2.0, 1e-9));
    expect(labels(lignes.single.enfants), ['poste_qui_n_existe_pas']);
  });
}
