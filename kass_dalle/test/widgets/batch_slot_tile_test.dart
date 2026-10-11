import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kass_dalle/features/planning/domain/planning_preferences.dart';
import 'package:kass_dalle/features/planning/presentation/batch_planning_widgets.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// La carte d'un créneau de « Nouveau planning ».
///
/// Ce que ces tests verrouillent : les détails d'un créneau sont repliés
/// quand il n'y a rien à signaler, dépliés quand il porte un avertissement,
/// et les actions secondaires vivent dans le menu ⋮.
Recipe _recette() => Recipe(
  id: 'r1',
  titre: 'Blanquette de veau',
  langue: 'fr',
  rawCooklang: 'Cuire.',
  imageUrls: const [],
  reviewStatus: ReviewStatus.validated,
  tags: const RecipeTags(prepTime: 20, cookTime: 90),
  ingredientsIndex: const [],
  createdBy: 'uid',
  createdAt: DateTime(2026, 8, 20),
  updatedAt: DateTime(2026, 8, 20),
);

void main() {
  setUpAll(() => initializeDateFormatting('fr', null));

  final date = DateTime(2026, 10, 16);

  Future<void> pump(
    WidgetTester tester, {
    Recipe? recipe,
    DayConstraint constraint = const DayConstraint(),
    DateTime? prepDate,
    VoidCallback? onAssign,
    VoidCallback? onRemove,
    VoidCallback? onDelete,
    VoidCallback? onExport,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BatchSlotTile(
              index: 0,
              date: date,
              recipe: recipe,
              slotTime: const TimeOfDay(hour: 19, minute: 0),
              isGenerating: false,
              dayConstraint: constraint,
              isBatchDay: false,
              prepDate: prepDate,
              onAssign: onAssign ?? () {},
              onRemove: onRemove ?? () {},
              onDelete: onDelete ?? () {},
              onTimeChanged: (_) {},
              onMaxPrepChanged: (_) {},
              onTargetPortionsChanged: (_) {},
              onReheatChanged: (_) {},
              onNotesChanged: (_) {},
              onFormatChanged: (_) {},
              onGenerateWithAI: () {},
              onExportToCalendar: recipe != null ? (onExport ?? () {}) : null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('sans avertissement, les détails sont repliés', (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, recipe: _recette());

    expect(find.text('Blanquette de veau'), findsOneWidget);
    expect(find.text('Détails'), findsOneWidget);
    // L'éditeur des contraintes du jour vit dans le pli.
    expect(find.byType(SlotConstraintsEditor), findsNothing);
    expect(
      find.bySemanticsLabel('Détails du repas du vendredi 16, replié'),
      findsOneWidget,
    );

    await tester.tap(find.text('Détails'));
    await tester.pumpAndSettle();
    expect(find.byType(SlotConstraintsEditor), findsOneWidget);
    expect(
      find.bySemanticsLabel('Détails du repas du vendredi 16, déplié'),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('avec un avertissement, les détails sont dépliés', (
    tester,
  ) async {
    await pump(
      tester,
      recipe: _recette(),
      constraint: const DayConstraint(mealFormat: MealFormat.entreePlat),
    );

    // L'avertissement reste visible sur la carte, et le pli est ouvert.
    expect(find.text('Entrée : à choisir'), findsOneWidget);
    expect(find.byType(SlotConstraintsEditor), findsOneWidget);
  });

  testWidgets('un plat à préparer un autre jour ouvre les détails', (
    tester,
  ) async {
    await pump(tester, recipe: _recette(), prepDate: DateTime(2026, 10, 14));

    expect(find.textContaining('À préparer le'), findsOneWidget);
    expect(find.byType(SlotConstraintsEditor), findsOneWidget);
  });

  testWidgets('la ligne de résumé dit les parts, la durée et le maximum', (
    tester,
  ) async {
    await pump(
      tester,
      recipe: _recette(),
      constraint: const DayConstraint(targetPortions: 4, maxPrepMinutes: 45),
    );

    expect(find.text('4 parts · 110 min · 45 min max'), findsOneWidget);
    // Ni « Redimensionnée : non » ni « Réchauffage: non ».
    expect(find.textContaining('Redimensionnée'), findsNothing);
    expect(find.textContaining('Réchauffage: non'), findsNothing);
  });

  testWidgets('le menu ⋮ porte les quatre actions du créneau', (tester) async {
    var assigned = 0;
    var deleted = 0;
    await pump(
      tester,
      recipe: _recette(),
      onAssign: () => assigned++,
      onDelete: () => deleted++,
    );

    await tester.tap(find.byTooltip('Plus d\'actions'));
    await tester.pumpAndSettle();
    expect(find.text('Changer de recette'), findsOneWidget);
    expect(find.text('Ajouter au calendrier et au planning'), findsOneWidget);
    expect(find.text('Retirer la recette'), findsOneWidget);
    expect(find.text('Supprimer ce jour'), findsOneWidget);

    await tester.tap(find.text('Changer de recette'));
    await tester.pumpAndSettle();
    expect(assigned, 1);

    await tester.tap(find.byTooltip('Plus d\'actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Supprimer ce jour'));
    await tester.pumpAndSettle();
    expect(deleted, 1);
  });

  testWidgets('« Autre suggestion » et l\'heure restent visibles', (
    tester,
  ) async {
    await pump(tester, recipe: _recette());

    expect(find.byTooltip('Autre suggestion'), findsOneWidget);
    expect(find.byTooltip('Changer l\'heure du repas'), findsOneWidget);
    expect(find.text('19:00'), findsOneWidget);
    // Le bouton de l'heure est une vraie cible tactile.
    final button = find.ancestor(
      of: find.text('19:00'),
      matching: find.byType(TextButton),
    );
    expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
  });

  testWidgets('un créneau vide propose « Choisir une recette »', (
    tester,
  ) async {
    var assigned = 0;
    await pump(tester, onAssign: () => assigned++);

    expect(find.text('À assigner'), findsOneWidget);
    await tester.tap(
      find.widgetWithText(OutlinedButton, 'Choisir une recette'),
    );
    expect(assigned, 1);
  });
}
