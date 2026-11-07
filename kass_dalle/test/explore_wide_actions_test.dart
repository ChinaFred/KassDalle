import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
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
import 'package:kass_dalle/features/search/presentation/explore_filter_panel.dart';
import 'package:kass_dalle/features/search/presentation/search_providers.dart';
import 'package:kass_dalle/features/search/presentation/search_screen.dart';

/// La rangée d'actions de l'Explorer sur grand écran : « Chercher avec
/// l'IA », puis les menus « Créer avec l'IA » et « Ailleurs ». Un menu qui
/// n'aurait qu'une entrée devient un bouton direct ; un appel en cours
/// désactive l'entrée, pas le menu.
class _FakeService extends GeminiService {
  @override
  Future<UrlImportQuota> getUrlImportQuota() async =>
      const UrlImportQuota(limit: 10, used: 0, remaining: 10);
}

class _IdeasLoading extends AiIdeasNotifier {
  @override
  AiIdeasState build() => const AiIdeasLoading('gratin');
}

class _WebLoading extends WebSearchNotifier {
  @override
  WebSearchState build() => const WebSearchLoading('gratin');
}

class _RankingLoading extends AiRankingNotifier {
  @override
  AiRankingState build() => const AiRankingLoading(
    AiRankingRequest(
      query: 'gratin',
      filterSignature: '',
      sources: SearchParams(),
      corpus: [],
    ),
  );
}

Recipe _recipe(String id, String titre) => Recipe(
  id: id,
  titre: titre,
  langue: 'fr',
  rawCooklang: '',
  imageUrls: const [],
  reviewStatus: ReviewStatus.validated,
  tags: const RecipeTags(),
  ingredientsIndex: const [],
  createdBy: 'moi',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

Future<void> _pump(
  WidgetTester tester, {
  bool canEdit = true,
  ExplorePick? pick,
  List<Recipe>? recipes,
  bool ideasBusy = false,
  bool webBusy = false,
  bool rankingBusy = false,
}) async {
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => SearchScreen(pick: pick),
      ),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        appUserProvider.overrideWith((ref) => Stream.value(null)),
        canEditProvider.overrideWithValue(canEdit),
        exploreCorpusProvider.overrideWith(
          (ref, params) async => ExploreCorpus(
            myUid: 'moi',
            recipes: recipes ?? [_recipe('r1', 'Gratin')],
          ),
        ),
        myRatingProvider.overrideWith((ref, id) => Stream.value(null)),
        geminiServiceProvider.overrideWithValue(_FakeService()),
        if (ideasBusy) aiIdeasProvider.overrideWith(_IdeasLoading.new),
        if (webBusy) webSearchProvider.overrideWith(_WebLoading.new),
        if (rankingBusy) aiRankingProvider.overrideWith(_RankingLoading.new),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await _settle(tester);
}

/// Les états en cours animent des cartes d'attente sans fin :
/// `pumpAndSettle` n'aboutirait pas.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _open(WidgetTester tester, String menu) async {
  await tester.tap(find.text(menu));
  await _settle(tester);
}

MenuItemButton _entry(WidgetTester tester, String label) =>
    tester.widget<MenuItemButton>(find.widgetWithText(MenuItemButton, label));

bool _fieldHasFocus(WidgetTester tester) => tester
    .widget<EditableText>(
      find.descendant(
        of: find.byType(TextField),
        matching: find.byType(EditableText),
      ),
    )
    .focusNode
    .hasFocus;

void main() {
  group('éditeur', () {
    testWidgets('trois boutons, le compteur hors du libellé', (tester) async {
      await _pump(tester);
      expect(
        find.widgetWithText(FilledButton, 'Chercher avec l\'IA'),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(OutlinedButton, 'Créer avec l\'IA'),
        findsOneWidget,
      );
      expect(find.widgetWithText(OutlinedButton, 'Ailleurs'), findsOneWidget);
      expect(find.byIcon(Icons.arrow_drop_down), findsNWidgets(2));
      // Les entrées restent dans les menus fermés.
      expect(find.text('Imaginer 3 recettes'), findsNothing);
      expect(find.text('Chercher sur le web'), findsNothing);
      expect(find.text('Importer depuis un lien'), findsNothing);
      expect(find.textContaining('·'), findsNothing);
    });

    testWidgets('« Créer avec l\'IA » : imaginer, puis composer', (
      tester,
    ) async {
      await _pump(tester);
      await _open(tester, 'Créer avec l\'IA');
      expect(find.text('Imaginer 3 recettes'), findsOneWidget);
      expect(
        find.text(
          'L\'IA rédige trois recettes sur votre envie, à relire avant de '
          'les enregistrer en brouillon.',
        ),
        findsOneWidget,
      );
      expect(find.text('Composer un repas'), findsOneWidget);
      expect(
        find.text(
          'Discutez d\'un plat ou d\'un menu complet. Les plats retenus '
          'deviennent des brouillons à relire.',
        ),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(find.text('Composer un repas')).dy,
        greaterThan(tester.getTopLeft(find.text('Imaginer 3 recettes')).dy),
      );
      // Le sous-titre passe à la ligne : l'entrée reste bornée.
      expect(
        tester
            .getSize(find.widgetWithText(MenuItemButton, 'Composer un repas'))
            .width,
        lessThan(480),
      );
    });

    testWidgets('« Ailleurs » : le web, puis l\'import', (tester) async {
      await _pump(tester);
      await _open(tester, 'Ailleurs');
      expect(find.text('Chercher sur le web'), findsOneWidget);
      expect(
        find.text('Jusqu\'à 8 pages de recettes, affichées ici.'),
        findsOneWidget,
      );
      expect(find.text('Importer depuis un lien'), findsOneWidget);
      expect(
        find.text('Une recette d\'une page web arrive dans vos brouillons.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Importer depuis un lien'));
      await tester.pumpAndSettle();
      // La boîte d'import s'ouvre.
      expect(find.text('Adresse de la page'), findsOneWidget);
    });

    testWidgets('les menus s\'annoncent comme tels', (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester);
      for (final menu in ['Créer avec l\'IA', 'Ailleurs']) {
        expect(
          tester.getSemantics(find.text(menu)),
          isSemantics(
            label: menu,
            hint: 'Ouvre un menu',
            isButton: true,
            hasExpandedState: true,
            isExpanded: false,
          ),
          reason: menu,
        );
      }
      // Menu ouvert : annoncé déplié.
      await _open(tester, 'Ailleurs');
      expect(
        tester.getSemantics(find.text('Ailleurs')),
        isSemantics(hasExpandedState: true, isExpanded: true),
      );
      handle.dispose();
    });

    // La police des tests donne 14 px à chaque caractère : les libellés y
    // sont environ deux fois plus larges qu'avec la police de l'application.
    // Les largeurs ci-dessous sont donc celles de cette police.
    testWidgets('à 1 200 px, la rangée tient sur une ligne', (tester) async {
      await _pump(tester);
      final y = tester.getTopLeft(find.text('Chercher avec l\'IA')).dy;
      expect(tester.getTopLeft(find.text('Créer avec l\'IA')).dy, y);
      expect(tester.getTopLeft(find.text('Ailleurs')).dy, y);
    });

    testWidgets('fenêtre plus étroite : les deux menus passent ensemble', (
      tester,
    ) async {
      await _pump(tester);
      tester.view.physicalSize = const Size(1000, 1000);
      await _settle(tester);
      final ask = tester.getTopLeft(find.text('Chercher avec l\'IA')).dy;
      final create = tester.getTopLeft(find.text('Créer avec l\'IA')).dy;
      expect(create, greaterThan(ask));
      expect(tester.getTopLeft(find.text('Ailleurs')).dy, create);
    });
  });

  group('info-bulle de « Chercher avec l\'IA »', () {
    testWidgets('une recette : au singulier', (tester) async {
      await _pump(tester);
      expect(
        find.byTooltip('L\'IA classe la recette retenue par les filtres.'),
        findsOneWidget,
      );
    });

    testWidgets('aucune recette : bouton inactif, info-bulle qui le dit', (
      tester,
    ) async {
      await _pump(tester, recipes: const []);
      expect(
        find.byTooltip(
          'Aucune recette retenue par les filtres : l\'IA n\'a rien à classer.',
        ),
        findsOneWidget,
      );
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Chercher avec l\'IA'),
      );
      expect(button.onPressed, isNull);
    });

    test('accordée au nombre', () {
      expect(
        askAiTooltip(12),
        'L\'IA classe les 12 recettes retenues par les filtres.',
      );
      expect(
        askAiTooltip(1),
        'L\'IA classe la recette retenue par les filtres.',
      );
    });
  });

  testWidgets('mode choix : « Imaginer 3 recettes » en bouton direct', (
    tester,
  ) async {
    await _pump(
      tester,
      pick: const ExplorePick(initialQuery: '', banner: 'Recette pour lundi'),
    );
    expect(find.text('Créer avec l\'IA'), findsNothing);
    expect(
      find.widgetWithText(OutlinedButton, 'Imaginer 3 recettes'),
      findsOneWidget,
    );
    // L'import reste proposé en mode choix.
    await _open(tester, 'Ailleurs');
    expect(find.text('Chercher sur le web'), findsOneWidget);
    expect(find.text('Importer depuis un lien'), findsOneWidget);
  });

  group('appel en cours : l\'entrée se désactive, pas le menu', () {
    testWidgets('classement : bouton plein inactif', (tester) async {
      await _pump(tester, rankingBusy: true);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Chercher avec l\'IA'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('rédaction : « Imaginer » inactif, « Composer » actif', (
      tester,
    ) async {
      await _pump(tester, ideasBusy: true);
      final menu = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Créer avec l\'IA'),
      );
      expect(menu.onPressed, isNotNull);
      await _open(tester, 'Créer avec l\'IA');
      expect(_entry(tester, 'Imaginer 3 recettes').onPressed, isNull);
      expect(_entry(tester, 'Composer un repas').onPressed, isNotNull);
    });

    testWidgets('rédaction en mode choix : le bouton direct inactif', (
      tester,
    ) async {
      await _pump(
        tester,
        ideasBusy: true,
        pick: const ExplorePick(initialQuery: '', banner: 'Recette pour lundi'),
      );
      final button = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Imaginer 3 recettes'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('recherche web : « Chercher » inactif, « Importer » actif', (
      tester,
    ) async {
      await _pump(tester, webBusy: true);
      await _open(tester, 'Ailleurs');
      expect(_entry(tester, 'Chercher sur le web').onPressed, isNull);
      expect(_entry(tester, 'Importer depuis un lien').onPressed, isNotNull);
    });

    testWidgets('recherche web du lecteur : son bouton inactif', (
      tester,
    ) async {
      await _pump(tester, canEdit: false, webBusy: true);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Chercher sur le web'),
      );
      expect(button.onPressed, isNull);
    });
  });

  group('champ vide : l\'entrée choisie rend le focus au champ', () {
    for (final (menu, entry, help) in [
      (
        'Créer avec l\'IA',
        'Imaginer 3 recettes',
        'Écrivez votre envie pour que l\'IA imagine des recettes.',
      ),
      (
        'Ailleurs',
        'Chercher sur le web',
        'Écrivez ce que vous cherchez sur le web.',
      ),
    ]) {
      testWidgets(entry, (tester) async {
        await _pump(tester);
        FocusManager.instance.primaryFocus?.unfocus();
        await _settle(tester);
        expect(_fieldHasFocus(tester), isFalse);
        await _open(tester, menu);
        await tester.tap(find.text(entry));
        await _settle(tester);
        expect(find.text(entry), findsNothing, reason: 'menu fermé');
        expect(find.text(help), findsOneWidget);
        expect(_fieldHasFocus(tester), isTrue);
      });
    }

    testWidgets('au clavier aussi', (tester) async {
      await _pump(tester);
      await tester.tap(find.byType(TextField));
      await _settle(tester);
      // Champ → « Chercher avec l'IA » → « Créer avec l'IA ».
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester);
      expect(find.text('Imaginer 3 recettes'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await _settle(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await _settle(tester);
      expect(
        find.text('Écrivez votre envie pour que l\'IA imagine des recettes.'),
        findsOneWidget,
      );
      expect(_fieldHasFocus(tester), isTrue);
    });
  });

  testWidgets(
    'ordre de tabulation : panneau, champ, IA, Créer, Ailleurs, liste',
    (tester) async {
      final handle = tester.ensureSemantics();
      await _pump(tester);
      await tester.tap(find.byType(TextField));
      await _settle(tester);
      expect(_fieldHasFocus(tester), isTrue);

      // Maj+Tab depuis le champ : le dernier élément du panneau des filtres.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await _settle(tester);
      expect(_focusInside(find.byType(ExploreFilterPanel)), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await _settle(tester);
      expect(_fieldHasFocus(tester), isTrue);

      for (final label in [
        'Chercher avec l\'IA',
        'Créer avec l\'IA',
        'Ailleurs',
      ]) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await _settle(tester);
        expect(
          tester.getSemantics(find.text(label)),
          isSemantics(isFocused: true),
          reason: label,
        );
      }
      // Après « Ailleurs », la liste, pas le panneau.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await _settle(tester);
      expect(_focusInside(find.byType(ExploreFilterPanel)), isFalse);
      expect(
        _focusInside(find.byKey(const PageStorageKey('explore-results'))),
        isTrue,
      );
      handle.dispose();
    },
  );
}

/// Vrai si le focus principal est dans le widget unique de [finder].
bool _focusInside(Finder finder) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  final target = finder.evaluate().single;
  if (focused == target) return true;
  var inside = false;
  focused.visitAncestorElements((e) {
    if (e == target) {
      inside = true;
      return false;
    }
    return true;
  });
  return inside;
}
