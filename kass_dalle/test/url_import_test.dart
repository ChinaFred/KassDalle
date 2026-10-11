import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/books/domain/book.dart';
import 'package:kass_dalle/features/processing/domain/processing_job.dart';
import 'package:kass_dalle/features/processing/domain/processing_step_labels.dart';
import 'package:kass_dalle/features/processing/domain/processing_trail.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/domain/url_import.dart';
import 'package:kass_dalle/features/recipes/presentation/drafts/work_queue_widgets.dart';
import 'package:kass_dalle/features/recipes/presentation/url_import/recipe_source_link.dart';

/// Import d'une recette depuis un lien, côté client : réponses de la
/// callable, adresse de la page sur la recette, job et ses échecs, livre
/// système « Mes recettes du web ».
void main() {
  group('réponse de la callable', () {
    test('chaque statut est lu', () {
      expect(
        UrlImportResult.fromMap({
          'status': 'queued',
          'jobId': 'j1',
          'limit': 10,
          'remaining': 7,
        }).remaining,
        7,
      );
      expect(
        UrlImportResult.fromMap({'status': 'invalid_url'}).status,
        UrlImportStatus.invalidUrl,
      );
      final dup = UrlImportResult.fromMap({
        'status': 'duplicate',
        'recipeId': 'r1',
        'titre': 'Quiche',
      });
      expect(dup.status, UrlImportStatus.duplicate);
      expect(dup.titre, 'Quiche');
      expect(
        UrlImportResult.fromMap({
          'status': 'quota_exceeded',
          'limit': 10,
        }).limit,
        10,
      );
      // Un statut inconnu ne se lit pas comme un succès.
      expect(
        UrlImportResult.fromMap({'status': '???'}).status,
        UrlImportStatus.refused,
      );
    });

    test('compteur', () {
      final q = UrlImportQuota.fromMap({
        'limit': 10,
        'used': 3,
        'remaining': 7,
      });
      expect((q.limit, q.used, q.remaining), (10, 3, 7));
    });
  });

  group('adresse', () {
    test('lien web', () {
      expect(looksLikeWebLink('https://www.marmiton.org/x'), isTrue);
      expect(looksLikeWebLink('  http://a.fr  '), isTrue);
      expect(looksLikeWebLink('ftp://a.fr'), isFalse);
      expect(looksLikeWebLink('marmiton.org'), isFalse);
      expect(looksLikeWebLink(''), isFalse);
      expect(looksLikeWebLink('https://a.fr/${'x' * 2100}'), isFalse);
    });
  });

  group('recette importée', () {
    Recipe recipe({
      String? sourceUrl,
      String? sourceSite,
      RecipeOrigin? origin,
    }) => Recipe(
      id: 'r1',
      titre: 'Quiche',
      langue: 'fr',
      rawCooklang: '',
      imageUrls: const [],
      reviewStatus: ReviewStatus.draft,
      tags: const RecipeTags(),
      ingredientsIndex: const [],
      createdBy: 'u1',
      createdAt: DateTime(2026, 10, 1),
      updatedAt: DateTime(2026, 10, 1),
      origin: origin,
      sourceUrl: sourceUrl,
      sourceSite: sourceSite,
    );

    test('source_url et source_site relus, réécrits tels quels', () {
      final r = recipe(
        sourceUrl: 'https://www.site.fr/quiche',
        sourceSite: 'site.fr',
        origin: RecipeOrigin.web,
      );
      final written = r.toFirestore();
      expect(written['source_url'], 'https://www.site.fr/quiche');
      expect(written['source_site'], 'site.fr');
      expect(written['origin'], 'web');
      final read = Recipe.fromFirestore('r1', {
        ...written,
        'created_at': _Ts(DateTime(2026, 10, 1)),
        'updated_at': _Ts(DateTime(2026, 10, 1)),
      });
      expect(read.sourceSite, 'site.fr');
      final copy = r.copyWith(titre: 'Autre');
      expect((copy.sourceUrl, copy.sourceSite), (r.sourceUrl, r.sourceSite));
    });

    test('sans adresse, le champ n’est pas écrit', () {
      expect(recipe().toFirestore().containsKey('source_url'), isFalse);
      expect(recipe().toFirestore().containsKey('source_site'), isFalse);
      expect(recipe().sourceSite, isNull);
    });

    test('libellé de l’origine', () {
      expect(
        draftOriginLabel(RecipeOrigin.web),
        'Brouillon importé depuis une page web',
      );
      expect(recipeOriginFrom('web'), RecipeOrigin.web);
    });
  });

  test('« Mes recettes du web » est un livre système', () {
    final book = Book(
      id: 'web_u1',
      titre: 'Mes recettes du web',
      auteur: "Kass'Dalle",
      langue: 'fr',
      tags: const [Book.tagWeb],
      reviewStatus: BookReviewStatus.validated,
      createdBy: 'u1',
      createdAt: DateTime(2026, 10, 1),
      updatedAt: DateTime(2026, 10, 1),
      isPrivate: true,
    );
    expect(book.isWebBook, isTrue);
    expect(book.isSystemBook, isTrue);
  });

  group('job d’import par lien', () {
    ProcessingJob job({Object? errorCode, int? recettes, int? retries}) =>
        ProcessingJob.fromFirestore('j1', {
          'type': 'recipeUrlImport',
          'status': errorCode == null ? 'done' : 'error',
          'created_by': 'u1',
          'created_at': _Ts(DateTime(2026, 10, 1)),
          'updated_at': _Ts(DateTime(2026, 10, 1)),
          'file_name': 'site.fr',
          'source_url': 'https://www.site.fr/quiche',
          'error_code': ?errorCode,
          'recettes_trouvees': ?recettes,
          'url_retry_count': ?retries,
        });

    test('type, adresse, code d’échec, recettes trouvées', () {
      final j = job(errorCode: 'page_blocked', recettes: 2);
      expect(j.type, ProcessingJobType.recipeUrlImport);
      expect(j.sourceUrl, 'https://www.site.fr/quiche');
      expect(j.errorCode, UrlImportErrorCode.pageBlocked);
      expect(j.recettesTrouvees, 2);
      expect(job(errorCode: 'inconnu').errorCode, isNull);
    });

    test('actions proposées selon l’échec', () {
      final blocked = urlImportFailureFor(job(errorCode: 'page_blocked'))!;
      expect(blocked.message, startsWith('Ce site ne laisse pas'));
      expect(blocked.offerOpenPage && blocked.offerPasteText, isTrue);
      expect(blocked.retryable, isFalse);
      expect(
        urlImportFailureFor(job(errorCode: 'no_recipe'))!.message,
        'Aucune recette trouvée sur cette page.',
      );
      final timeout = urlImportFailureFor(job(errorCode: 'timeout'))!;
      expect(timeout.message, 'La page n\'a pas répondu à temps.');
      expect(timeout.retryable, isTrue);
      // Les règles n'admettent que deux relances.
      final exhausted = urlImportFailureFor(
        job(errorCode: 'timeout', retries: 2),
      )!;
      expect(exhausted.retryable, isFalse);
      expect(exhausted.offerPasteText, isTrue);
      expect(urlImportFailureFor(job())!.retryable, isTrue);
    });

    test('fil d’étapes et libellé de lecture', () {
      expect(
        trailFor(ProcessingJobType.recipeUrlImport).map((s) => s.code).toList(),
        ['fetch', 'gemini_call', 'tagging', 'normalize', 'save', 'design'],
      );
      expect(formatProcessingStep('fetch'), 'Lecture de la page web…');
    });

    testWidgets('tuile en échec : message et actions', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QueueJobTile(
              job: job(errorCode: 'page_blocked'),
              isSelected: false,
              isSelecting: false,
              onTap: () {},
              onLongPress: () {},
              onRetry: () {},
              onDelete: () {},
            ),
          ),
        ),
      );
      expect(find.textContaining('Ce site ne laisse pas'), findsOneWidget);
      expect(find.text('Ouvrir la page'), findsOneWidget);
      expect(find.text('Coller le texte'), findsOneWidget);
      // « Supprimer » vit dans le menu, pas dans le panneau.
      expect(find.text('Supprimer'), findsNothing);
      expect(find.byTooltip('Relancer'), findsNothing);
    });

    testWidgets('délai dépassé : « Relancer » dans le panneau seulement', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QueueJobTile(
              job: job(errorCode: 'timeout'),
              isSelected: false,
              isSelecting: false,
              onTap: () {},
              onLongPress: () {},
              onRetry: () {},
              onDelete: () {},
            ),
          ),
        ),
      );
      expect(find.text('Relancer'), findsOneWidget);
      expect(find.byTooltip('Relancer'), findsNothing);
    });

    testWidgets('en mode sélection, le panneau n\'a pas de boutons', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: QueueJobTile(
              job: job(errorCode: 'page_blocked'),
              isSelected: false,
              isSelecting: true,
              onTap: () {},
              onLongPress: () {},
              onRetry: () {},
              onDelete: () {},
            ),
          ),
        ),
      );
      expect(find.textContaining('Ce site ne laisse pas'), findsOneWidget);
      expect(find.text('Ouvrir la page'), findsNothing);
    });
  });

  group('lien vers la page d’origine', () {
    testWidgets('site en lien et adresse complète', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RecipeSourceLink(
              url: 'https://www.site.fr/quiche',
              site: 'site.fr',
            ),
          ),
        ),
      );
      expect(find.text('Source : '), findsOneWidget);
      expect(find.text('site.fr'), findsOneWidget);
      expect(find.byIcon(Icons.open_in_new), findsOneWidget);
      expect(find.byTooltip('Ouvrir la page d\'origine'), findsOneWidget);
      expect(find.byTooltip('Copier l\'adresse'), findsOneWidget);
      expect(find.text('https://www.site.fr/quiche'), findsOneWidget);
      expect(
        tester.getSize(find.byType(InkWell).first).height,
        greaterThanOrEqualTo(48),
      );
    });

    testWidgets('sans nom de site, le lien porte l\'hôte de l\'adresse', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: RecipeSourceLink(
              url: 'https://www.site.fr/quiche',
              prefix: 'Page à recopier : ',
            ),
          ),
        ),
      );
      expect(find.text('www.site.fr'), findsOneWidget);
    });

    testWidgets('rien pour une adresse qui n’est pas un lien web', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: RecipeSourceLink(url: 'javascript:alert(1)')),
        ),
      );
      expect(find.text('Source : '), findsNothing);
    });
  });
}

/// Horodatage minimal : `fromFirestore` n'en appelle que `toDate()`.
class _Ts {
  _Ts(this._d);
  final DateTime _d;
  DateTime toDate() => _d;
}
