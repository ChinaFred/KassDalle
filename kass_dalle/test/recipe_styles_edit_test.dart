// Correction à la main du style d'une recette (`tags.styles`).
//
// Trois niveaux : le panneau (dix-huit pastilles, trois au plus, pour tout
// rôle), le formulaire (une pastille touchée pose `styles_manual`) et le
// repository (`validateDraft` écrit `styles` et `styles_manual`, garde
// `styles_checked_at`).
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/features/books/domain/book.dart';
import 'package:kass_dalle/features/books/presentation/book_providers.dart';
import 'package:kass_dalle/features/recipes/domain/meal_role.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';
import 'package:kass_dalle/features/recipes/presentation/edit/recipe_form_mixin.dart';
import 'package:kass_dalle/features/recipes/presentation/edit/recipe_meta_panel.dart';

import 'support/test_backend.dart';

// ── Panneau ─────────────────────────────────────────────────────────────────

class _PanelHost extends StatefulWidget {
  final String? role;
  final List<String> initialStyles;
  final bool saving;
  final void Function(List<String>)? onStyles;

  const _PanelHost({
    this.role = 'plat',
    this.initialStyles = const [],
    this.saving = false,
    this.onStyles,
  });

  @override
  State<_PanelHost> createState() => _PanelHostState();
}

class _PanelHostState extends State<_PanelHost> {
  final _ctrls = List.generate(7, (_) => TextEditingController());
  late List<String> styles = widget.initialStyles;

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
        mealRole: widget.role,
        onMealRoleChanged: (_) {},
        styles: styles,
        onStylesChanged: (v) {
          setState(() => styles = v);
          widget.onStyles?.call(v);
        },
      ),
    );
  }
}

Future<void> _pumpPanel(WidgetTester tester, _PanelHost host) async {
  await tester.binding.setSurfaceSize(const Size(500, 3000));
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

FilterChip _chip(WidgetTester tester, String style) =>
    tester.widget<FilterChip>(
      find.widgetWithText(FilterChip, recipeStyleLabel(style)),
    );

/// Les pastilles du seul bloc « Style » : le panneau en porte d'autres
/// (cuisines, types de plat).
Finder _styleChips() => find.descendant(
  of: find.byKey(const ValueKey('recipeStylesChips')),
  matching: find.byType(FilterChip),
);

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

final _checkedAt = DateTime.utc(2026, 10, 1);

Recipe _burger({RecipeTags? tags}) => Recipe(
  id: 'recipe-1',
  titre: 'Burger maison',
  langue: 'fr',
  rawCooklang: 'Griller.',
  imageUrls: const [],
  reviewStatus: ReviewStatus.validated,
  tags:
      tags ??
      RecipeTags(
        mealRole: 'plat',
        styles: const ['street_food'],
        stylesCheckedAt: _checkedAt,
      ),
  ingredientsIndex: const [],
  createdBy: 'uid-test',
  createdAt: DateTime.utc(2026, 1, 1),
  updatedAt: DateTime.utc(2026, 6, 1),
);

void main() {
  group('panneau : pastilles « Style »', () {
    testWidgets('dix-huit pastilles sous le rôle, avec l\'aide par défaut', (
      tester,
    ) async {
      await _pumpPanel(tester, const _PanelHost());
      expect(_styleChips(), findsNWidgets(kRecipeStyles.length));
      expect(find.text('Style'), findsOneWidget);
      expect(find.text(kStylesHelper), findsOneWidget);
      final role = tester.getTopLeft(find.text('Rôle dans un repas')).dy;
      final style = tester.getTopLeft(find.text('Style')).dy;
      expect(role < style, isTrue);
    });

    for (final role in [null, 'entree', 'dessert', 'snack']) {
      testWidgets('présentes pour le rôle ${role ?? 'non classé'}', (
        tester,
      ) async {
        await _pumpPanel(tester, _PanelHost(role: role));
        expect(_styleChips(), findsNWidgets(kRecipeStyles.length));
      });
    }

    testWidgets('toucher une pastille prévient le parent, dans l\'ordre', (
      tester,
    ) async {
      final calls = <List<String>>[];
      await _pumpPanel(
        tester,
        _PanelHost(initialStyles: const ['barbecue'], onStyles: calls.add),
      );
      await tester.tap(find.widgetWithText(FilterChip, 'Street food'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilterChip, 'Barbecue / plancha'));
      await tester.pump();
      expect(calls, [
        ['street_food', 'barbecue'],
        ['street_food'],
      ]);
    });

    testWidgets('trois au plus : les autres se désactivent, l\'aide le dit', (
      tester,
    ) async {
      await _pumpPanel(
        tester,
        const _PanelHost(initialStyles: ['brunch', 'festif', 'enfants']),
      );
      expect(find.text(kStylesMaxHelper), findsOneWidget);
      expect(find.text(kStylesHelper), findsNothing);
      expect(_chip(tester, 'street_food').onSelected, isNull);
      // Une pastille cochée reste décochable.
      expect(_chip(tester, 'brunch').onSelected, isNotNull);
    });

    testWidgets('une valeur hors vocabulaire reste, sans pastille', (
      tester,
    ) async {
      final calls = <List<String>>[];
      await _pumpPanel(
        tester,
        _PanelHost(initialStyles: const ['ancien_style'], onStyles: calls.add),
      );
      expect(_styleChips(), findsNWidgets(kRecipeStyles.length));
      await tester.tap(find.widgetWithText(FilterChip, 'Brunch'));
      await tester.pump();
      expect(calls.single, ['brunch', 'ancien_style']);
    });

    testWidgets('désactivées pendant l\'enregistrement', (tester) async {
      await _pumpPanel(tester, const _PanelHost(saving: true));
      expect(_chip(tester, 'brunch').onSelected, isNull);
    });
  });

  group('formulaire : style', () {
    testWidgets('sans retouche, le style et le marqueur de la base', (
      tester,
    ) async {
      final recipe = _burger();
      final form = await _pumpForm(tester, recipe);
      expect(form.stylesManual, isFalse);
      final tags = form.buildTagsFromForm(recipe.tags);
      expect(tags.styles, ['street_food']);
      expect(tags.stylesManual, isFalse);
      expect(tags.stylesCheckedAt, _checkedAt);
    });

    testWidgets('une pastille touchée pose la correction à la main', (
      tester,
    ) async {
      final recipe = _burger();
      final form = await _pumpForm(tester, recipe);
      form.setStyles(['barbecue', 'street_food']);
      final tags = form.buildTagsFromForm(recipe.tags);
      expect(tags.styles, ['street_food', 'barbecue']);
      expect(tags.stylesManual, isTrue);
      expect(tags.toMap()['styles_manual'], isTrue);
    });

    testWidgets('tout décocher à la main : liste vide gardée', (tester) async {
      final recipe = _burger();
      final form = await _pumpForm(tester, recipe);
      form.setStyles(const []);
      final map = form.buildTagsFromForm(recipe.tags).toMap();
      expect(map['styles'], isEmpty);
      expect(map['styles_manual'], isTrue);
    });

    testWidgets('une correction de la base est relue comme telle', (
      tester,
    ) async {
      final recipe = _burger(
        tags: const RecipeTags(
          mealRole: 'plat',
          styles: ['terroir'],
          stylesManual: true,
        ),
      );
      final form = await _pumpForm(tester, recipe);
      expect(form.stylesManual, isTrue);
      expect(form.selectedStyles, ['terroir']);
    });

    testWidgets('Non classé garde le style', (tester) async {
      final recipe = _burger();
      final form = await _pumpForm(tester, recipe);
      form.setMealRole(null);
      final tags = form.buildTagsFromForm(recipe.tags);
      expect(tags.mealRole, isNull);
      expect(tags.styles, ['street_food']);
      expect(tags.stylesCheckedAt, _checkedAt);
    });
  });

  group('repository : validateDraft', () {
    Future<Map<String, dynamic>> validate(
      TestBackend backend,
      RecipeTags tags,
    ) async {
      await backend.recipes.validateDraft(
        recipeId: 'recipe-1',
        editedCooklang: 'Griller.',
        titre: 'Burger maison',
        callerUid: 'uid-test',
        tagsOverride: tags,
      );
      final snap = await backend.firestore
          .collection('recipes')
          .doc('recipe-1')
          .get();
      return Map<String, dynamic>.from(snap.data()!['tags'] as Map);
    }

    test('une correction à la main écrit styles et styles_manual', () async {
      final backend = TestBackend();
      await backend.seedRecipe(_burger());
      final tags = await validate(
        backend,
        _burger().tags.copyWith(
          styles: ['street_food', 'barbecue'],
          stylesManual: true,
        ),
      );
      expect(tags['styles'], ['street_food', 'barbecue']);
      expect(tags['styles_manual'], isTrue);
      expect(tags['styles_checked_at'], isA<Timestamp>());
    });

    test(
      'un style inconnu du formulaire n\'efface pas celui de la base',
      () async {
        final backend = TestBackend();
        await backend.seedRecipe(_burger());
        final tags = await validate(
          backend,
          const RecipeTags(mealRole: 'plat'),
        );
        expect(tags['styles'], ['street_food']);
        expect(tags['styles_checked_at'], isA<Timestamp>());
        expect(tags.containsKey('styles_manual'), isFalse);
      },
    );
  });
}
