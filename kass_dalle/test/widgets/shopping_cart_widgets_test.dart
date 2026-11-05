import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/planning/domain/planned_meal.dart';
import 'package:kass_dalle/features/planning/presentation/planning_widgets.dart';
import 'package:kass_dalle/features/recipes/data/shopping_cart_repository.dart';
import 'package:kass_dalle/features/recipes/domain/shopping_cart.dart';
import 'package:kass_dalle/features/recipes/presentation/detail/shopping_list_sheet.dart';
import 'package:kass_dalle/features/recipes/presentation/recipe_providers.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _uid = 'u1';

/// Un panier dont la lecture attend [gate] : un ajout reste en cours tant
/// qu'on ne l'ouvre pas.
class _SlowRepo extends ShoppingCartRepository {
  _SlowRepo({required super.firestore, required super.errorReportService});

  final gate = Completer<void>();

  @override
  Future<ShoppingCart> load(String uid) async {
    await gate.future;
    return super.load(uid);
  }
}

AppUser _user() => AppUser(
  uid: _uid,
  email: 'u1@example.com',
  displayName: 'Utilisateur',
  role: UserRole.reader,
  createdAt: DateTime(2026),
  lastSeenAt: DateTime(2026),
);

ShoppingItem _item(String name, {bool checked = false}) => ShoppingItem(
  name: name,
  quantities: const [(qty: '1', unit: '')],
  category: 'Autres',
  checked: checked,
);

PlannedMeal _meal() => PlannedMeal(
  id: 'm1',
  uid: 'marie',
  recipeId: 'r1',
  recipeTitre: 'Poulet basquaise',
  plannedAt: DateTime(2030, 1, 1, 19),
  durationMinutes: 0,
  createdAt: DateTime(2026),
);

void main() {
  group('PlanningMealTile — « Ajouter aux courses »', () {
    Future<void> pump(WidgetTester tester, Widget tile) =>
        tester.pumpWidget(MaterialApp(home: Scaffold(body: tile)));

    testWidgets('repas en lecture seule : une icône, sans menu', (
      tester,
    ) async {
      var added = false;
      await pump(
        tester,
        PlanningMealTile(
          meal: _meal(),
          isPast: false,
          aiLoading: false,
          isWide: false,
          readOnly: true,
          onAddToShopping: () => added = true,
        ),
      );
      expect(find.byType(PopupMenuButton<PlanningMealAction>), findsNothing);
      await tester.tap(find.byTooltip('Ajouter aux courses'));
      expect(added, isTrue);
    });

    testWidgets('action absente : ni icône ni entrée', (tester) async {
      await pump(
        tester,
        PlanningMealTile(
          meal: _meal(),
          isPast: true,
          aiLoading: false,
          isWide: true,
          readOnly: true,
        ),
      );
      expect(find.byTooltip('Ajouter aux courses'), findsNothing);
    });

    testWidgets('téléphone, repas avec menu : l\'entrée vit dans le menu', (
      tester,
    ) async {
      var added = false;
      await pump(
        tester,
        PlanningMealTile(
          meal: _meal(),
          isPast: false,
          aiLoading: false,
          isWide: false,
          onDelete: () {},
          onAddToShopping: () => added = true,
        ),
      );
      expect(find.byTooltip('Ajouter aux courses'), findsNothing);
      await tester.tap(find.byType(PopupMenuButton<PlanningMealAction>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ajouter aux courses'));
      await tester.pumpAndSettle();
      expect(added, isTrue);
    });

    testWidgets('grand écran : l\'icône est visible sur la tuile', (
      tester,
    ) async {
      await pump(
        tester,
        PlanningMealTile(
          meal: _meal(),
          isPast: false,
          aiLoading: false,
          isWide: true,
          onDelete: () {},
          onAddToShopping: () {},
        ),
      );
      expect(find.byTooltip('Ajouter aux courses'), findsOneWidget);
      // L'icône suffit : le menu ⋮ ne la répète pas.
      await tester.tap(find.byType(PopupMenuButton<PlanningMealAction>));
      await tester.pumpAndSettle();
      expect(find.text('Supprimer'), findsOneWidget);
      expect(find.text('Ajouter aux courses'), findsNothing);
    });
  });

  group('Ajouter / Remplacer, et Mes courses', () {
    late FakeFirebaseFirestore firestore;
    late ShoppingCartRepository repo;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      firestore = FakeFirebaseFirestore();
      repo = ShoppingCartRepository(
        firestore: firestore,
        errorReportService: ErrorReportService(firestore: firestore),
      );
    });

    Future<void> pumpHost(
      WidgetTester tester,
      List<ShoppingItem> incoming, {
      Size size = const Size(400, 800),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appUserProvider.overrideWith((ref) => Stream.value(_user())),
            shoppingCartRepositoryProvider.overrideWithValue(repo),
          ],
          child: MaterialApp(
            home: Scaffold(
              appBar: AppBar(actions: const [ShoppingCartButton()]),
              body: Consumer(
                builder: (context, ref, _) => FilledButton(
                  onPressed: () => addToShoppingList(
                    context,
                    ref,
                    incoming: incoming,
                    summary: '« Poulet basquaise » apporte 1 article.',
                  ),
                  child: const Text('ajouter'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<List<String>> names() async =>
        (await repo.load(_uid)).items.map((i) => i.name).toList();

    testWidgets('panier vide : ajout direct, sans boîte', (tester) async {
      await pumpHost(tester, [_item('Riz')]);
      await tester.tap(find.text('ajouter'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('1 article ajouté aux courses.'), findsOneWidget);
      expect(await names(), ['Riz']);
    });

    testWidgets('panier rempli : la boîte s\'ouvre, « Ajouter » fusionne', (
      tester,
    ) async {
      await repo.restore(_uid, [_item('Ail'), _item('Sel')]);
      await pumpHost(tester, [_item('Riz')]);
      await tester.tap(find.text('ajouter'));
      await tester.pumpAndSettle();
      expect(find.text('Votre liste contient déjà 2 articles'), findsOne);
      expect(
        find.text('« Poulet basquaise » apporte 1 article.'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Ajouter'));
      await tester.pumpAndSettle();
      expect(await names(), ['Ail', 'Sel', 'Riz']);
    });

    testWidgets('« Remplacer », puis « Annuler » rend la liste précédente', (
      tester,
    ) async {
      await repo.restore(_uid, [_item('Ail')]);
      await pumpHost(tester, [_item('Riz')]);
      await tester.tap(find.text('ajouter'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Remplacer'));
      await tester.pumpAndSettle();
      expect(await names(), ['Riz']);
      expect(find.text('Liste remplacée : 1 article.'), findsOneWidget);
      await tester.tap(find.widgetWithText(SnackBarAction, 'Annuler'));
      await tester.pumpAndSettle();
      expect(await names(), ['Ail']);
      expect(find.text('Liste précédente rendue.'), findsOneWidget);
    });

    testWidgets('deux appuis rapides : un seul ajout', (tester) async {
      final slow = _SlowRepo(
        firestore: firestore,
        errorReportService: ErrorReportService(firestore: firestore),
      );
      repo = slow;
      await pumpHost(tester, [_item('Riz')]);
      await tester.tap(find.text('ajouter'));
      await tester.pump();
      await tester.tap(find.text('ajouter'));
      await tester.pump();
      slow.gate.complete();
      await tester.pumpAndSettle();
      final cart = await repo.load(_uid);
      expect(cart.items.single.quantities.single.qty, '1');
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('« Annuler » de la boîte n\'écrit rien', (tester) async {
      await repo.restore(_uid, [_item('Ail')]);
      await pumpHost(tester, [_item('Riz')]);
      await tester.tap(find.text('ajouter'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Annuler'));
      await tester.pumpAndSettle();
      expect(await names(), ['Ail']);
    });

    testWidgets('Mes courses : pastille, sous-titre, case cochée enregistrée', (
      tester,
    ) async {
      await repo.restore(_uid, [_item('Ail'), _item('Riz', checked: true)]);
      await pumpHost(tester, const []);
      // Un article reste à acheter.
      expect(find.text('1'), findsOneWidget);
      await tester.tap(find.byTooltip('Mes courses, 1 à acheter'));
      await tester.pumpAndSettle();
      expect(find.text('Mes courses'), findsOneWidget);
      expect(find.text('2 articles · 1 coché'), findsOneWidget);
      await tester.tap(find.text('1 Ail'));
      await tester.pumpAndSettle();
      expect((await repo.load(_uid)).checkedCount, 2);
    });

    testWidgets('Mes courses vide, sur grand écran : une fenêtre', (
      tester,
    ) async {
      await pumpHost(tester, const [], size: const Size(1200, 900));
      await tester.tap(find.byTooltip('Mes courses'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Votre liste de courses est vide.'), findsOneWidget);
    });

    testWidgets('Vider la liste demande confirmation', (tester) async {
      await repo.restore(_uid, [_item('Ail'), _item('Riz')]);
      await pumpHost(tester, const []);
      await tester.tap(find.byTooltip('Mes courses, 2 à acheter'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Actions de la liste'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Vider la liste'));
      await tester.pumpAndSettle();
      expect(find.text('Vider la liste de courses ?'), findsOneWidget);
      expect(
        find.text('Les 2 articles seront retirés, sur tous vos appareils.'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Vider'));
      await tester.pumpAndSettle();
      expect((await repo.load(_uid)).isEmpty, isTrue);
    });

    testWidgets('Retirer les articles cochés, puis Annuler', (tester) async {
      await repo.restore(_uid, [_item('Ail', checked: true), _item('Riz')]);
      await pumpHost(tester, const []);
      await tester.tap(find.byTooltip('Mes courses, 1 à acheter'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Actions de la liste'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Retirer les articles cochés'));
      await tester.pumpAndSettle();
      expect((await repo.load(_uid)).items.map((i) => i.name), ['Riz']);
      expect(find.text('1 article retiré.'), findsOneWidget);
      await tester.tap(find.widgetWithText(SnackBarAction, 'Annuler'));
      await tester.pumpAndSettle();
      expect((await repo.load(_uid)).items.map((i) => i.name), ['Ail', 'Riz']);
    });

    /// Enregistre les écritures du presse-papiers et répond à url_launcher :
    /// l'un comme l'autre passent par un canal de plateforme que le test
    /// n'a pas.
    List<String> mockClipboardAndLauncher(WidgetTester tester) {
      final copied = <String>[];
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      const launcher = MethodChannel('plugins.flutter.io/url_launcher');
      messenger.setMockMethodCallHandler(launcher, (call) async => true);
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        messenger.setMockMethodCallHandler(launcher, null);
      });
      return copied;
    }

    testWidgets('Copier pour Google Keep : seuls les articles non cochés', (
      tester,
    ) async {
      final copied = mockClipboardAndLauncher(tester);
      await repo.restore(_uid, [
        _item('Ail'),
        _item('Riz', checked: true),
        _item('Sel'),
      ]);
      await pumpHost(tester, const []);
      await tester.tap(find.byTooltip('Mes courses, 2 à acheter'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Seuls les articles non cochés sont copiés. Keep n\'a pas d\'API : '
          'à vous de créer la note, de la convertir en cases à cocher et de '
          'refaire les rayons.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Copier pour Google Keep'));
      await tester.pumpAndSettle();
      expect(copied, hasLength(1));
      expect(copied.single, contains('\t1 Ail'));
      expect(copied.single, contains('\t1 Sel'));
      expect(copied.single, isNot(contains('Riz')));
      expect(
        find.text(
          '2 articles copiés. Dans Keep : créez une nouvelle note et collez.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('Copier pour Google Keep, tout coché : rien à copier', (
      tester,
    ) async {
      final copied = mockClipboardAndLauncher(tester);
      await repo.restore(_uid, [
        _item('Ail', checked: true),
        _item('Riz', checked: true),
      ]);
      await pumpHost(tester, const []);
      await tester.tap(find.byTooltip('Mes courses'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copier pour Google Keep'));
      await tester.pumpAndSettle();
      expect(copied, isEmpty);
      expect(find.text('Tout est déjà coché : rien à copier.'), findsOneWidget);
    });
  });
}
