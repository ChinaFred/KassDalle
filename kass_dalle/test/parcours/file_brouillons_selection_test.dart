import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/core/widgets/provider_retry.dart';
import 'package:kass_dalle/features/processing/data/processing_job_repository.dart';
import 'package:kass_dalle/features/processing/domain/processing_job.dart';
import 'package:kass_dalle/features/processing/presentation/processing_providers.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/presentation/drafts/work_queue_screen.dart';
import 'package:kass_dalle/features/recipes/presentation/drafts/work_queue_widgets.dart';

import '../support/test_backend.dart';

/// Valider et supprimer des brouillons en lot, depuis la file
/// « Brouillons & Traitements ».
///
/// Les dépôts sont les vrais, posés sur un Firestore en mémoire : ce qui est
/// vérifié est ce qui est écrit, pas l'appel d'une fausse méthode.
Recipe _brouillon(String id, String titre, {String? fidelity, int jour = 1}) =>
    Recipe(
      id: id,
      titre: titre,
      langue: 'fr',
      rawCooklang: '>> portions: 4\nMélanger la @farine{200%g}.',
      imageUrls: const [],
      reviewStatus: ReviewStatus.draft,
      tags: const RecipeTags(),
      ingredientsIndex: const ['farine'],
      createdBy: 'uid-test',
      createdAt: DateTime.utc(2026, 9, jour),
      updatedAt: DateTime.utc(2026, 9, jour),
      fidelityLevel: fidelity,
    );

ProcessingJob _traitementEnErreur() => ProcessingJob(
  id: 'j1',
  type: ProcessingJobType.recipeScan,
  status: ProcessingJobStatus.error,
  createdBy: 'uid-test',
  createdAt: DateTime.utc(2026, 9, 1),
  updatedAt: DateTime.utc(2026, 9, 1),
  fileName: 'scan.jpg',
  fileUrl: '',
  errorMessage: 'Lecture impossible',
);

Future<void> _ouvrir(
  WidgetTester tester,
  TestBackend backend, {
  List<ProcessingJob> traitements = const [],
}) async {
  await tester.binding.setSurfaceSize(const Size(1400, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  // Le décor de test fixe déjà `processingJobsProvider` à une liste vide, et
  // Riverpod refuse deux overrides du même fournisseur dans un conteneur : la
  // file de traitements se pose dans une portée imbriquée.
  await tester.pumpWidget(
    ProviderScope(
      retry: appProviderRetry,
      overrides: backend.overrides,
      child: ProviderScope(
        overrides: [
          processingJobsProvider.overrideWith(
            (ref) => Stream.value(traitements),
          ),
          processingJobRepositoryProvider.overrideWithValue(
            ProcessingJobRepository(firestore: backend.firestore),
          ),
        ],
        child: const MaterialApp(locale: Locale('fr'), home: WorkQueueScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<String?> _statut(TestBackend backend, String id) async {
  final doc = await backend.firestore.collection('recipes').doc(id).get();
  return doc.data()?['review_status'] as String?;
}

Future<void> _confirmer(WidgetTester tester, String libelle) async {
  await tester.tap(
    find.descendant(of: find.byType(AlertDialog), matching: find.text(libelle)),
  );
  await tester.pumpAndSettle();
}

void main() {
  _sectionHeaderTests();

  group('Parcours 7 — sélection multiple des brouillons', () {
    testWidgets('« Sélectionner » montre les cases, sans appui long', (
      tester,
    ) async {
      final backend = TestBackend();
      await backend.seedRecipe(_brouillon('d1', 'Gravlax', jour: 1));
      await backend.seedRecipe(_brouillon('d2', 'Blanquette', jour: 2));
      await _ouvrir(tester, backend);

      expect(find.byType(Checkbox), findsNothing);

      await tester.tap(find.byTooltip('Sélectionner'));
      await tester.pump();

      expect(find.byType(Checkbox), findsNWidgets(2));
      expect(find.text('Sélectionnez des éléments'), findsOneWidget);
      // Rien n'est coché : aucune action n'est proposée.
      expect(find.textContaining('Valider ('), findsNothing);
    });

    testWidgets('décocher le dernier élément ferme la sélection', (
      tester,
    ) async {
      final backend = TestBackend();
      await backend.seedRecipe(_brouillon('d1', 'Gravlax'));
      await _ouvrir(tester, backend);

      await tester.longPress(find.text('Gravlax'));
      await tester.pump();
      expect(find.byType(Checkbox), findsOneWidget);
      expect(find.text('1 sélectionné(s)'), findsOneWidget);

      await tester.tap(find.text('Gravlax'));
      await tester.pump();
      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets('valider les brouillons cochés, et eux seuls', (tester) async {
      final backend = TestBackend();
      await backend.seedRecipe(_brouillon('d1', 'Gravlax', jour: 1));
      await backend.seedRecipe(_brouillon('d2', 'Blanquette', jour: 2));
      await backend.seedRecipe(_brouillon('d3', 'Clafoutis', jour: 3));
      await _ouvrir(tester, backend);

      await tester.tap(find.byTooltip('Sélectionner'));
      await tester.pump();
      await tester.tap(find.text('Gravlax'));
      await tester.tap(find.text('Blanquette'));
      await tester.pump();

      expect(find.text('2 sélectionné(s)'), findsOneWidget);
      expect(find.text('Valider (2)'), findsOneWidget);
      expect(find.text('Supprimer (2)'), findsOneWidget);

      await tester.tap(find.text('Valider (2)'));
      await tester.pumpAndSettle();
      expect(find.text('Valider 2 brouillons ?'), findsOneWidget);
      await _confirmer(tester, 'Valider');

      expect(await _statut(backend, 'd1'), 'validated');
      expect(await _statut(backend, 'd2'), 'validated');
      expect(await _statut(backend, 'd3'), 'draft');
      expect(find.text('2 brouillons validés.'), findsOneWidget);
      // Le lot est fini : la sélection est fermée et le brouillon restant reste.
      expect(find.byType(Checkbox), findsNothing);
      expect(find.text('Clafoutis'), findsOneWidget);
    });

    testWidgets('un brouillon à réserve de fidélité n\'est pas validé en lot', (
      tester,
    ) async {
      final backend = TestBackend();
      await backend.seedRecipe(_brouillon('ok', 'Gravlax', jour: 1));
      await backend.seedRecipe(
        _brouillon('reserve', 'Blanquette', fidelity: 'rupture', jour: 2),
      );
      await _ouvrir(tester, backend);

      await tester.tap(find.byTooltip('Sélectionner'));
      await tester.pump();
      await tester.tap(find.byTooltip('Tout sélectionner'));
      await tester.pump();

      // Deux cochés, un seul admis : le bouton annonce ce qui sera validé.
      expect(find.text('2 sélectionné(s)'), findsOneWidget);
      expect(find.text('Valider (1)'), findsOneWidget);

      await tester.tap(find.text('Valider (1)'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('1 avec réserve de fidélité, à relire un par un'),
        findsOneWidget,
      );
      await _confirmer(tester, 'Valider');

      expect(await _statut(backend, 'ok'), 'validated');
      expect(await _statut(backend, 'reserve'), 'draft');
      // La réserve n'est pas levée : personne ne l'a relue.
      final reserve = await backend.firestore
          .collection('recipes')
          .doc('reserve')
          .get();
      expect(reserve.data()?['fidelity_level'], 'rupture');
    });

    testWidgets('supprimer les brouillons cochés demande confirmation', (
      tester,
    ) async {
      final backend = TestBackend();
      await backend.seedRecipe(_brouillon('d1', 'Gravlax', jour: 1));
      await backend.seedRecipe(_brouillon('d2', 'Blanquette', jour: 2));
      await backend.seedRecipe(_brouillon('d3', 'Clafoutis', jour: 3));
      await _ouvrir(tester, backend);

      await tester.tap(find.byTooltip('Sélectionner'));
      await tester.pump();
      await tester.tap(find.text('Gravlax'));
      await tester.tap(find.text('Clafoutis'));
      await tester.pump();

      await tester.tap(find.text('Supprimer (2)'));
      await tester.pumpAndSettle();
      expect(find.text('Supprimer 2 brouillons ?'), findsOneWidget);

      // Annuler ne supprime rien.
      await _confirmer(tester, 'Annuler');
      expect(await _statut(backend, 'd1'), 'draft');
      expect(find.byType(Checkbox), findsNWidgets(3));

      await tester.tap(find.text('Supprimer (2)'));
      await tester.pumpAndSettle();
      await _confirmer(tester, 'Supprimer');

      final restants = await backend.firestore.collection('recipes').get();
      expect(restants.docs.map((d) => d.id), ['d2']);
      expect(find.text('Supprimés : 2 brouillons.'), findsOneWidget);
    });

    testWidgets('une sélection mêlée garde chaque action sur sa part', (
      tester,
    ) async {
      final backend = TestBackend();
      await backend.seedRecipe(_brouillon('d1', 'Gravlax'));
      await backend.firestore.collection('processing_jobs').doc('j1').set({
        'created_by': 'uid-test',
      });
      await _ouvrir(tester, backend, traitements: [_traitementEnErreur()]);

      await tester.tap(find.byTooltip('Sélectionner'));
      await tester.pump();
      await tester.tap(find.byTooltip('Tout sélectionner'));
      await tester.pump();

      expect(find.text('2 sélectionné(s)'), findsOneWidget);
      expect(find.text('Valider (1)'), findsOneWidget);
      expect(find.text('Relancer (1)'), findsOneWidget);
      expect(find.text('Supprimer (2)'), findsOneWidget);

      await tester.tap(find.text('Supprimer (2)'));
      await tester.pumpAndSettle();
      expect(
        find.text('Supprimer 1 brouillon et 1 traitement ?'),
        findsOneWidget,
      );
      await _confirmer(tester, 'Supprimer');

      final recettes = await backend.firestore.collection('recipes').get();
      final jobs = await backend.firestore.collection('processing_jobs').get();
      expect(recettes.docs, isEmpty);
      expect(jobs.docs, isEmpty);
    });
  });
}

/// La case de section, visible en vue Groupe familial et Tous les
/// utilisateurs : elle coche d'un geste les éléments d'une même personne.
void _sectionHeaderTests() {
  group('En-tête de section', () {
    Future<void> monter(
      WidgetTester tester, {
      bool? selection,
      VoidCallback? onToggleSelection,
    }) => tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: WorkQueueSectionHeader(
              ownerUid: '__me',
              count: 3,
              expanded: true,
              onToggle: () {},
              selection: selection,
              onToggleSelection: onToggleSelection,
            ),
          ),
        ),
      ),
    );

    testWidgets('sans sélection en cours, aucune case', (tester) async {
      await monter(tester);
      expect(find.byType(Checkbox), findsNothing);
    });

    testWidgets('pendant une sélection, la case reflète la section', (
      tester,
    ) async {
      var appuis = 0;
      await monter(tester, selection: null, onToggleSelection: () => appuis++);

      final case_ = tester.widget<Checkbox>(find.byType(Checkbox));
      expect(case_.tristate, isTrue);
      // Une partie seulement est cochée : l'état intermédiaire.
      expect(case_.value, isNull);

      await tester.tap(find.byType(Checkbox));
      expect(appuis, 1);
    });
  });
}
