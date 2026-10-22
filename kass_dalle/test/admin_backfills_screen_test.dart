import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/domain/backfill_status.dart';
import 'package:kass_dalle/features/admin/presentation/admin_backfills_screen.dart';
import 'package:kass_dalle/features/admin/presentation/billing_providers.dart';

Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  required Map<String, BackfillRunState> runs,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        backfillRunsProvider.overrideWith((ref) => Stream.value(runs)),
        backfillSchedulesProvider.overrideWith(
          (ref) => Stream.value(
            const BackfillSchedules({
              'nutrition': {
                'enabled': true,
                'days': [1, 2, 3, 4, 5, 6, 7],
                'hour': 5,
              },
            }),
          ),
        ),
      ],
      child: const MaterialApp(home: AdminBackfillsScreen()),
    ),
  );
  await tester.pump();
}

void main() {
  final runs = {
    'refresh_sodium': BackfillRunState.fromMap('refresh_sodium', {
      'termine_le': DateTime.utc(2026, 10, 10, 10),
      'termine_version': '0.23.30',
      'termine_par': 'auto',
      'dernier_passage_statut': 'termine',
      'dernier_passage_le': DateTime.utc(2026, 10, 10, 10),
    }),
  };

  testWidgets('téléphone : trois sections, nutrition programmée par défaut', (
    tester,
  ) async {
    await _pump(tester, size: const Size(400, 4800), runs: runs);
    expect(find.text('Récurrents (5)'), findsOneWidget);
    expect(find.text('Ponctuels à lancer (0)'), findsOneWidget);
    expect(find.text('Ponctuels terminés (1)'), findsOneWidget);
    expect(
      find.text('Programmation : Tous les jours à 5 h'),
      findsOneWidget,
      reason: 'le défaut semé par le serveur est lu tel quel',
    );
    expect(find.text('Relancer quand même'), findsOneWidget);
    expect(
      find.textContaining('Dernier passage — terminé'),
      findsOneWidget,
      reason: 'tuile terminée : la seconde ligne dit de quoi elle parle',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('état d\'un backfill retiré du code : ignoré, sans erreur', (
    tester,
  ) async {
    // Les ponctuels retirés en v0.23.52, v0.24.33, v0.24.37, v0.24.44 et v0.24.51 laissent leur
    // `app_config/backfill_run_<clé>` en base, terminé ou même en cours.
    await _pump(
      tester,
      size: const Size(400, 4800),
      runs: {
        ...runs,
        'estimated_times': BackfillRunState.fromMap('estimated_times', {
          'termine_le': DateTime.utc(2026, 10, 10, 10),
          'termine_par': 'auto',
          'dernier_passage_statut': 'termine',
        }),
        'recipe_protein': BackfillRunState.fromMap('recipe_protein', {
          'dernier_passage_statut': 'en_cours',
          'en_cours_expire_le': DateTime.now().add(const Duration(hours: 1)),
          'last_report': {'traitees': 3, 'restantes': 0},
        }),
        'planning_defaults': BackfillRunState.fromMap('planning_defaults', {
          'dernier_passage_statut': 'erreur',
          'dernier_passage_erreur': 'ancienne erreur',
        }),
        'system_books': BackfillRunState.fromMap('system_books', {
          'termine_le': DateTime.utc(2026, 10, 13, 10),
          'termine_par': 'auto',
          'dernier_passage_statut': 'termine',
        }),
        'illustration_folders_move':
            BackfillRunState.fromMap('illustration_folders_move', {
              'termine_le': DateTime.utc(2026, 10, 21, 10),
              'termine_par': 'auto',
              'dernier_passage_statut': 'termine',
            }),
        'move_meals_to_group': BackfillRunState.fromMap('move_meals_to_group', {
          'dernier_passage_statut': 'termine',
          'last_report': {'deplaces': 7, 'echoues': 0},
        }),
        'default_units': BackfillRunState.fromMap('default_units', {
          'termine_le': DateTime.utc(2026, 10, 21, 10),
          'termine_par': 'auto',
          'dernier_passage_statut': 'termine',
        }),
        'users_schema_check': BackfillRunState.fromMap('users_schema_check', {
          'termine_le': DateTime.utc(2026, 10, 22, 10),
          'termine_par': 'auto',
          'dernier_passage_statut': 'termine',
        }),
      },
    );
    expect(find.text('Récurrents (5)'), findsOneWidget);
    expect(find.text('Ponctuels à lancer (0)'), findsOneWidget);
    expect(find.text('Ponctuels terminés (1)'), findsOneWidget);
    expect(find.text('Durées estimées'), findsNothing);
    expect(find.text('Protéine et féculent des plats'), findsNothing);
    expect(find.text('Contraintes de variété par défaut'), findsNothing);
    expect(find.text('Livres système des comptes'), findsNothing);
    expect(find.text('Ranger les illustrations'), findsNothing);
    expect(find.text('Déplacer mes repas vers un groupe'), findsNothing);
    expect(find.text('Semer les unités standard'), findsNothing);
    expect(find.text('Contrôler les comptes'), findsNothing);
    expect(find.textContaining('ancienne erreur'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('« Copier la liste » copie une ligne par ponctuel terminé', (
    tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
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
    await _pump(tester, size: const Size(400, 4800), runs: runs);
    await tester.tap(find.widgetWithText(TextButton, 'Copier la liste'));
    await tester.pump();
    expect(
      copied,
      'refresh_sodium — Reprendre le sel des ingrédients — terminé le '
      '10/10/2026 en v0.23.30 — automatique — dernier compte rendu : absent '
      '— à revoir : 0',
    );
    expect(find.text('Liste des ponctuels terminés copiée.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large : deux colonnes sans débordement', (tester) async {
    await _pump(tester, size: const Size(1200, 2400), runs: runs);
    expect(find.text('Programmer'), findsNWidgets(5));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'avant le premier passage horaire : défaut de la nutrition affiché',
    (tester) async {
      tester.view.physicalSize = const Size(400, 3000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            backfillRunsProvider.overrideWith(
              (ref) => Stream.value(const <String, BackfillRunState>{}),
            ),
            backfillSchedulesProvider.overrideWith(
              (ref) => Stream.value(BackfillSchedules.empty),
            ),
          ],
          child: const MaterialApp(home: AdminBackfillsScreen()),
        ),
      );
      await tester.pump();
      expect(
        find.text('Programmation : Tous les jours à 5 h (par défaut)'),
        findsOneWidget,
      );
      expect(find.text('Programmation : Non programmé'), findsNWidgets(4));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('chargement : tuiles neutres, ponctuels non rangés', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          backfillRunsProvider.overrideWith(
            (ref) => const Stream<Map<String, BackfillRunState>>.empty(),
          ),
          backfillSchedulesProvider.overrideWith(
            (ref) => const Stream<BackfillSchedules>.empty(),
          ),
        ],
        child: const MaterialApp(home: AdminBackfillsScreen()),
      ),
    );
    await tester.pump();
    expect(find.text('Ponctuels'), findsOneWidget);
    expect(find.textContaining('Ponctuels à lancer'), findsNothing);
    expect(find.text('État inconnu'), findsNothing);
    expect(find.text('Programmation : …'), findsNWidgets(5));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'confirmation : « Réessayer aussi les éléments exclus après 3 échecs » pour les '
    'backfills qui excluent après trois échecs, décochée par défaut',
    (tester) async {
      await _pump(tester, size: const Size(400, 3000), runs: runs);

      // Ordre du registre : nutrition, puis « Enrichir unités et ingrédients ».
      final launches = find.widgetWithText(FilledButton, 'Lancer');
      await tester.tap(launches.at(1));
      await tester.pumpAndSettle();
      final box = find.widgetWithText(
        CheckboxListTile,
        'Réessayer aussi les éléments exclus après 3 échecs',
      );
      expect(box, findsOneWidget);
      expect(tester.widget<CheckboxListTile>(box).value, isFalse);
      await tester.tap(box);
      await tester.pump();
      expect(tester.widget<CheckboxListTile>(box).value, isTrue);
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();

      // La nutrition n'a pas de mémoire des échecs : pas de case.
      await tester.tap(launches.at(0));
      await tester.pumpAndSettle();
      expect(
        find.text('Réessayer aussi les éléments exclus après 3 échecs'),
        findsNothing,
      );
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
