// Correction à la main de la protéine et du féculent d'une recette.
//
// Trois niveaux : le panneau (listes visibles pour un plat ou un
// accompagnement seulement), le formulaire (`buildTagsFromForm` : « Non
// renseigné » et changement de rôle) et le repository (`validateDraft` efface
// champ par champ ce que le formulaire retire).
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/features/books/domain/book.dart';
import 'package:kass_dalle/features/books/presentation/book_providers.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/presentation/edit/recipe_form_mixin.dart';
import 'package:kass_dalle/features/recipes/presentation/edit/recipe_meta_panel.dart';

import 'support/test_backend.dart';

// ── Panneau ─────────────────────────────────────────────────────────────────

class _PanelHost extends StatefulWidget {
  final String? initialRole;
  final String? initialProtein;
  final bool saving;
  final void Function(String?)? onProtein;

  const _PanelHost({
    this.initialRole,
    this.initialProtein,
    this.saving = false,
    this.onProtein,
  });

  @override
  State<_PanelHost> createState() => _PanelHostState();
}

class _PanelHostState extends State<_PanelHost> {
  final _ctrls = List.generate(7, (_) => TextEditingController());
  late String? role = widget.initialRole;
  late String? protein = widget.initialProtein;
  String? starch;

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: RecipeMetaPanel(
        titleCtrl: _ctrls[0],
        portionsCtrl: _ctrls[1],
        difficultyCtrl: _ctrls[2],
        prepTimeCtrl: _ctrls[3],
        cookTimeCtrl: _ctrls[4],
        restTimeCtrl: _ctrls[5],
        pageNumberCtrl: _ctrls[6],
        saving: widget.saving,
        selectedBookId: null,
        onBookChanged: (_, _) {},
        showBookSelector: false,
        cuisines: const [],
        onCuisinesChanged: (_) {},
        dishTypes: const [],
        onDishTypesChanged: (_) {},
        mealRole: role,
        onMealRoleChanged: (v) => setState(() => role = v),
        mainProtein: protein,
        onMainProteinChanged: (v) {
          setState(() => protein = v);
          widget.onProtein?.call(v);
        },
        mainStarch: starch,
        onMainStarchChanged: (v) => setState(() => starch = v),
      ),
    );
  }
}

Future<void> _pumpPanel(WidgetTester tester, _PanelHost host) async {
  await tester.binding.setSurfaceSize(const Size(500, 2400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        targetBooksProvider.overrideWithValue(const AsyncValue.data(<Book>[])),
      ],
      child: MaterialApp(home: Scaffold(body: host)),
    ),
  );
  await tester.pump();
}

const _protein = ValueKey('mainProteinDropdown');
const _starch = ValueKey('mainStarchDropdown');

// ── Formulaire ──────────────────────────────────────────────────────────────

class _FormHost extends ConsumerStatefulWidget {
  final Recipe recipe;
  const _FormHost(this.recipe);

  @override
  ConsumerState<_FormHost> createState() => _FormHostState();
}

class _FormHostState extends ConsumerState<_FormHost>
    with RecipeFormMixin<_FormHost> {
  @override
  void initState() {
    super.initState();
    initFormFromRecipe(widget.recipe);
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Future<_FormHostState> _pumpForm(WidgetTester tester, Recipe recipe) async {
  await tester.pumpWidget(
    ProviderScope(child: MaterialApp(home: _FormHost(recipe))),
  );
  return tester.state<_FormHostState>(find.byType(_FormHost));
}

final _checkedAt = DateTime.utc(2026, 9, 1);

Recipe _plat({String role = 'plat'}) => Recipe(
  id: 'recipe-1',
  titre: 'Hachis parmentier',
  langue: 'fr',
  rawCooklang: 'Mélanger.',
  imageUrls: const [],
  reviewStatus: ReviewStatus.validated,
  tags: RecipeTags(
    mealRole: role,
    contains: const ['proteine', 'feculent'],
    mainProtein: 'boeuf',
    mainStarch: 'pommes_de_terre',
    mainIngredientsCheckedAt: _checkedAt,
  ),
  ingredientsIndex: const [],
  createdBy: 'uid-test',
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 6, 1),
);

void main() {
  group('panneau : listes protéine et féculent', () {
    testWidgets('visibles pour un plat, sous le rôle, avec leur aide', (
      tester,
    ) async {
      await _pumpPanel(tester, const _PanelHost(initialRole: 'plat'));
      expect(find.byKey(_protein), findsOneWidget);
      expect(find.byKey(_starch), findsOneWidget);
      expect(find.text('Protéine principale'), findsOneWidget);
      expect(find.text('Féculent principal'), findsOneWidget);
      expect(find.text(kMainIngredientHelper), findsNWidgets(2));
      expect(find.text('Non renseigné'), findsNWidgets(2));
      // Ordre : Rôle, Protéine, Féculent, Cuisine.
      final role = tester.getTopLeft(find.text('Rôle dans un repas')).dy;
      final prot = tester.getTopLeft(find.byKey(_protein)).dy;
      final starch = tester.getTopLeft(find.byKey(_starch)).dy;
      final cuisine = tester.getTopLeft(find.text('Cuisine')).dy;
      expect(role < prot && prot < starch && starch < cuisine, isTrue);
    });

    testWidgets('visibles pour un accompagnement', (tester) async {
      await _pumpPanel(tester, const _PanelHost(initialRole: 'accompagnement'));
      expect(find.byKey(_protein), findsOneWidget);
      expect(find.byKey(_starch), findsOneWidget);
    });

    for (final role in [null, 'entree', 'dessert', 'snack']) {
      testWidgets('absentes pour le rôle ${role ?? 'non classé'}', (
        tester,
      ) async {
        await _pumpPanel(tester, _PanelHost(initialRole: role));
        expect(find.byKey(_protein), findsNothing);
        expect(find.byKey(_starch), findsNothing);
      });
    }

    testWidgets('disparaissent quand le rôle passe à Dessert', (tester) async {
      await _pumpPanel(tester, const _PanelHost(initialRole: 'plat'));
      await tester.tap(find.text('Plat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dessert').last);
      await tester.pumpAndSettle();
      expect(find.byKey(_protein), findsNothing);
      expect(find.byKey(_starch), findsNothing);
    });

    testWidgets('un choix prévient le parent ; Non renseigné rend null', (
      tester,
    ) async {
      final calls = <String?>[];
      await _pumpPanel(
        tester,
        _PanelHost(
          initialRole: 'plat',
          initialProtein: 'boeuf',
          onProtein: calls.add,
        ),
      );
      expect(find.text('Bœuf'), findsOneWidget);
      await tester.tap(find.text('Bœuf'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Volaille').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Volaille'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Non renseigné').last);
      await tester.pumpAndSettle();
      expect(calls, ['volaille', null]);
    });

    testWidgets('une valeur hors liste reste affichée', (tester) async {
      await _pumpPanel(
        tester,
        const _PanelHost(initialRole: 'plat', initialProtein: 'veau'),
      );
      expect(find.text('veau'), findsOneWidget);
    });

    testWidgets('désactivées pendant l\'enregistrement', (tester) async {
      await _pumpPanel(
        tester,
        const _PanelHost(initialRole: 'plat', saving: true),
      );
      final field = tester.widget<DropdownButton<String>>(
        find.descendant(
          of: find.byKey(_protein),
          matching: find.byType(DropdownButton<String>),
        ),
      );
      expect(field.onChanged, isNull);
    });
  });

  group('formulaire : buildTagsFromForm', () {
    testWidgets('sans retouche, les valeurs et le marqueur de la base', (
      tester,
    ) async {
      final recipe = _plat();
      final form = await _pumpForm(tester, recipe);
      final tags = form.buildTagsFromForm(recipe.tags);
      expect(tags.mainProtein, 'boeuf');
      expect(tags.mainStarch, 'pommes_de_terre');
      expect(tags.mainIngredientsCheckedAt, _checkedAt);
    });

    testWidgets('un choix à la main remplace la valeur et pose le marqueur', (
      tester,
    ) async {
      final recipe = _plat();
      final form = await _pumpForm(tester, recipe);
      form.setMainProtein('agneau');
      final tags = form.buildTagsFromForm(recipe.tags);
      expect(tags.mainProtein, 'agneau');
      expect(tags.mainStarch, 'pommes_de_terre');
      expect(tags.mainIngredientsCheckedAt, isNotNull);
      expect(tags.mainIngredientsCheckedAt, isNot(_checkedAt));
    });

    testWidgets('Non renseigné retire le champ et le marqueur', (tester) async {
      final recipe = _plat();
      final form = await _pumpForm(tester, recipe);
      form.setMainStarch(null);
      final tags = form.buildTagsFromForm(recipe.tags);
      expect(tags.mainProtein, 'boeuf');
      expect(tags.mainStarch, isNull);
      expect(tags.mainIngredientsCheckedAt, isNull);
      final map = tags.toMap();
      expect(map.containsKey('main_starch'), isFalse);
      expect(map.containsKey('main_ingredients_checked_at'), isFalse);
      expect(map['main_protein'], 'boeuf');
    });

    testWidgets('passer à Dessert retire les deux champs et le marqueur', (
      tester,
    ) async {
      final recipe = _plat();
      final form = await _pumpForm(tester, recipe);
      form.setMealRole('dessert');
      final tags = form.buildTagsFromForm(recipe.tags);
      expect(tags.mealRole, 'dessert');
      expect(tags.mainProtein, isNull);
      expect(tags.mainStarch, isNull);
      expect(tags.mainIngredientsCheckedAt, isNull);
    });

    testWidgets('revenir à Plat dans la session retrouve les valeurs', (
      tester,
    ) async {
      final recipe = _plat();
      final form = await _pumpForm(tester, recipe);
      form.setMealRole('entree');
      form.setMealRole('accompagnement');
      final tags = form.buildTagsFromForm(recipe.tags);
      expect(tags.mainProtein, 'boeuf');
      expect(tags.mainStarch, 'pommes_de_terre');
    });

    testWidgets('Non classé retire tout', (tester) async {
      final recipe = _plat();
      final form = await _pumpForm(tester, recipe);
      form.setMealRole(null);
      final tags = form.buildTagsFromForm(recipe.tags);
      expect(tags.mealRole, isNull);
      expect(tags.mainProtein, isNull);
      expect(tags.mainStarch, isNull);
    });

    testWidgets('une valeur restée d\'un ancien rôle n\'est pas reprise', (
      tester,
    ) async {
      final recipe = _plat(role: 'dessert');
      final form = await _pumpForm(tester, recipe);
      expect(form.selectedMainProtein, isNull);
      expect(form.selectedMainStarch, isNull);
      form.setMealRole('plat');
      final tags = form.buildTagsFromForm(recipe.tags);
      expect(tags.mainProtein, isNull);
      expect(tags.mainIngredientsCheckedAt, isNull);
    });
  });

  group('repository : validateDraft', () {
    Future<Map<String, dynamic>> validate(
      TestBackend backend,
      RecipeTags tags, {
      bool fromForm = true,
    }) async {
      await backend.recipes.validateDraft(
        recipeId: 'recipe-1',
        editedCooklang: 'Mélanger.',
        titre: 'Hachis parmentier',
        callerUid: 'uid-test',
        tagsOverride: tags,
        mainIngredientsFromForm: fromForm,
      );
      final snap = await backend.firestore
          .collection('recipes')
          .doc('recipe-1')
          .get();
      return Map<String, dynamic>.from(snap.data()!['tags'] as Map);
    }

    test('Non renseigné efface le champ et le marqueur en base', () async {
      final backend = TestBackend();
      await backend.seedRecipe(_plat());
      final tags = await validate(
        backend,
        _plat().tags.withMainIngredients(mainProtein: 'boeuf'),
      );
      expect(tags['main_protein'], 'boeuf');
      expect(tags.containsKey('main_starch'), isFalse);
      expect(tags.containsKey('main_ingredients_checked_at'), isFalse);
    });

    test('un choix à la main remplace la valeur de la base', () async {
      final backend = TestBackend();
      await backend.seedRecipe(_plat());
      final tags = await validate(
        backend,
        _plat().tags.withMainIngredients(
          mainProtein: 'porc',
          mainStarch: 'riz',
          mainIngredientsCheckedAt: DateTime.utc(2026, 10, 10),
        ),
      );
      expect(tags['main_protein'], 'porc');
      expect(tags['main_starch'], 'riz');
      expect(tags['main_ingredients_checked_at'], isA<Timestamp>());
    });

    test('un rôle sans protéine les efface, même en lot', () async {
      final backend = TestBackend();
      await backend.seedRecipe(_plat());
      final tags = await validate(
        backend,
        _plat(role: 'dessert').tags,
        fromForm: false,
      );
      expect(tags['meal_role'], 'dessert');
      expect(tags.containsKey('main_protein'), isFalse);
      expect(tags.containsKey('main_starch'), isFalse);
      expect(tags.containsKey('main_ingredients_checked_at'), isFalse);
    });

    test('en lot, un champ absent des tags relus reste en base', () async {
      final backend = TestBackend();
      await backend.seedRecipe(_plat());
      final tags = await validate(
        backend,
        const RecipeTags(mealRole: 'plat'),
        fromForm: false,
      );
      expect(tags['main_protein'], 'boeuf');
      expect(tags['main_starch'], 'pommes_de_terre');
      expect(tags['main_ingredients_checked_at'], isA<Timestamp>());
    });
  });
}
