import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/processing/domain/processing_job.dart';
import 'package:kass_dalle/features/recipes/data/book_import_analysis.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/presentation/drafts/work_queue_batch.dart';

/// Les doublons à l'import, côté client : lecture de ce que le serveur écrit
/// (`processing_jobs.duplicates`, `recipes.duplicate_of`, `existingBook`) et
/// validation en lot qui écarte les brouillons marqués.

/// Substitut de `Timestamp` pour `Recipe.fromFirestore`, qui n'attend qu'un
/// objet exposant `toDate()`.
class _FakeTimestamp {
  final DateTime value;
  const _FakeTimestamp(this.value);
  DateTime toDate() => value;
}

Recipe _brouillon({
  String id = 'r1',
  String raw = 'Posez le filet.',
  String? fidelity,
  RecipeDuplicateRef? duplicateOf,
}) => Recipe(
  id: id,
  titre: 'Gravlax $id',
  langue: 'fr',
  rawCooklang: raw,
  imageUrls: const [],
  reviewStatus: ReviewStatus.draft,
  tags: const RecipeTags(),
  ingredientsIndex: const [],
  createdBy: 'uid',
  createdAt: DateTime(2026, 9, 1),
  updatedAt: DateTime(2026, 9, 1),
  fidelityLevel: fidelity,
  duplicateOf: duplicateOf,
);

ProcessingJob _job(String id, ProcessingJobStatus status) {
  final now = DateTime(2026, 10, 1);
  return ProcessingJob(
    id: id,
    type: ProcessingJobType.bookDocumentScan,
    status: status,
    createdBy: 'uid',
    createdAt: now,
    updatedAt: now,
    fileName: 'livre.pdf',
    fileUrl: '',
  );
}

void main() {
  final creation = DateTime(2026, 10, 17, 9, 0);

  Map<String, dynamic> jobDocument(Map<String, dynamic> extra) => {
    'type': 'recipeScan',
    'status': 'duplicate',
    'created_by': 'uid-1',
    'created_at': Timestamp.fromDate(creation),
    'updated_at': Timestamp.fromDate(creation),
    'file_name': 'page.jpg',
    'file_url': 'https://storage/page.jpg',
    ...extra,
  };

  group('ProcessingJob — doublon possible', () {
    test('lit le statut duplicate et la liste des doublons', () {
      final job = ProcessingJob.fromFirestore(
        'j1',
        jobDocument({
          'created_recipe_ids': ['r9'],
          'duplicates': [
            {
              'titre': 'Tarte aux pommes',
              'existing_titre': 'Tarte aux pommes',
              'existing_page': 42,
              'recipe_id': 'r1',
            },
            {
              'titre': 'Crumble',
              'existing_titre': 'Crumble',
              'existing_page': null,
              'job_id': 'j0',
            },
          ],
        }),
      );
      expect(job.status, ProcessingJobStatus.duplicate);
      expect(job.isDuplicate, isTrue);
      expect(job.isActive, isFalse);
      expect(job.createdRecipeIds, ['r9']);
      expect(job.duplicates, hasLength(2));
      expect(job.duplicates.first.recipeId, 'r1');
      expect(job.duplicates.first.existingPage, 42);
      expect(job.duplicates.last.jobId, 'j0');
      expect(job.duplicates.last.recipeId, isNull);
      expect(job.duplicateOverride, isFalse);
    });

    test('lecture tolérante : entrées illisibles écartées, champ absent', () {
      final job = ProcessingJob.fromFirestore(
        'j1',
        jobDocument({
          'duplicates': [
            'pas une carte',
            {'titre': 'Flan', 'existing_page': 12.0},
          ],
          'duplicate_override': true,
        }),
      );
      expect(job.duplicates, hasLength(1));
      expect(job.duplicates.single.existingTitre, '');
      expect(job.duplicates.single.existingPage, 12);
      expect(job.duplicateOverride, isTrue);

      final sansChamp = ProcessingJob.fromFirestore(
        'j2',
        jobDocument({'status': 'processing'}),
      );
      expect(sansChamp.duplicates, isEmpty);
      expect(
        ProcessingJob.fromFirestore(
          'j3',
          jobDocument({'duplicates': 'nimporte'}),
        ).duplicates,
        isEmpty,
      );
    });

    test(
      'libellé de la référence : page connue, inconnue, import en cours',
      () {
        expect(
          const JobDuplicate(
            titre: 'Flan',
            existingTitre: 'Flan pâtissier',
            existingPage: 42,
            recipeId: 'r1',
          ).referenceLabel,
          'Déjà dans le livre : Flan pâtissier, p. 42',
        );
        expect(
          const JobDuplicate(
            titre: 'Flan',
            existingTitre: 'Flan pâtissier',
            recipeId: 'r1',
          ).referenceLabel,
          'Déjà dans le livre : Flan pâtissier',
        );
        expect(
          const JobDuplicate(
            titre: 'Flan',
            existingTitre: 'Flan pâtissier',
            jobId: 'j0',
          ).referenceLabel,
          'Import plus ancien en cours : Flan pâtissier',
        );
      },
    );

    test('copyWith garde les doublons', () {
      final job = ProcessingJob.fromFirestore(
        'j1',
        jobDocument({
          'duplicates': [
            {'titre': 'Flan', 'existing_titre': 'Flan', 'recipe_id': 'r1'},
          ],
        }),
      );
      expect(job.copyWith().duplicates, hasLength(1));
    });
  });

  group('Recipe.duplicateOf', () {
    Map<String, dynamic> recipeDocument(Object? mark) => {
      'titre': 'Flan',
      'raw_cooklang': 'Cuire.',
      'created_by': 'uid',
      'created_at': _FakeTimestamp(creation),
      'updated_at': _FakeTimestamp(creation),
      'duplicate_of': mark,
    };

    test('lu depuis le document, jamais réécrit par toFirestore', () {
      final recipe = Recipe.fromFirestore(
        'r2',
        recipeDocument({
          'titre': 'Flan pâtissier',
          'page': 42,
          'recipe_id': 'r1',
        }),
      );
      expect(recipe.duplicateOf?.recipeId, 'r1');
      expect(recipe.duplicateOf?.page, 42);
      expect(
        recipe.duplicateOf?.bannerLabel,
        'Doublon possible de « Flan pâtissier » (p. 42)',
      );
      expect(recipe.toFirestore().containsKey('duplicate_of'), isFalse);
      expect(recipe.copyWith(titre: 'Autre').duplicateOf, isNotNull);
    });

    test('absent ou illisible : pas de marque', () {
      expect(
        Recipe.fromFirestore('r2', recipeDocument(null)).duplicateOf,
        isNull,
      );
      expect(
        Recipe.fromFirestore('r2', recipeDocument('x')).duplicateOf,
        isNull,
      );
    });

    test('bandeau sans page quand elle est inconnue', () {
      expect(
        const RecipeDuplicateRef(titre: 'Flan', jobId: 'j0').bannerLabel,
        'Doublon possible de « Flan »',
      );
    });
  });

  group('planDraftValidation — doublons possibles', () {
    const mark = RecipeDuplicateRef(titre: 'Flan', page: 3, recipeId: 'ref');

    test('un brouillon marqué est écarté et compté à part', () {
      final plan = planDraftValidation([
        _brouillon(id: 'a'),
        _brouillon(id: 'b', duplicateOf: mark),
        _brouillon(id: 'c', fidelity: 'avertissement', duplicateOf: mark),
      ]);
      expect(plan.toValidate.map((r) => r.id), ['a']);
      expect(plan.duplicates.map((r) => r.id), ['b', 'c']);
      expect(plan.withFidelityReserve, isEmpty);
      expect(plan.skipped, 2);
      // Même en lot, réserve comprise, un doublon n'est jamais validé.
      expect(plan.validatableInBatch, 1);
    });

    test('une marque devenue caduque est validée normalement', () {
      final plan = planDraftValidation(
        [
          _brouillon(id: 'b', duplicateOf: mark),
          _brouillon(id: 'c', fidelity: 'avertissement', duplicateOf: mark),
        ],
        staleDuplicates: {'b', 'c'},
      );
      expect(plan.toValidate.map((r) => r.id), ['b']);
      expect(plan.withFidelityReserve.map((r) => r.id), ['c']);
      expect(plan.duplicates, isEmpty);
    });

    test('un brouillon vide et marqué compte comme vide, une fois', () {
      final plan = planDraftValidation([
        _brouillon(id: 'v', raw: ' ', duplicateOf: mark),
      ]);
      expect(plan.emptyContent, hasLength(1));
      expect(plan.duplicates, isEmpty);
    });

    test('le compte rendu nomme les doublons possibles', () {
      final plan = planDraftValidation([
        _brouillon(id: 'a'),
        _brouillon(id: 'b', duplicateOf: mark),
        _brouillon(id: 'c', duplicateOf: mark),
      ]);
      expect(
        validationSummary(plan, failed: 0),
        '1 brouillon validé. Non validés : 2 doublons possibles.',
      );
      final seul = planDraftValidation([
        _brouillon(id: 'b', duplicateOf: mark),
      ]);
      expect(
        validationSummary(seul, failed: 0),
        'Aucun brouillon validé. Non validés : 1 doublon possible.',
      );
    });

    test('compteur de la file', () {
      expect(pendingDuplicatesLabel(0), isNull);
      expect(pendingDuplicatesLabel(1), '1 doublon possible à trancher');
      expect(pendingDuplicatesLabel(3), '3 doublons possibles à trancher');
    });
  });

  group('staleDuplicateMarks', () {
    Future<Set<String>> run(
      List<Recipe> drafts, {
      Map<String, bool> recipes = const {},
      Map<String, ProcessingJob?> jobs = const {},
      Set<String> unreadable = const {},
      List<String>? errors,
    }) {
      return staleDuplicateMarks(
        drafts,
        readRecipe: (id) async {
          if (unreadable.contains(id)) throw StateError('permission-denied');
          return (recipes[id] ?? false) ? _brouillon(id: id) : null;
        },
        readJob: (id) async {
          if (unreadable.contains(id)) throw StateError('permission-denied');
          return jobs[id];
        },
        onReadError: (error, stackTrace, draft) => errors?.add(draft.id),
      );
    }

    test('référence recette supprimée : la marque tombe', () async {
      final stale = await run(
        [
          _brouillon(
            id: 'gone',
            duplicateOf: const RecipeDuplicateRef(titre: 'X', recipeId: 'r0'),
          ),
          _brouillon(
            id: 'kept',
            duplicateOf: const RecipeDuplicateRef(titre: 'Y', recipeId: 'r1'),
          ),
          _brouillon(id: 'plain'),
        ],
        recipes: {'r1': true},
      );
      expect(stale, {'gone'});
    });

    test(
      'référence import absent, en erreur ou rejeté : la marque tombe',
      () async {
        RecipeDuplicateRef byJob(String id) =>
            RecipeDuplicateRef(titre: 'X', jobId: id);
        final stale = await run(
          [
            _brouillon(id: 'absent', duplicateOf: byJob('j-absent')),
            _brouillon(id: 'erreur', duplicateOf: byJob('j-error')),
            _brouillon(id: 'rejete', duplicateOf: byJob('j-rejected')),
            _brouillon(id: 'encours', duplicateOf: byJob('j-processing')),
            _brouillon(id: 'termine', duplicateOf: byJob('j-done')),
          ],
          jobs: {
            'j-error': _job('j-error', ProcessingJobStatus.error),
            'j-rejected': _job('j-rejected', ProcessingJobStatus.rejected),
            'j-processing': _job(
              'j-processing',
              ProcessingJobStatus.processing,
            ),
            'j-done': _job('j-done', ProcessingJobStatus.done),
          },
        );
        expect(stale, {'absent', 'erreur', 'rejete'});
      },
    );

    test('lecture refusée : la marque reste, l\'erreur est signalée', () async {
      final errors = <String>[];
      final stale = await run(
        [
          _brouillon(
            id: 'prive',
            duplicateOf: const RecipeDuplicateRef(titre: 'X', recipeId: 'r-p'),
          ),
        ],
        unreadable: {'r-p'},
        errors: errors,
      );
      expect(stale, isEmpty);
      expect(errors, ['prive']);
    });
  });

  group('BookImportAnalysis.existingBook', () {
    Map<String, dynamic> response(Object? existing) => {
      'kind': 'epub',
      'sizeBytes': 1024,
      'windows': 12,
      'characters': 70000,
      'existingBook': existing,
    };

    test('absent ou nul : aucun livre rapproché', () {
      expect(BookImportAnalysis.fromMap(response(null)).existingBook, isNull);
      final sansCle = Map<String, dynamic>.from(response(null))
        ..remove('existingBook');
      expect(BookImportAnalysis.fromMap(sansCle).existingBook, isNull);
      expect(
        BookImportAnalysis.fromMap(response({'titre': 'Sans id'})).existingBook,
        isNull,
      );
    });

    test('même titre : l\'avertissement nomme le livre et son auteur', () {
      final book = BookImportAnalysis.fromMap(
        response(<Object?, Object?>{
          'id': 'b1',
          'titre': 'Le Riz Jaune',
          'auteur': 'Thaï Liou',
          'sameFile': false,
          'sameTitle': true,
          'importedAt': null,
        }),
      ).existingBook!;
      expect(book.id, 'b1');
      expect(book.sameTitle, isTrue);
      expect(book.sameFile, isFalse);
      expect(
        book.warningLabel,
        'Ce livre semble déjà dans votre bibliothèque : Le Riz Jaune, '
        'Thaï Liou.',
      );
      expect(book.sameFileLabel, isNull);
    });

    test('même fichier : la date du premier import est donnée', () {
      final book = BookImportAnalysis.fromMap(
        response({
          'id': 'b1',
          'titre': 'Le Riz Jaune',
          'auteur': null,
          'sameFile': true,
          'sameTitle': false,
          'importedAt': '2026-03-12T10:00:00',
        }),
      ).existingBook!;
      expect(
        book.warningLabel,
        'Ce livre semble déjà dans votre bibliothèque : Le Riz Jaune.',
      );
      expect(
        book.sameFileLabel,
        'Ce fichier a déjà été importé le 12/03/2026.',
      );
    });

    test('même fichier sans date lisible', () {
      final book = ExistingBookMatch.fromMap({
        'id': 'b1',
        'titre': 'Le Riz Jaune',
        'sameFile': true,
        'importedAt': 'pas une date',
      })!;
      expect(book.importedAt, isNull);
      expect(book.sameFileLabel, 'Ce fichier a déjà été importé.');
    });
  });
}
