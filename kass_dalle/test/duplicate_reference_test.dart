import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kass_dalle/features/processing/data/processing_job_repository.dart';
import 'package:kass_dalle/features/processing/domain/processing_job.dart';
import 'package:kass_dalle/features/processing/presentation/processing_providers.dart';
import 'package:kass_dalle/features/recipes/data/recipe_repository.dart';
import 'package:kass_dalle/features/recipes/domain/duplicate_reference.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/presentation/drafts/duplicate_widgets.dart';
import 'package:kass_dalle/features/recipes/presentation/drafts/work_queue_widgets.dart';
import 'package:kass_dalle/features/recipes/presentation/recipe_providers.dart';

/// La référence « import plus ancien » d'un doublon possible n'est jamais
/// réécrite par le serveur : le client la résout à l'affichage.

Recipe _recette(
  String id, {
  String? titre,
  int? page,
  RecipeDuplicateRef? duplicateOf,
}) => Recipe(
  id: id,
  titre: titre ?? 'Recette $id',
  langue: 'fr',
  rawCooklang: 'Posez le filet.',
  imageUrls: const [],
  reviewStatus: ReviewStatus.draft,
  tags: const RecipeTags(),
  ingredientsIndex: const [],
  createdBy: 'uid',
  createdAt: DateTime(2026, 9, 1),
  updatedAt: DateTime(2026, 9, 1),
  pageNumber: page,
  duplicateOf: duplicateOf,
);

ProcessingJob _job(
  String id,
  ProcessingJobStatus status, {
  List<String> created = const [],
  List<JobDuplicate> duplicates = const [],
}) {
  final now = DateTime(2026, 10, 1);
  return ProcessingJob(
    id: id,
    type: ProcessingJobType.recipeScan,
    status: status,
    createdBy: 'uid',
    createdAt: now,
    updatedAt: now,
    fileName: 'page.jpg',
    fileUrl: '',
    createdRecipeIds: created,
    duplicates: duplicates,
  );
}

class _FakeRecipes implements RecipeRepository {
  _FakeRecipes(this.recipes, this.denied);
  final Map<String, Recipe?> recipes;
  final Set<String> denied;

  @override
  Future<Recipe?> getById(String id) async {
    if (denied.contains(id)) throw _denied;
    return recipes[id];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeJobs implements ProcessingJobRepository {
  _FakeJobs(this.jobs, this.denied);
  final Map<String, ProcessingJob?> jobs;
  final Set<String> denied;

  @override
  Future<ProcessingJob?> getJob(String id) async {
    if (denied.contains(id)) throw _denied;
    return jobs[id];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Les dépôts remplacés, et la file de l'utilisateur ([mine]) fixée.
List<Override> _overrides({
  Map<String, Recipe?> recipes = const {},
  Map<String, ProcessingJob?> jobs = const {},
  Set<String> denied = const {},
  List<ProcessingJob> mine = const [],
}) => [
  recipeRepositoryProvider.overrideWithValue(_FakeRecipes(recipes, denied)),
  processingJobRepositoryProvider.overrideWithValue(_FakeJobs(jobs, denied)),
  processingJobsProvider.overrideWith((ref) => Stream.value(mine)),
];

final _denied = FirebaseException(
  plugin: 'cloud_firestore',
  code: 'permission-denied',
);

void main() {
  group('duplicateJobOutcome', () {
    test('en file ou en cours : en attente', () {
      for (final status in [
        ProcessingJobStatus.queued,
        ProcessingJobStatus.processing,
      ]) {
        final outcome = duplicateJobOutcome(_job('j', status));
        expect(outcome.pending, isTrue);
        expect(outcome.candidates, isEmpty);
      }
    });

    test('terminé : ses recettes sont les candidates', () {
      final outcome = duplicateJobOutcome(
        _job('j', ProcessingJobStatus.done, created: ['a', 'b']),
      );
      expect(outcome.pending, isFalse);
      expect(outcome.candidates, ['a', 'b']);
    });

    test('erreur, rejet, doublon ou absent : plus rien', () {
      for (final job in [
        _job('j', ProcessingJobStatus.error, created: ['a']),
        _job('j', ProcessingJobStatus.rejected),
        _job('j', ProcessingJobStatus.duplicate, created: ['a']),
        null,
      ]) {
        final outcome = duplicateJobOutcome(job);
        expect(outcome.pending, isFalse);
        expect(outcome.candidates, isEmpty);
      }
    });
  });

  group('pickDuplicateReferenceRecipe', () {
    test('le titre égal l\'emporte, casse et espaces ignorés', () {
      final picked = pickDuplicateReferenceRecipe([
        _recette('a', titre: 'Sauce'),
        _recette('b', titre: 'Tarte aux pommes'),
      ], '  tarte AUX pommes ');
      expect(picked?.id, 'b');
    });

    test('sans titre égal : la première ; sans recette : null', () {
      expect(
        pickDuplicateReferenceRecipe([
          _recette('a', titre: 'Sauce'),
          _recette('b', titre: 'Pâte'),
        ], 'Tarte')?.id,
        'a',
      );
      expect(pickDuplicateReferenceRecipe(const [], 'Tarte'), isNull);
    });

    test('libellé : titre et page de la recette trouvée', () {
      expect(
        duplicateFoundLabel(_recette('a', titre: 'Tarte', page: 42)),
        'Déjà dans le livre : Tarte, p. 42',
      );
      expect(
        duplicateFoundLabel(_recette('a', titre: 'Tarte')),
        'Déjà dans le livre : Tarte',
      );
    });
  });

  group('duplicateReferenceProvider', () {
    ProviderContainer container({
      Map<String, Recipe?> recipes = const {},
      Map<String, ProcessingJob?> jobs = const {},
      Set<String> denied = const {},
    }) {
      final c = ProviderContainer(
        overrides: _overrides(recipes: recipes, jobs: jobs, denied: denied),
      );
      addTearDown(c.dispose);
      return c;
    }

    Future<DuplicateReference> read(
      ProviderContainer c, {
      String? recipeId,
      String? jobId,
      String titre = 'Tarte',
    }) {
      final provider = duplicateReferenceProvider((
        recipeId: recipeId,
        jobId: jobId,
        existingTitre: titre,
      ));
      // Garde le provider en vie le temps de la lecture.
      final sub = c.listen(provider, (_, _) {});
      addTearDown(sub.close);
      return c.read(provider.future);
    }

    test('recette lue, absente ou refusée', () async {
      final c = container(recipes: {'r1': _recette('r1')}, denied: {'r-p'});
      expect(await read(c, recipeId: 'r1'), isA<DuplicateReferenceFound>());
      expect(await read(c, recipeId: 'r0'), isA<DuplicateReferenceGone>());
      final refused = await read(c, recipeId: 'r-p');
      expect(refused, isA<DuplicateReferenceUnreadable>());
      expect((refused as DuplicateReferenceUnreadable).denied, isTrue);
    });

    test('import de l\'utilisateur : lu dans sa file, sans lecture', () async {
      final c = ProviderContainer(
        overrides: _overrides(
          mine: [
            _job('j1', ProcessingJobStatus.done, created: ['b']),
          ],
          recipes: {'b': _recette('b', titre: 'Tarte')},
        ),
      );
      addTearDown(c.dispose);
      final jobs = c.listen(processingJobsProvider, (_, _) {});
      addTearDown(jobs.close);
      await c.read(processingJobsProvider.future);
      final ref = await read(c, jobId: 'j1');
      expect((ref as DuplicateReferenceFound).recipe.id, 'b');
    });

    test('import en cours : en attente', () async {
      final c = container(
        jobs: {'j1': _job('j1', ProcessingJobStatus.processing)},
      );
      expect(await read(c, jobId: 'j1'), isA<DuplicateReferencePending>());
    });

    test(
      'import terminé : la recette au même titre, sinon la première',
      () async {
        final c = container(
          jobs: {
            'j1': _job('j1', ProcessingJobStatus.done, created: ['a', 'b']),
            'j2': _job('j2', ProcessingJobStatus.done, created: ['x', 'a']),
          },
          recipes: {
            'a': _recette('a', titre: 'Sauce'),
            'b': _recette('b', titre: 'Tarte', page: 12),
          },
        );
        final first = await read(c, jobId: 'j1');
        expect((first as DuplicateReferenceFound).recipe.id, 'b');
        // 'x' n'existe plus : la seule recette lue sert de référence.
        final second = await read(c, jobId: 'j2');
        expect((second as DuplicateReferenceFound).recipe.id, 'a');
      },
    );

    test(
      'import en erreur, rejeté, en doublon, absent ou illisible : supprimée',
      () async {
        final c = container(
          jobs: {
            'e': _job('e', ProcessingJobStatus.error),
            'r': _job('r', ProcessingJobStatus.rejected),
            'd': _job('d', ProcessingJobStatus.duplicate, created: ['a']),
            'vide': _job('vide', ProcessingJobStatus.done, created: ['zz']),
          },
          recipes: {'a': _recette('a')},
          denied: {'prive'},
        );
        for (final id in ['e', 'r', 'd', 'absent', 'prive', 'vide']) {
          expect(
            await read(c, jobId: id),
            isA<DuplicateReferenceGone>(),
            reason: id,
          );
        }
      },
    );

    test(
      'import terminé dont la recette est refusée : non consultable',
      () async {
        final c = container(
          jobs: {
            'j1': _job('j1', ProcessingJobStatus.done, created: ['p']),
          },
          denied: {'p'},
        );
        final ref = await read(c, jobId: 'j1');
        expect((ref as DuplicateReferenceUnreadable).denied, isTrue);
      },
    );
  });

  group('DuplicateReferenceLink', () {
    Future<GoRouter> pump(
      WidgetTester tester,
      Widget child, {
      Map<String, Recipe?> recipes = const {},
      Map<String, ProcessingJob?> jobs = const {},
      Set<String> denied = const {},
    }) async {
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => Scaffold(body: child),
          ),
          GoRoute(
            path: '/drafts/:id',
            builder: (_, state) =>
                Scaffold(body: Text('relecture ${state.pathParameters['id']}')),
          ),
        ],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: _overrides(recipes: recipes, jobs: jobs, denied: denied),
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      await tester.pumpAndSettle();
      return router;
    }

    Widget link({String? recipeId, String? jobId}) => DuplicateReferenceLink(
      recipeId: recipeId,
      jobId: jobId,
      existingTitre: 'Tarte',
      linkLabel: duplicateFoundLabel,
      plainLabel: 'Déjà dans le livre : Tarte',
      pendingLabel: 'Import plus ancien en cours : Tarte',
    );

    testWidgets('import terminé : lien vers la recette créée, cible de 48 px', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pump(
        tester,
        link(jobId: 'j1'),
        jobs: {
          'j1': _job('j1', ProcessingJobStatus.done, created: ['b']),
        },
        recipes: {'b': _recette('b', titre: 'Tarte', page: 7)},
      );
      expect(find.text('Déjà dans le livre : Tarte, p. 7'), findsOneWidget);
      final button = find.byType(TextButton);
      expect(
        tester.getSize(button).height,
        greaterThanOrEqualTo(kMinInteractiveDimension),
      );
      expect(
        tester.getSemantics(
          find.bySemanticsLabel('Déjà dans le livre : Tarte, p. 7'),
        ),
        matchesSemantics(
          label: 'Déjà dans le livre : Tarte, p. 7',
          isLink: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('relecture b'), findsOneWidget);
      semantics.dispose();
    });

    testWidgets('import en cours : texte sans lien', (tester) async {
      await pump(
        tester,
        link(jobId: 'j1'),
        jobs: {'j1': _job('j1', ProcessingJobStatus.queued)},
      );
      expect(find.text('Import plus ancien en cours : Tarte'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets('import en erreur : « Recette supprimée », sans lien', (
      tester,
    ) async {
      await pump(
        tester,
        link(jobId: 'j1'),
        jobs: {'j1': _job('j1', ProcessingJobStatus.error)},
      );
      expect(find.text('Recette supprimée'), findsOneWidget);
      expect(find.byType(TextButton), findsNothing);
    });

    testWidgets('recette refusée : page d\'un autre membre, sans lien', (
      tester,
    ) async {
      await pump(tester, link(recipeId: 'r-p'), denied: {'r-p'});
      expect(
        find.text('Déjà dans le livre (page d\'un autre membre)'),
        findsOneWidget,
      );
      expect(find.byType(TextButton), findsNothing);
    });
  });

  group('DuplicateOfBanner', () {
    Future<void> pump(WidgetTester tester, {required bool expanded}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: _overrides(recipes: {'r1': _recette('r1')}),
          child: MaterialApp(
            home: Scaffold(
              body: DuplicateOfBanner(
                recipe: _recette(
                  'd1',
                  duplicateOf: const RecipeDuplicateRef(
                    titre: 'Tarte',
                    page: 42,
                    recipeId: 'r1',
                  ),
                ),
                initiallyExpanded: expanded,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('replié sur téléphone : une ligne, le détail au chevron', (
      tester,
    ) async {
      await pump(tester, expanded: false);
      expect(
        find.text('Doublon possible de « Tarte » (p. 42)'),
        findsOneWidget,
      );
      expect(find.text('Ouvrir la recette existante'), findsNothing);
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pumpAndSettle();
      expect(find.text('Ouvrir la recette existante'), findsOneWidget);
      expect(
        find.text('Valider la publiera quand même et retirera cette marque.'),
        findsOneWidget,
      );
    });

    testWidgets('déplié sur grand écran', (tester) async {
      await pump(tester, expanded: true);
      expect(find.text('Ouvrir la recette existante'), findsOneWidget);
    });
  });

  group('File : doublons possibles', () {
    testWidgets('« Valider » sans nombre quand un brouillon marqué est coché', (
      tester,
    ) async {
      Widget bar({required bool showCount}) => MaterialApp(
        home: Scaffold(
          bottomNavigationBar: WorkQueueSelectionBar(
            validateCount: 1,
            showValidateCount: showCount,
            retryCount: null,
            deleteCount: 2,
            onValidate: () {},
            onRetry: () {},
            onDelete: () {},
          ),
        ),
      );
      await tester.pumpWidget(bar(showCount: false));
      expect(find.text('Valider'), findsOneWidget);
      await tester.pumpWidget(bar(showCount: true));
      expect(find.text('Valider (1)'), findsOneWidget);
    });

    testWidgets(
      'menu d\'un brouillon marqué : « Relire » au lieu de « Valider »',
      (tester) async {
        var validated = false;
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => Scaffold(
                body: QueueDraftTile(
                  recipe: _recette(
                    'd1',
                    duplicateOf: const RecipeDuplicateRef(
                      titre: 'Tarte',
                      recipeId: 'r1',
                    ),
                  ),
                  isSelected: false,
                  isSelecting: false,
                  onTap: () {},
                  onLongPress: () {},
                  onValidate: () => validated = true,
                  onDelete: () {},
                ),
              ),
            ),
            GoRoute(
              path: '/drafts/:id',
              builder: (_, state) => Scaffold(
                body: Text('relecture ${state.pathParameters['id']}'),
              ),
            ),
          ],
        );
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.tap(find.byTooltip('Actions'));
        await tester.pumpAndSettle();
        expect(find.text('Valider'), findsNothing);
        await tester.tap(find.text('Relire'));
        await tester.pumpAndSettle();
        expect(validated, isFalse);
        expect(find.text('relecture d1'), findsOneWidget);
      },
    );

    testWidgets('job en doublon sans liste : texte de repli', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: QueueJobTile(
                job: _job('j1', ProcessingJobStatus.duplicate),
                isSelected: false,
                isSelecting: false,
                onTap: () {},
                onLongPress: () {},
                onRetry: null,
                onDelete: () {},
                onNotDuplicate: () {},
                notDuplicateBusy: true,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('Une recette de cette page semble déjà dans le livre.'),
        findsOneWidget,
      );
      // Reprise en cours d'écriture : le bouton reste, désactivé.
      final button = tester.widget<TextButton>(
        find.ancestor(
          of: find.text('Ce n\'est pas un doublon'),
          matching: find.byWidgetPredicate((w) => w is TextButton),
        ),
      );
      expect(button.onPressed, isNull);
    });
  });
}
