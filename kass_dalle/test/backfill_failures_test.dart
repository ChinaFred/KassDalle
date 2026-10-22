import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/domain/backfill_failures.dart';
import 'package:kass_dalle/features/admin/domain/recipe_roles_backfill_report.dart';
import 'package:kass_dalle/features/admin/presentation/admin_backfills_screen.dart';
import 'package:kass_dalle/features/admin/presentation/backfill_failures_sheet.dart';

BackfillFailure _f(String kind, String id, String label, String reason) =>
    BackfillFailure(kind: kind, id: id, label: label, reason: reason);

BackfillFailures _many(int shown, int total) => BackfillFailures(
  items: [
    for (var i = 0; i < shown; i++)
      _f('recipe', 'r$i', 'Recette $i', 'Pas de réponse de l\'IA'),
  ],
  total: total,
);

void main() {
  group('BackfillFailures.fromMap', () {
    test('absent ou mal formé : null', () {
      expect(BackfillFailures.fromMap(null), isNull);
      expect(BackfillFailures.fromMap('x'), isNull);
    });

    test('lit les entrées, saute celles sans identifiant', () {
      final f = BackfillFailures.fromMap({
        'items': [
          {
            'kind': 'ingredient',
            'id': 'farine',
            'label': 'farine',
            'reason': 'Pas de réponse de l\'IA',
          },
          {'kind': 'recipe', 'label': 'sans id'},
          'pas une entrée',
          {'kind': 'recipe', 'id': 'r1'},
        ],
        'total': 240,
      })!;
      expect(f.items, hasLength(2));
      expect(f.items.first.label, 'farine');
      expect(f.items.last.label, 'r1', reason: 'nom absent : l\'identifiant');
      expect(f.total, 240);
      expect(f.truncated, isTrue);
    });

    test('total absent ou plus petit que la liste : la liste fait foi', () {
      final f = BackfillFailures.fromMap({
        'items': [
          {'kind': 'recipe', 'id': 'r1', 'label': 'A', 'reason': 'x'},
        ],
      })!;
      expect(f.total, 1);
      expect(f.truncated, isFalse);
    });

    test('BackfillCounts lit compteurs, drapeaux et aRevoir', () {
      final c = BackfillCounts.fromMap({
        'examinees': 12,
        'completed': true,
        'aRevoir': {'items': <Object>[], 'total': 3},
      });
      expect(c['examinees'], 12);
      expect(c['completed'], 1);
      expect(c.failures!.total, 3);
    });

    test('le compte rendu des durées estimées porte aRevoir', () {
      final c = BackfillCounts.fromMap({
        'dejaEnCours': false,
        'estimees': 5,
        'sansEstimation': 1,
        'enErreur': 1,
        'completed': false,
        'aRevoir': {
          'items': [
            {
              'kind': 'recipe',
              'id': 'r1',
              'label': 'Tarte',
              'reason': 'L\'IA n\'a estimé aucune durée',
            },
            {
              'kind': 'recipe',
              'id': 'r2',
              'label': 'Gratin',
              'reason': 'Lot en échec : délai dépassé',
            },
          ],
          'total': 2,
        },
      });
      expect(c['estimees'], 5);
      expect(c['dejaEnCours'], 0);
      expect(c.failures!.items.map((i) => i.id), ['r1', 'r2']);
      expect(c.failures!.items.first.reason, 'L\'IA n\'a estimé aucune durée');
    });

    test('le compte rendu du rôle des recettes porte aRevoir', () {
      final r = RecipeRolesBackfillReport.fromMap({
        'aRevoir': {
          'items': [
            {
              'kind': 'recipe',
              'id': 'r1',
              'label': 'Tarte',
              'reason': 'L\'IA n\'a pas su classer la recette',
            },
          ],
          'total': 1,
        },
      });
      expect(r.failures!.items.single.label, 'Tarte');
      expect(RecipeRolesBackfillReport.fromMap({}).failures, isNull);
    });
  });

  group('libellé du lien', () {
    test('un, plusieurs, tronqué, aucun', () {
      expect(
        backfillFailuresLinkLabel(_many(1, 1)),
        'Voir l\'élément à revoir',
      );
      expect(backfillFailuresLinkLabel(_many(56, 56)), 'Voir les 56 à revoir');
      expect(
        backfillFailuresLinkLabel(_many(100, 240)),
        'Voir les 100 premiers sur 240 à revoir',
      );
      expect(backfillFailuresLinkLabel(_many(0, 0)), isNull);
      expect(backfillFailuresLinkLabel(null), isNull);
      expect(backfillFailuresLinkLabel(_many(0, 17)), isNull);
    });
  });

  group('bannière', () {
    Future<void> pump(
      WidgetTester tester, {
      BackfillFailures? failures,
      VoidCallback? onShow,
    }) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BackfillOperationBanner(
              isError: false,
              message: 'Ingrédients : en erreur=17',
              failures: failures,
              onShowFailures: onShow ?? () {},
              onClose: () {},
            ),
          ),
        ),
      );
    }

    testWidgets('éléments à revoir : avertissement et lien', (tester) async {
      var shown = 0;
      await pump(tester, failures: _many(56, 56), onShow: () => shown++);
      expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsNothing);
      await tester.tap(find.text('Voir les 56 à revoir'));
      expect(shown, 1);
    });

    testWidgets('rien à revoir : coche, pas de lien', (tester) async {
      await pump(tester, failures: _many(0, 0));
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets('total sans détail : pas de lien, et le message le dit', (
      tester,
    ) async {
      await pump(tester, failures: _many(0, 17));
      expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
      expect(
        find.textContaining('Détail indisponible pour cette opération.'),
        findsOneWidget,
      );
    });
  });

  group('feuille « À revoir »', () {
    final mixed = BackfillFailures(
      items: [
        _f('recipe', 'r2', 'Quiche', 'Recette incomplète : farine non examiné'),
        _f('ingredient', 'sel', 'sel', 'Pas de réponse de l\'IA'),
        _f(
          'recipe',
          'r1',
          'Clafoutis',
          'Recette incomplète : farine non examiné',
        ),
        _f('ingredient', 'farine', 'farine', 'Lot en échec : délai dépassé'),
        _f('ingredient', 'beurre', 'beurre', 'Lot en échec : délai dépassé'),
      ],
      total: 5,
    );

    Future<void> pumpSheet(WidgetTester tester, BackfillFailures failures) {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: BackfillFailuresSheet(
              title: 'Allergènes',
              failures: failures,
            ),
          ),
        ),
      );
    }

    testWidgets(
      'titre, sous-titre, groupes par nature, tri par raison puis nom',
      (tester) async {
        await pumpSheet(tester, mixed);
        expect(find.text('À revoir — Allergènes'), findsOneWidget);
        expect(
          find.text('5 éléments. Touchez une ligne pour l\'ouvrir.'),
          findsOneWidget,
        );
        expect(find.text('Ingrédients (3)'), findsOneWidget);
        expect(find.text('Recettes (2)'), findsOneWidget);

        final titles = tester
            .widgetList<ListTile>(find.byType(ListTile))
            .map((t) => (t.title as Text).data)
            .toList();
        expect(titles, ['beurre', 'farine', 'sel', 'Clafoutis', 'Quiche']);
        expect(find.byIcon(Icons.chevron_right), findsNWidgets(5));
        expect(find.textContaining('affichés sur'), findsNothing);
      },
    );

    testWidgets('une seule nature : pas d\'en-tête ; un élément', (
      tester,
    ) async {
      await pumpSheet(tester, _many(1, 1));
      expect(find.textContaining('Recettes ('), findsNothing);
      expect(
        find.text('1 élément. Touchez-le pour l\'ouvrir.'),
        findsOneWidget,
      );
    });

    testWidgets('tronquée : le pied dit combien sont affichés', (tester) async {
      await pumpSheet(tester, _many(3, 240));
      expect(find.text('3 affichés sur 240.'), findsOneWidget);
      expect(
        find.text('240 éléments. Touchez une ligne pour l\'ouvrir.'),
        findsOneWidget,
      );
    });

    testWidgets('nature inconnue : ni chevron, ni lien', (tester) async {
      await pumpSheet(
        tester,
        BackfillFailures(
          items: [_f('autre', 'x1', 'Élément', 'Contraintes trop longues')],
          total: 1,
        ),
      );
      expect(find.byIcon(Icons.chevron_right), findsNothing);
      expect(tester.widget<ListTile>(find.byType(ListTile)).onTap, isNull);
      expect(find.text('1 élément.'), findsOneWidget);
    });

    testWidgets('copier : une ligne « nom — raison » par élément', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await pumpSheet(tester, mixed);
      await tester.tap(find.byTooltip('Copier la liste'));
      await tester.pump();
      expect(
        copied,
        'beurre — Lot en échec : délai dépassé\n'
        'farine — Lot en échec : délai dépassé\n'
        'sel — Pas de réponse de l\'IA\n'
        'Clafoutis — Recette incomplète : farine non examiné\n'
        'Quiche — Recette incomplète : farine non examiné',
      );
      expect(find.text('Liste copiée.'), findsOneWidget);
    });
  });
}
