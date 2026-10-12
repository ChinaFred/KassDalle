import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kass_dalle/core/services/gemini_providers.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/core/services/gemini_service.dart';
import 'package:kass_dalle/features/admin/presentation/admin_providers.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/domain/url_import.dart';
import 'package:kass_dalle/features/recipes/presentation/recipe_providers.dart';
import 'package:kass_dalle/features/search/domain/search_models.dart';
import 'package:kass_dalle/features/search/domain/web_search.dart';
import 'package:kass_dalle/features/search/presentation/google_search_suggestions.dart';
import 'package:kass_dalle/features/search/presentation/search_providers.dart';
import 'package:kass_dalle/features/search/presentation/search_screen.dart';
import 'package:kass_dalle/features/search/presentation/search_widgets.dart';
import 'package:kass_dalle/features/search/presentation/web_page_opener.dart';
import 'package:url_launcher/url_launcher.dart' show LaunchMode;

/// « Chercher sur le web » : bouton par rôle, états de la section « Sur le
/// web », carte d'une page, plafond du jour, et lecture de la réponse.

final _pages = [
  WebRecipeResult(
    url: Uri.parse('https://www.le-site.fr/blanquette'),
    title: 'Blanquette de veau',
    site: 'le-site.fr',
    snippet: 'La recette de grand-mère.',
  ),
  WebRecipeResult(
    url: Uri.parse('https://blog.example.fr/blanquette'),
    title: 'Ma blanquette',
    site: 'blog.example.fr',
  ),
];

class _RecordingErrorReportService extends ErrorReportService {
  final features = <String>[];

  @override
  Future<String> reportError({
    String? userId,
    String? jobId,
    required String feature,
    required Object error,
    StackTrace? stackTrace,
    Map<String, dynamic> context = const {},
  }) async {
    features.add(feature);
    return 'r';
  }
}

final _errors = _RecordingErrorReportService();

class _FakeService extends GeminiService {
  _FakeService(this.answer);

  /// Ce que rend la recherche : une réponse, ou une erreur levée.
  Future<WebSearchResponse> Function(String query) answer;
  final queries = <String>[];
  final imported = <String>[];

  @override
  Future<UrlImportQuota> getUrlImportQuota() async =>
      const UrlImportQuota(limit: 10, used: 0, remaining: 10);

  @override
  Future<UrlImportResult> importRecipeFromUrl(
    String url, {
    bool force = false,
  }) async {
    imported.add(url);
    return const UrlImportResult(status: UrlImportStatus.queued, jobId: 'j1');
  }

  @override
  Future<WebSearchResponse> searchWebRecipes(String query) {
    queries.add(query);
    return answer(query);
  }
}

Future<WebSearchResponse> _found(String query) async => WebSearchResponse(
  query: query,
  results: _pages,
  webSearchQueries: const ['blanquette de veau recette'],
  remaining: 49,
  limit: 50,
);

final _corpus = ExploreCorpus(
  myUid: 'moi',
  recipes: [
    Recipe(
      id: 'r1',
      titre: 'Gratin',
      langue: 'fr',
      rawCooklang: '',
      imageUrls: const [],
      reviewStatus: ReviewStatus.validated,
      tags: const RecipeTags(),
      ingredientsIndex: const [],
      createdBy: 'moi',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    ),
  ],
);

Future<_FakeService> _pump(
  WidgetTester tester, {
  bool canEdit = true,
  bool phone = false,
  Future<WebSearchResponse> Function(String)? answer,
}) async {
  // Assez haut pour que les deux cartes soient construites.
  tester.view.physicalSize = phone
      ? const Size(400, 1600)
      : const Size(1000, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final service = _FakeService(answer ?? _found);
  final router = GoRouter(
    routes: [GoRoute(path: '/', builder: (_, _) => const SearchScreen())],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appUserProvider.overrideWith((ref) => Stream.value(null)),
        canEditProvider.overrideWithValue(canEdit),
        exploreCorpusProvider.overrideWith((ref, params) async => _corpus),
        myRatingProvider.overrideWith((ref, id) => Stream.value(null)),
        geminiServiceProvider.overrideWithValue(service),
        errorReportServiceProvider.overrideWithValue(_errors),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return service;
}

Future<void> _search(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Chercher sur le web'));
  await tester.pumpAndSettle();
}

void main() {
  group('bouton « Chercher sur le web »', () {
    testWidgets(
      'lecteur sur téléphone : bouton plein en bas, rien sans texte',
      (tester) async {
        final service = await _pump(tester, canEdit: false, phone: true);
        expect(
          find.widgetWithText(FilledButton, 'Chercher sur le web'),
          findsOneWidget,
        );
        expect(find.text('Chercher sur Google'), findsNothing);
        await tester.tap(find.text('Chercher sur le web'));
        await tester.pumpAndSettle();
        expect(
          find.text('Écrivez ce que vous cherchez sur le web.'),
          findsOneWidget,
        );
        expect(service.queries, isEmpty);
      },
    );

    testWidgets('rien ne part à la frappe ni sur Entrée', (tester) async {
      final service = await _pump(tester);
      await tester.enterText(find.byType(TextField), 'blanquette');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(service.queries, isEmpty);
    });

    testWidgets('éditeur sur téléphone : dans « Aller plus loin »', (
      tester,
    ) async {
      await _pump(tester, phone: true);
      await tester.tap(find.text('Aller plus loin'));
      await tester.pumpAndSettle();
      expect(find.text('Chercher sur le web'), findsOneWidget);
      expect(find.text('Chercher sur Google'), findsNothing);
      // Avant la première recherche, le nombre restant est inconnu.
      expect(
        find.text('Jusqu\'à 8 pages de recettes, affichées ici.'),
        findsOneWidget,
      );
    });

    testWidgets('grand écran : à la place de « Chercher sur Google »', (
      tester,
    ) async {
      await _pump(tester);
      expect(
        find.widgetWithText(OutlinedButton, 'Chercher sur le web'),
        findsOneWidget,
      );
      expect(find.text('Chercher sur Google'), findsNothing);
    });
  });

  group('section « Sur le web »', () {
    testWidgets('éditeur : cartes, import, restant, pied', (tester) async {
      final service = await _pump(tester);
      await _search(tester, 'blanquette');
      expect(service.queries, ['blanquette']);
      expect(find.text('Sur le web'), findsOneWidget);
      expect(
        find.text('« blanquette » · Il vous reste 49 recherches aujourd\'hui.'),
        findsOneWidget,
      );
      expect(find.text('2 pages trouvées'), findsOneWidget);
      expect(find.text('Blanquette de veau'), findsOneWidget);
      // Un seul bouton d'import, page structurée ou non : aucun badge.
      expect(find.text('Import direct'), findsNothing);
      expect(find.text('Importer'), findsNWidgets(2));
      expect(find.text('Ouvrir'), findsNWidgets(2));
      expect(find.text('Vidéos et réseaux sociaux exclus.'), findsOneWidget);
      expect(find.text('Voir sur Google'), findsOneWidget);
      // Un seul libellé par carte.
      expect(
        find.bySemanticsLabel('Blanquette de veau, le-site.fr'),
        findsOneWidget,
      );
    });

    testWidgets('lecteur : pas d\'« Importer »', (tester) async {
      await _pump(tester, canEdit: false);
      await _search(tester, 'blanquette');
      expect(find.text('Blanquette de veau'), findsOneWidget);
      expect(find.text('Importer'), findsNothing);
      expect(find.text('Ouvrir'), findsNWidgets(2));
      expect(
        find.bySemanticsLabel('Blanquette de veau, le-site.fr'),
        findsOneWidget,
      );
    });

    testWidgets('« Importer » ouvre la boîte remplie, puis « Import envoyé »', (
      tester,
    ) async {
      final service = await _pump(tester);
      await _search(tester, 'blanquette');
      await tester.tap(find.text('Importer').first);
      await tester.pumpAndSettle();
      expect(find.text('https://www.le-site.fr/blanquette'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Importer').last);
      await tester.pumpAndSettle();
      expect(service.imported, ['https://www.le-site.fr/blanquette']);
      expect(find.text('Import envoyé'), findsOneWidget);
      expect(find.text('Importer'), findsOneWidget);
    });

    testWidgets('servie par le cache : non décomptée', (tester) async {
      await _pump(
        tester,
        answer: (q) async => WebSearchResponse(
          query: q,
          results: _pages,
          fromCache: true,
          remaining: 12,
        ),
      );
      await _search(tester, 'blanquette');
      expect(
        find.text('« blanquette » · Recherche déjà faite, non décomptée.'),
        findsOneWidget,
      );
    });

    testWidgets('aucune page : état vide avec « Voir sur Google »', (
      tester,
    ) async {
      await _pump(
        tester,
        answer: (q) async =>
            WebSearchResponse(query: q, results: const [], remaining: 40),
      );
      // « Gratin » trouve la recette de la bibliothèque : la seule grande
      // icône possible serait celle de la section web.
      await _search(tester, 'Gratin');
      expect(find.text('Aucune page de recette trouvée'), findsOneWidget);
      // État resserré : pas de grande icône, le pied dit le reste.
      expect(find.byIcon(Icons.search_off_rounded), findsNothing);
      expect(find.text('Vidéos et réseaux sociaux exclus.'), findsOneWidget);
      expect(find.text('Voir sur Google'), findsOneWidget);
    });

    testWidgets('budget d\'IA du jour : carte dédiée, sans « Réessayer »', (
      tester,
    ) async {
      await _pump(
        tester,
        answer: (_) async =>
            throw const WebSearchAiBudgetExceeded('Plafond atteint.'),
      );
      _errors.features.clear();
      await _search(tester, 'blanquette');
      expect(
        find.text(
          'Le budget d\'IA du jour est atteint. La recherche web revient '
          'demain.',
        ),
        findsOneWidget,
      );
      expect(find.text('Réessayer'), findsNothing);
      expect(find.text('Voir sur Google'), findsOneWidget);
      expect(_errors.features, isEmpty);
    });

    testWidgets('requête refusée : message du serveur, sans « Réessayer »', (
      tester,
    ) async {
      await _pump(
        tester,
        answer: (_) async => throw const WebSearchQueryRefused(
          'La recherche dépasse 200 caractères.',
        ),
      );
      _errors.features.clear();
      await _search(tester, 'blanquette');
      expect(find.text('La recherche dépasse 200 caractères.'), findsOneWidget);
      expect(find.text('Réessayer'), findsNothing);
      expect(find.text('Vidéos et réseaux sociaux exclus.'), findsOneWidget);
      expect(_errors.features, isEmpty);
    });

    testWidgets('moteur indisponible : message du serveur, « Réessayer »', (
      tester,
    ) async {
      await _pump(
        tester,
        answer: (_) async => throw const WebSearchEngineUnavailable(
          'Le moteur de recherche est saturé. Réessayez plus tard.',
        ),
      );
      _errors.features.clear();
      await _search(tester, 'blanquette');
      expect(find.text('Moteur de recherche indisponible'), findsOneWidget);
      expect(
        find.text('Le moteur de recherche est saturé. Réessayez plus tard.'),
        findsOneWidget,
      );
      expect(find.text('Réessayer'), findsOneWidget);
      // Le serveur journalise la panne : pas de second rapport.
      expect(_errors.features, isEmpty);
    });

    testWidgets('hors ligne : « Connexion perdue »', (tester) async {
      await _pump(
        tester,
        answer: (_) async =>
            throw GeminiCallableException('unavailable', 'UNAVAILABLE', null),
      );
      await _search(tester, 'blanquette');
      expect(find.text('Connexion perdue'), findsOneWidget);
      expect(find.text('Réessayer'), findsOneWidget);
      expect(find.text('Voir sur Google'), findsOneWidget);
    });

    testWidgets('lecteur sans recherche restante : la phrase sous le bouton', (
      tester,
    ) async {
      final service = await _pump(
        tester,
        canEdit: false,
        phone: true,
        answer: (q) async =>
            WebSearchResponse(query: q, results: _pages, remaining: 0),
      );
      await _search(tester, 'blanquette');
      expect(
        find.text('Il ne vous reste aucune recherche aujourd\'hui.'),
        findsOneWidget,
      );
      // Le bouton reste actif : une recherche en cache sert encore.
      await tester.tap(find.text('Chercher sur le web'));
      await tester.pumpAndSettle();
      expect(service.queries, hasLength(2));
    });

    testWidgets('grand écran, plafond atteint : la phrase sous les boutons', (
      tester,
    ) async {
      await _pump(
        tester,
        answer: (_) async => throw const WebSearchQuotaExceeded(limit: 50),
      );
      await _search(tester, 'blanquette');
      expect(
        find.text('Il ne vous reste aucune recherche aujourd\'hui.'),
        findsOneWidget,
      );
    });

    testWidgets('plafond du jour : carte dédiée, sans « Réessayer »', (
      tester,
    ) async {
      await _pump(
        tester,
        answer: (_) async => throw const WebSearchQuotaExceeded(limit: 50),
      );
      await _search(tester, 'blanquette');
      expect(
        find.text(
          'Vous avez fait vos 50 recherches web d\'aujourd\'hui. Le compteur '
          'repart demain.',
        ),
        findsOneWidget,
      );
      expect(find.text('Réessayer'), findsNothing);
      expect(find.text('Voir sur Google'), findsOneWidget);
    });

    testWidgets('panne : erreur compacte avec « Réessayer »', (tester) async {
      var calls = 0;
      await _pump(
        tester,
        answer: (q) async {
          calls++;
          throw GeminiCallableException('internal', 'boom', null);
        },
      );
      _errors.features.clear();
      await _search(tester, 'blanquette');
      expect(_errors.features, ['search.web']);
      expect(find.text('Réessayer'), findsOneWidget);
      expect(find.text('Voir sur Google'), findsOneWidget);
      await tester.tap(find.text('Réessayer'));
      await tester.pumpAndSettle();
      expect(calls, 2);
    });

    testWidgets('texte modifié après la recherche : « Relancer »', (
      tester,
    ) async {
      final service = await _pump(tester);
      await _search(tester, 'blanquette');
      await tester.enterText(find.byType(TextField), 'blanquette de veau');
      await tester.pumpAndSettle();
      expect(
        find.text('Recherche modifiée depuis la demande.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Relancer'));
      await tester.pumpAndSettle();
      expect(service.queries, ['blanquette', 'blanquette de veau']);
    });

    testWidgets('« Effacer » ferme la section', (tester) async {
      await _pump(tester);
      await _search(tester, 'blanquette');
      await tester.tap(find.text('Effacer'));
      await tester.pumpAndSettle();
      expect(find.text('Sur le web'), findsNothing);
    });
  });

  group('lecture de la réponse', () {
    test('une adresse hors https est écartée', () {
      final response = WebSearchResponse.fromMap({
        'query': 'q',
        'results': [
          {'url': 'http://exemple.fr/r', 'title': 'R'},
          {'url': 'javascript:alert(1)', 'title': 'X'},
          {
            'url': 'https://exemple.fr/r',
            'title': 'R',
            'site': 'exemple.fr',
            // Champ d'un ancien serveur : ignoré.
            'imageUrl': 'https://exemple.fr/i.jpg',
            // Rendu par le serveur, plus lu par le client.
            'directImport': true,
          },
        ],
        'fromCache': true,
        'remaining': 3,
      });
      expect(response.results, hasLength(1));
      expect(response.fromCache, isTrue);
      expect(response.remaining, 3);
    });

    test('les refus attendus se reconnaissent, SDK comme web', () {
      final details = {'reason': webSearchQuotaReason, 'limit': 50};
      final quota = webSearchErrorFrom(
        GeminiCallableException('resource-exhausted', 'x', details),
      );
      expect(quota, isA<WebSearchQuotaExceeded>());
      expect((quota! as WebSearchQuotaExceeded).limit, 50);
      expect(
        webSearchErrorFrom(
          GeminiCallableException('resource_exhausted', 'x', details),
        ),
        isA<WebSearchQuotaExceeded>(),
      );
      // Le plafond de dépense d'IA n'est pas le plafond des recherches.
      expect(
        webSearchErrorFrom(
          GeminiCallableException('resource-exhausted', 'Plafond.', {
            'reason': webSearchAiBudgetReason,
          }),
        ),
        isA<WebSearchAiBudgetExceeded>(),
      );
      expect(
        webSearchErrorFrom(
          GeminiCallableException('INVALID_ARGUMENT', 'Trop long.', {
            'reason': webSearchQueryReason,
          }),
        ),
        isA<WebSearchQueryRefused>(),
      );
      expect(
        webSearchErrorFrom(
          GeminiCallableException('unavailable', 'Saturé.', {
            'reason': webSearchEngineReason,
          }),
        ),
        isA<WebSearchEngineUnavailable>(),
      );
      // Un `unavailable` sans raison est une coupure réseau : non traduit.
      expect(
        webSearchErrorFrom(
          GeminiCallableException('unavailable', 'UNAVAILABLE', null),
        ),
        isNull,
      );
      expect(
        webSearchErrorFrom(GeminiCallableException('internal', 'x', details)),
        isNull,
      );
    });

    test('phrases du restant', () {
      expect(remainingSearchesLine(null), isNull);
      expect(
        remainingSearchesLine(1),
        'Il vous reste 1 recherche aujourd\'hui.',
      );
      expect(
        remainingSearchesLine(12),
        'Il vous reste 12 recherches aujourd\'hui.',
      );
      expect(webPagesFoundLabel(1), '1 page trouvée');
    });
  });

  group('fournisseur', () {
    test('un second appui pendant la recherche ne repart pas', () async {
      final service = _FakeService(_found);
      final container = ProviderContainer(
        overrides: [geminiServiceProvider.overrideWithValue(service)],
      );
      addTearDown(container.dispose);
      final sub = container.listen(webSearchProvider, (_, _) {});
      addTearDown(sub.close);
      final notifier = container.read(webSearchProvider.notifier);
      final first = notifier.search('blanquette');
      final second = notifier.search('blanquette');
      await Future.wait([first, second]);
      expect(service.queries, ['blanquette']);
      final state = container.read(webSearchProvider);
      expect(state, isA<WebSearchSuccess>());
      expect(state.remaining, 49);
      // Fermée, la section garde le nombre restant pour « Aller plus loin ».
      notifier.close();
      expect(container.read(webSearchProvider).remaining, 49);
    });
  });

  group('bouton « Importer » d\'une carte', () {
    Future<List<String>> pumpTile(
      WidgetTester tester, {
      bool imported = false,
    }) async {
      final calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: WebResultTile(
              result: _pages.first,
              canImport: true,
              imported: imported,
              onOpen: () => calls.add('open'),
              onImport: () => calls.add('import'),
              onCopyLink: () => calls.add('copy'),
            ),
          ),
        ),
      );
      return calls;
    }

    testWidgets('lance l\'import sans ouvrir la page', (tester) async {
      final calls = await pumpTile(tester);
      await tester.tap(find.text('Importer'));
      await tester.pumpAndSettle();
      expect(calls, ['import']);
    });

    testWidgets('icône lien, infobulle, cible de 48 px, aucun badge', (
      tester,
    ) async {
      await pumpTile(tester);
      final button = find.widgetWithText(FilledButton, 'Importer');
      expect(button, findsOneWidget);
      expect(
        find.descendant(of: button, matching: find.byIcon(Icons.link)),
        findsOneWidget,
      );
      expect(
        find.byTooltip('Importer cette recette dans vos brouillons'),
        findsOneWidget,
      );
      expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
      expect(find.text('Import direct'), findsNothing);
      expect(find.byIcon(Icons.bolt), findsNothing);
    });

    testWidgets('import envoyé : « Import envoyé », plus de bouton', (
      tester,
    ) async {
      final calls = await pumpTile(tester, imported: true);
      expect(find.text('Import envoyé'), findsOneWidget);
      expect(find.text('Importer'), findsNothing);
      await tester.tap(find.text('Import envoyé'));
      await tester.pumpAndSettle();
      expect(calls, isNot(contains('import')));
    });
  });

  group('ouverture d\'une page', () {
    test('navigateur intégré sur téléphone, navigateur ailleurs', () {
      for (final host in [TargetPlatform.android, TargetPlatform.iOS]) {
        expect(
          webPageLaunchModeFor(host: host, inAppSupported: true),
          LaunchMode.inAppBrowserView,
          reason: '$host',
        );
        expect(
          webPageLaunchModeFor(host: host, inAppSupported: false),
          LaunchMode.externalApplication,
          reason: '$host sans navigateur intégré',
        );
      }
      for (final host in [
        null,
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        expect(
          webPageLaunchModeFor(host: host, inAppSupported: true),
          LaunchMode.externalApplication,
          reason: '$host',
        );
      }
    });
  });

  testWidgets('vignette : toujours l\'icône, jamais d\'image', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: WebResultThumbnail())),
    );
    expect(find.byIcon(Icons.public), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets('cartes d\'attente : muettes pour un lecteur d\'écran', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: WebResultPlaceholderTile())),
    );
    expect(find.bySemanticsLabel(RegExp('.')), findsNothing);
    handle.dispose();
  });

  group('bloc de Google', () {
    test('mode par plateforme', () {
      expect(googleSuggestionsModeFor(null), GoogleSuggestionsMode.webFrame);
      for (final p in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      ]) {
        expect(googleSuggestionsModeFor(p), GoogleSuggestionsMode.webView);
      }
      expect(
        googleSuggestionsModeFor(TargetPlatform.windows),
        GoogleSuggestionsMode.windowsWebView,
      );
      expect(
        googleSuggestionsModeFor(TargetPlatform.linux),
        GoogleSuggestionsMode.chips,
      );
    });

    test(
      'Windows : un onglet par appui, redirections ignorées une seconde',
      () {
        var now = DateTime(2026, 10, 12, 10);
        final gate = ExternalOpenGate(now: () => now);
        // google.com, puis consent.google.com et /search dans la seconde.
        expect(gate.tryOpen(), isTrue);
        now = now.add(const Duration(milliseconds: 200));
        expect(gate.tryOpen(), isFalse);
        now = now.add(const Duration(milliseconds: 700));
        expect(gate.tryOpen(), isFalse);
        // Une redirection lente, 1,1 s après le clic : la fenêtre a glissé.
        now = now.add(const Duration(milliseconds: 200));
        expect(gate.tryOpen(), isFalse);
        // Un nouvel appui, une seconde après la dernière étape, ouvre.
        now = now.add(const Duration(seconds: 1));
        expect(gate.tryOpen(), isTrue);
        expect(gate.tryOpen(), isFalse);
      },
    );

    test('le document interdit tout script', () {
      expect(
        wrapGoogleSuggestions('<div>G</div>'),
        contains('content="script-src \'none\'"'),
      );
    });

    testWidgets('puces : rien du tout sans requête', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: GoogleSuggestionChips(queries: [])),
        ),
      );
      expect(find.byType(Padding), findsNothing);
      expect(find.byType(ActionChip), findsNothing);
    });

    testWidgets('puces : sur plusieurs lignes, sans hauteur fixe', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: GoogleSuggestionChips(
              queries: ['blanquette de veau', 'blanquette à l\'ancienne'],
            ),
          ),
        ),
      );
      expect(find.byType(ActionChip), findsNWidgets(2));
      expect(find.byType(Wrap), findsOneWidget);
      expect(find.byType(ListView), findsNothing);
    });
  });
}
