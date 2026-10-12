import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kass_dalle/core/services/gemini_providers.dart';
import 'package:kass_dalle/core/services/gemini_service.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/domain/url_import.dart';
import 'package:kass_dalle/features/recipes/presentation/recipe_providers.dart';
import 'package:kass_dalle/features/search/domain/search_models.dart';
import 'package:kass_dalle/features/search/domain/web_search.dart';
import 'package:kass_dalle/features/search/presentation/search_providers.dart';
import 'package:kass_dalle/features/search/presentation/search_screen.dart';
import 'package:kass_dalle/features/search/presentation/search_widgets.dart';

/// L'écran Explorer avec du texte : sections, compteur total, ligne des
/// petits ingrédients, et le bandeau d'import au retour du navigateur.
class _FakeService extends GeminiService {
  @override
  Future<UrlImportQuota> getUrlImportQuota() async =>
      const UrlImportQuota(limit: 10, used: 0, remaining: 10);

  @override
  Future<WebSearchResponse> searchWebRecipes(String query) async =>
      WebSearchResponse(
        query: query,
        results: [
          WebRecipeResult(
            url: Uri.parse('https://www.le-site.fr/blanquette'),
            title: 'Blanquette de veau',
            site: 'le-site.fr',
          ),
        ],
        remaining: 49,
      );
}

Recipe _recipe(
  String id,
  String titre, {
  List<String> ingredients = const [],
  List<String> cuisines = const [],
}) => Recipe(
  id: id,
  titre: titre,
  langue: 'fr',
  rawCooklang: '',
  imageUrls: const [],
  reviewStatus: ReviewStatus.validated,
  tags: RecipeTags(cuisines: cuisines),
  ingredientsIndex: ingredients,
  createdBy: 'moi',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

final _corpus = ExploreCorpus(
  myUid: 'moi',
  recipes: [
    _recipe('coreen', 'Poulet coréen', ingredients: const ['poulet']),
    _recipe(
      'bibimbap',
      'Bibimbap',
      ingredients: const ['riz', 'boeuf'],
      cuisines: const ['Coréenne'],
    ),
    _recipe(
      'poelee',
      'Poêlée de légumes',
      ingredients: const ['ailes de poulet', 'courgettes'],
    ),
    _recipe('sel', 'Sablés au sel', ingredients: const ['farine']),
  ],
);

/// [shell] : l'écran dans le corps d'un `Scaffold` parent, comme dans
/// l'application (`AppShell`), qui retire `viewInsets` du `MediaQuery`.
Future<void> _pump(
  WidgetTester tester, {
  bool canEdit = true,
  bool shell = false,
}) async {
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) =>
            shell ? const Scaffold(body: SearchScreen()) : const SearchScreen(),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appUserProvider.overrideWith((ref) => Stream.value(null)),
        canEditProvider.overrideWithValue(canEdit),
        exploreCorpusProvider.overrideWith((ref, params) async => _corpus),
        myRatingProvider.overrideWith((ref, id) => Stream.value(null)),
        geminiServiceProvider.overrideWithValue(_FakeService()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('« coréen » : deux sections, total des deux', (tester) async {
    await _pump(tester);
    await tester.enterText(find.byType(TextField), 'coréen');
    await tester.pumpAndSettle();
    expect(find.text('Dans le titre (1)'), findsOneWidget);
    expect(find.text('Par cuisine, type ou thème (1)'), findsOneWidget);
    expect(find.textContaining('Dans les ingrédients'), findsNothing);
    expect(find.text('2 recettes'), findsOneWidget);
    expect(find.text('Bibimbap'), findsOneWidget);
  });

  testWidgets(
    'section ingrédients repliée sous le titre, comptée, ouverte au clic',
    (tester) async {
      await _pump(tester);
      await tester.enterText(find.byType(TextField), 'poulet');
      await tester.pumpAndSettle();
      expect(find.text('Dans les ingrédients principaux (1)'), findsOneWidget);
      expect(find.text('Poêlée de légumes'), findsNothing);
      expect(find.text('2 recettes'), findsOneWidget);
      await tester.tap(find.text('Dans les ingrédients principaux (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Poêlée de légumes'), findsOneWidget);
      expect(find.text('Avec : ailes de poulet'), findsOneWidget);
      // Le texte change : la section reprend son état par défaut.
      await tester.enterText(find.byType(TextField), 'poulet ');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'poulets');
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'poulet');
      await tester.pumpAndSettle();
      expect(find.text('Poêlée de légumes'), findsNothing);
    },
  );

  testWidgets('un petit ingrédient tapé : cherché dans les titres seuls', (
    tester,
  ) async {
    await _pump(tester);
    await tester.enterText(find.byType(TextField), 'sel');
    await tester.pumpAndSettle();
    expect(
      find.text('« sel » n\'est cherché que dans les titres.'),
      findsOneWidget,
    );
    expect(find.text('Sablés au sel'), findsOneWidget);
  });

  testWidgets('libellé « Chercher avec l\'IA »', (tester) async {
    await _pump(tester);
    expect(find.textContaining('Chercher avec l\'IA'), findsOneWidget);
    expect(find.textContaining('Demander à l\'IA'), findsNothing);
  });

  group('bandeau au retour de Google', () {
    const launcher = MethodChannel('plugins.flutter.io/url_launcher');
    String? clipboard;

    setUp(() {
      clipboard = null;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(launcher, (call) async => true);
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          return clipboard == null ? null : {'text': clipboard};
        }
        return null;
      });
    });

    tearDown(() {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(launcher, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    /// Recherche web, puis [leave] : « Voir sur Google » (défaut) ou
    /// « Ouvrir » sur la carte. Puis retour dans l'application.
    Future<void> leaveAndComeBack(
      WidgetTester tester, {
      String leave = 'Voir sur Google',
    }) async {
      // Grand écran assez haut pour que le bandeau tienne sous la liste.
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'blanquette');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chercher sur le web'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(leave),
        200,
        scrollable: find
            .descendant(
              of: find.byKey(const PageStorageKey('explore-results')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(leave).first);
      await tester.pumpAndSettle();
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
    }

    testWidgets('éditeur : « Coller le lien » ouvre la boîte remplie', (
      tester,
    ) async {
      await _pump(tester);
      await leaveAndComeBack(tester);
      expect(
        find.text('Vous avez trouvé une recette ? Importez-la.'),
        findsOneWidget,
      );
      clipboard = 'Voici https://www.marmiton.org/recettes/blanquette';
      await tester.tap(find.text('Coller le lien').hitTestable());
      await tester.pumpAndSettle();
      expect(find.text('Adresse de la page'), findsOneWidget);
      expect(
        find.text('https://www.marmiton.org/recettes/blanquette'),
        findsOneWidget,
      );
      // « Annuler » laisse le bandeau.
      await tester.tap(find.text('Annuler'));
      await tester.pumpAndSettle();
      expect(
        find.text('Vous avez trouvé une recette ? Importez-la.'),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Fermer').hitTestable());
      await tester.pumpAndSettle();
      expect(
        find.text('Vous avez trouvé une recette ? Importez-la.'),
        findsNothing,
      );
    });

    testWidgets(
      'éditeur : la page ouverte depuis sa carte est dans le bandeau',
      (tester) async {
        await _pump(tester);
        clipboard = 'https://ailleurs.example/autre';
        await leaveAndComeBack(tester, leave: 'Ouvrir');
        expect(
          find.text('Vous avez trouvé une recette ? Importez-la.'),
          findsOneWidget,
        );
        // L'adresse de la carte, pas celle du presse-papiers.
        expect(find.text('Importer ce lien').hitTestable(), findsOneWidget);
        await tester.tap(find.text('Importer ce lien').hitTestable());
        await tester.pumpAndSettle();
        expect(find.text('https://www.le-site.fr/blanquette'), findsOneWidget);
      },
    );

    Finder resultsScrollable() => find
        .descendant(
          of: find.byKey(const PageStorageKey('explore-results')),
          matching: find.byType(Scrollable),
        )
        .first;

    void comeBack(WidgetTester tester) {
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    /// Recherche web lancée sur grand écran (le bouton y est dans la
    /// rangée), puis écran ramené à [size].
    Future<void> searchOn(
      WidgetTester tester,
      Size size, {
      bool shell = false,
    }) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(tester, shell: shell);
      await tester.enterText(find.byType(TextField), 'blanquette');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chercher sur le web'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = size;
      await tester.pumpAndSettle();
    }

    for (final (label, size, sentence) in [
      ('téléphone', const Size(400, 800), importBannerShortSentence),
      ('grand écran', const Size(1000, 800), importBannerSentence),
    ]) {
      testWidgets(
        '$label : le bandeau se pose sous la liste, la carte visible ne bouge pas',
        (tester) async {
          await searchOn(tester, size);
          final card = find.text('Blanquette de veau');
          final offsetBefore = tester
              .state<ScrollableState>(resultsScrollable())
              .position
              .pixels;
          final cardBefore = tester.getTopLeft(card);

          await tester.tap(find.text('Ouvrir').first);
          await tester.pumpAndSettle();
          comeBack(tester);
          await tester.pumpAndSettle();

          // Le bandeau est là, hors de la liste, sous elle.
          expect(find.text(sentence), findsOneWidget);
          expect(
            find.descendant(
              of: find.byType(ListView),
              matching: find.text(sentence),
            ),
            findsNothing,
          );
          expect(
            tester.getTopLeft(find.text(sentence)).dy,
            greaterThan(tester.getBottomLeft(resultsScrollable()).dy - 1),
          );
          // La carte n'était pas recouverte : rien n'a bougé.
          expect(
            tester.state<ScrollableState>(resultsScrollable()).position.pixels,
            offsetBefore,
          );
          expect(tester.getTopLeft(card), cardBefore);

          // Seule la phrase est annoncée au retour, pas toute la carte.
          final live = find.ancestor(
            of: find.text(sentence),
            matching: find.byWidgetPredicate(
              (w) => w is Semantics && (w.properties.liveRegion ?? false),
            ),
          );
          expect(live, findsOneWidget);
          expect(
            find.descendant(of: live, matching: find.text('Importer ce lien')),
            findsNothing,
          );
        },
      );
    }

    testWidgets(
      'téléphone : la carte recouverte par le bandeau revient en vue',
      (tester) async {
        // 590 px : le bas de la carte tombe dans la bande que le bandeau
        // occupera.
        await searchOn(tester, const Size(400, 590));
        final cardFinder = find.byType(WebResultTile);
        final pixelsBefore = tester
            .state<ScrollableState>(resultsScrollable())
            .position
            .pixels;

        await tester.tap(find.text('Ouvrir').first);
        await tester.pumpAndSettle();
        comeBack(tester);
        await tester.pumpAndSettle();

        expect(find.text(importBannerShortSentence), findsOneWidget);
        // La liste a défilé juste assez : le bas de la carte touche le bas de
        // la liste, au-dessus du bandeau.
        expect(
          tester.state<ScrollableState>(resultsScrollable()).position.pixels,
          greaterThan(pixelsBefore),
        );
        expect(
          tester.getBottomLeft(cardFinder).dy,
          closeTo(tester.getBottomLeft(resultsScrollable()).dy, 0.5),
        );
        expect(
          tester.getBottomLeft(cardFinder).dy,
          lessThanOrEqualTo(
            tester.getTopLeft(find.text(importBannerShortSentence)).dy,
          ),
        );
      },
    );

    testWidgets('téléphone, texte à 200 % : une ligne, aucun dépassement', (
      tester,
    ) async {
      await searchOn(tester, const Size(1000, 800));
      await tester.tap(find.text('Ouvrir').first);
      await tester.pumpAndSettle();
      comeBack(tester);
      await tester.pumpAndSettle();
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      // Assez de hauteur : le bandeau tient sur une ligne, la liste garde
      // sa place.
      tester.view.physicalSize = const Size(360, 800);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final sentence = find.text(importBannerShortSentence);
      expect(sentence, findsOneWidget);
      expect(tester.widget<Text>(sentence).maxLines, 1);
      expect(find.text('Importer ce lien'), findsOneWidget);
      expect(
        tester.getSize(resultsScrollable()).height,
        greaterThanOrEqualTo(120),
      );

      // Petite hauteur : le bandeau s'efface plutôt que d'écraser la liste.
      tester.view.physicalSize = const Size(360, 640);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(sentence.hitTestable(), findsNothing);
      expect(tester.getSize(resultsScrollable()).height, greaterThan(0));
    });

    testWidgets('clavier ouvert, sous le Scaffold du shell : pas de bandeau', (
      tester,
    ) async {
      // Assez haut pour que le bandeau tienne encore, clavier ouvert : seul
      // le clavier le masque.
      await searchOn(tester, const Size(400, 1400), shell: true);
      await tester.tap(find.text('Ouvrir').first);
      await tester.pumpAndSettle();
      comeBack(tester);
      await tester.pumpAndSettle();
      expect(find.text(importBannerShortSentence), findsOneWidget);

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      expect(find.text(importBannerShortSentence), findsNothing);
      expect(tester.takeException(), isNull);

      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(find.text(importBannerShortSentence), findsOneWidget);
    });

    testWidgets('grand écran, fenêtre basse, texte à 200 % : la liste garde '
        '120 px', (tester) async {
      await searchOn(tester, const Size(1000, 800));
      await tester.tap(find.text('Ouvrir').first);
      await tester.pumpAndSettle();
      comeBack(tester);
      await tester.pumpAndSettle();
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final sentence = find.text(importBannerSentence);

      for (final height in [1000.0, 800.0, 700.0, 600.0]) {
        tester.view.physicalSize = Size(1000, height);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$height');
        final listHeight = tester.getSize(resultsScrollable()).height;
        final shown =
            sentence.hitTestable().evaluate().isNotEmpty ||
            find
                .text(importBannerShortSentence)
                .hitTestable()
                .evaluate()
                .isNotEmpty;
        if (shown) {
          expect(
            listHeight,
            greaterThanOrEqualTo(importBannerMinListHeight),
            reason: '$height',
          );
        }
        if (height == 1000) expect(shown, isTrue);
      }
    });

    /// Vrai si le focus clavier est dans le bandeau dont la phrase est
    /// [sentence].
    bool focusInBanner(WidgetTester tester, String sentence) {
      final cards = find.ancestor(
        of: find.text(sentence),
        matching: find.byType(Card),
      );
      if (cards.evaluate().isEmpty) return false;
      final card = tester.element(cards.first);
      final focused = FocusManager.instance.primaryFocus?.context;
      if (focused == null) return false;
      var inside = false;
      focused.visitAncestorElements((e) {
        if (e == card) {
          inside = true;
          return false;
        }
        return true;
      });
      return inside;
    }

    /// Tab [count] fois ; vrai si le focus est passé par un bandeau.
    Future<bool> tabReaches(
      WidgetTester tester,
      String sentence, {
      int count = 200,
    }) async {
      // Le focus part du champ de recherche.
      await tester.tap(find.byType(TextField));
      await tester.pump();
      for (var i = 0; i < count; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        if (focusInBanner(tester, sentence)) return true;
      }
      return false;
    }

    testWidgets(
      'grand écran, fenêtre basse : complet, puis compact, puis rien',
      (tester) async {
        await searchOn(tester, const Size(1000, 800));
        await tester.tap(find.text('Ouvrir').first);
        await tester.pumpAndSettle();
        comeBack(tester);
        await tester.pumpAndSettle();
        final full = find.text(importBannerSentence).hitTestable();
        final compact = find.text(importBannerShortSentence).hitTestable();

        for (final (height, fullShown, compactShown) in [
          (800.0, true, false),
          (600.0, false, true),
          (520.0, false, false),
        ]) {
          tester.view.physicalSize = Size(1000, height);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: '$height');
          expect(full.evaluate().isNotEmpty, fullShown, reason: '$height');
          expect(
            compact.evaluate().isNotEmpty,
            compactShown,
            reason: '$height',
          );
          if (fullShown || compactShown) {
            expect(
              tester.getSize(resultsScrollable()).height,
              greaterThanOrEqualTo(importBannerMinListHeight),
              reason: '$height',
            );
          }
        }
      },
    );

    testWidgets('bandeau masqué : Tab ne l\'atteint pas', (tester) async {
      await searchOn(tester, const Size(1000, 800));
      await tester.tap(find.text('Ouvrir').first);
      await tester.pumpAndSettle();
      comeBack(tester);
      await tester.pumpAndSettle();

      // Complet affiché : Tab l'atteint, jamais la variante compacte cachée.
      expect(await tabReaches(tester, importBannerShortSentence), isFalse);
      expect(await tabReaches(tester, importBannerSentence), isTrue);

      // Fenêtre trop basse : aucune variante, aucun arrêt de focus.
      tester.view.physicalSize = const Size(1000, 520);
      await tester.pumpAndSettle();
      expect(find.text(importBannerSentence).hitTestable(), findsNothing);
      expect(await tabReaches(tester, importBannerSentence), isFalse);
      expect(await tabReaches(tester, importBannerShortSentence), isFalse);
    });

    testWidgets('lecteur : pas de bandeau', (tester) async {
      await _pump(tester, canEdit: false);
      await leaveAndComeBack(tester);
      expect(
        find.text('Vous avez trouvé une recette ? Importez-la.'),
        findsNothing,
      );
    });
  });
}
