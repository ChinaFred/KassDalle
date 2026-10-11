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
import 'package:kass_dalle/features/search/presentation/search_providers.dart';
import 'package:kass_dalle/features/search/presentation/search_screen.dart';

/// L'écran Explorer avec du texte : sections, compteur total, ligne des
/// petits ingrédients, et le bandeau d'import au retour de Google.
class _FakeService extends GeminiService {
  @override
  Future<UrlImportQuota> getUrlImportQuota() async =>
      const UrlImportQuota(limit: 10, used: 0, remaining: 10);
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

Future<void> _pump(WidgetTester tester, {bool canEdit = true}) async {
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

    Future<void> leaveAndComeBack(WidgetTester tester) async {
      await tester.enterText(find.byType(TextField), 'blanquette');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chercher sur Google'));
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
      await tester.tap(find.text('Coller le lien'));
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
      await tester.tap(find.byTooltip('Fermer'));
      await tester.pumpAndSettle();
      expect(
        find.text('Vous avez trouvé une recette ? Importez-la.'),
        findsNothing,
      );
    });

    testWidgets('téléphone : le bandeau défile en tête des résultats', (
      tester,
    ) async {
      await _pump(tester);
      await leaveAndComeBack(tester);
      const sentence = 'Vous avez trouvé une recette ? Importez-la.';
      // Grand écran : fixe sous le champ, hors de la liste.
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.text(sentence),
        ),
        findsNothing,
      );
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpAndSettle();
      // Téléphone : premier élément de la liste, qui défile avec elle.
      expect(
        find.descendant(
          of: find.byType(ListView),
          matching: find.text(sentence),
        ),
        findsOneWidget,
      );
      // Seule la phrase est annoncée à l'apparition, pas toute la carte.
      final live = find.ancestor(
        of: find.text(sentence),
        matching: find.byWidgetPredicate(
          (w) => w is Semantics && (w.properties.liveRegion ?? false),
        ),
      );
      expect(live, findsOneWidget);
      expect(
        find.descendant(of: live, matching: find.text('Coller le lien')),
        findsNothing,
      );
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
