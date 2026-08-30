import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/recipe_pdf_export.dart';
import 'package:kass_dalle/features/annotations/domain/annotation.dart';
import 'package:kass_dalle/features/recipes/domain/nutrition_contributions.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Ce que l'export emporte en plus de la méthode : photos, annotations, note.
///
/// Deux dangers ici, et aucun ne se voit à la relecture du code. Le premier est
/// la mise en page : l'étoile de la note est une forme vectorielle, et une
/// forme mal contrainte lève à la composition — le fichier n'existe alors
/// jamais. Le second est le tri : une annotation qui traverse alors que
/// l'utilisateur l'a décochée est une confidence imprimée sans son accord.
void main() {
  Recipe recette({
    List<String> imageUrls = const [],
    RecipeNutritionSnapshot? nutrition,
  }) => Recipe(
    id: 'r1',
    titre: 'Gravlax de saumon',
    langue: 'fr',
    rawCooklang:
        '>> titre: Gravlax de saumon\n'
        '>> portions: 8\n\n'
        'Mélanger le @sel{200%g} et le @sucre{150%g}.\n'
        'Réserver ~{12%heures} au frais.',
    imageUrls: imageUrls,
    reviewStatus: ReviewStatus.validated,
    tags: const RecipeTags(),
    ingredientsIndex: const ['sel', 'sucre'],
    createdBy: 'u1',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
    ingredients: const [
      RecipeIngredient(name: 'sel', qty: '200', unit: 'g'),
      RecipeIngredient(name: 'sucre', qty: '150', unit: 'g'),
    ],
    nutrition: nutrition,
  );

  RecipeNutritionSnapshot bloc({
    Map<String, double>? per100g = const {'kcal': 180, 'protein_g': 4.2},
    List<String> warnings = const [],
  }) => RecipeNutritionSnapshot(
    selectedPortions: 8,
    totalWeightG: 350,
    coverage: 0.92,
    coverageState: 'full',
    totals: const {'kcal': 1400, 'protein_g': 12.5, 'salt_g': 78.0},
    perPortion: const {'kcal': 175, 'protein_g': 1.6, 'salt_g': 9.8},
    per100g: per100g,
    quality: RecipeNutritionQuality(score: 84, level: 'A', warnings: warnings),
  );

  NutritionContributionTable contributions({RecipeAbsorbedOil? absorbedOil}) =>
      NutritionContributionTable(
        rows: const [
          NutritionContributionRow(
            ingredient: RecipeIngredient(name: 'sel', qty: '200', unit: 'g'),
            canonicalId: 'sel',
            weightGrams: 200,
            perIngredient: {'kcal': 0, 'salt_g': 78.0},
          ),
          NutritionContributionRow(
            ingredient: RecipeIngredient(name: 'sucre', qty: '150', unit: 'g'),
            canonicalId: 'sucre',
            weightGrams: 150,
            perIngredient: {'kcal': 600, 'carbs_g': 150},
          ),
          // Sans poids ni valeurs : la ligne doit sortir imprimée quand même.
          NutritionContributionRow(
            ingredient: RecipeIngredient(
              name: 'aneth',
              qty: '1',
              unit: 'botte',
            ),
            canonicalId: 'aneth',
          ),
          NutritionContributionRow(
            ingredient: RecipeIngredient(
              name: 'huile de friture',
              qty: '1000',
              unit: 'g',
            ),
            canonicalId: 'huile_de_friture',
            weightGrams: 1000,
            notConsumed: true,
            perIngredient: {'kcal': 8840, 'fat_g': 1000},
          ),
        ],
        absorbedOil: absorbedOil,
      );

  Annotation annotation(AnnotationType type, String text) => Annotation(
    id: '${type.name}-1',
    recipeId: 'r1',
    uid: 'u1',
    authorName: 'Fred',
    text: text,
    type: type,
    createdAt: DateTime(2026, 1, 2),
  );

  final lesTrois = [
    annotation(AnnotationType.note, 'Trop salé pour moi.'),
    annotation(AnnotationType.tip, 'Poser une planche dessus.'),
    annotation(AnnotationType.correction, 'Il manque l\'aneth.'),
  ];

  group('le document se compose', () {
    test(
      'avec la note du lecteur et les trois sortes d\'annotations',
      () async {
        final bytes = await buildRecipePdfBytes(
          recette(),
          annotations: lesTrois,
          userRating: 8,
        );
        expect(bytes.length, greaterThan(1000));
        // %PDF- : le fichier est bien un PDF, pas un tampon vide.
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      },
    );

    test(
      'sans note ni annotation — le cas de la recette toute neuve',
      () async {
        final bytes = await buildRecipePdfBytes(recette());
        expect(bytes.length, greaterThan(1000));
      },
    );

    test('une note de 10 tient dans son badge', () async {
      // Deux chiffres au lieu d'un : la largeur du badge n'est pas figée, et
      // une contrainte trop serrée n'aurait cassé que sur cette note-là.
      final bytes = await buildRecipePdfBytes(recette(), userRating: 10);
      expect(bytes.length, greaterThan(1000));
    });

    test('avec la seule synthèse nutritionnelle', () async {
      final bytes = await buildRecipePdfBytes(
        recette(),
        nutrition: PdfNutritionBlock(
          snapshot: bloc(warnings: const ['Calories recalculées : -8 %']),
          displayedPortions: 4,
        ),
      );
      expect(bytes.length, greaterThan(1000));
    });

    test('sans la vue pour 100 g, la colonne disparaît', () async {
      // Calcul partiel : la vue pour 100 g rapporterait les valeurs d'une
      // partie de la recette au poids du tout. Le tableau passe à trois
      // colonnes — c'est la mise en page qui change, pas seulement un chiffre.
      final bytes = await buildRecipePdfBytes(
        recette(),
        nutrition: PdfNutritionBlock(snapshot: bloc(per100g: null)),
      );
      expect(bytes.length, greaterThan(1000));
    });

    test('avec le détail par ingrédient et son huile absorbée', () async {
      // Dix colonnes sur une A4 portrait, une ligne sans valeur, une ligne
      // hors total et une ligne dérivée qui n'existe pas dans la recette : la
      // composition lève sur une contrainte trop serrée, et le fichier
      // n'existe alors jamais.
      final bytes = await buildRecipePdfBytes(
        recette(),
        nutrition: PdfNutritionBlock(
          snapshot: bloc(),
          displayedPortions: 8,
          contributions: contributions(
            absorbedOil: const RecipeAbsorbedOil(
              grams: 82,
              absorptionRatio: 0.1,
              friedWeightG: 820,
              sourceName: 'huile de friture',
              capped: false,
              contribution: {'kcal': 725, 'fat_g': 82},
            ),
          ),
        ),
      );
      expect(bytes.length, greaterThan(1000));
    });
  });

  group('ce que le dialogue compte', () {
    test('les photos et chaque sorte d\'annotation, séparément', () {
      final counts = PdfExtraCounts.of(
        recette(imageUrls: const ['a', 'b']),
        lesTrois,
      );
      expect(counts.images, 2);
      expect(counts.notes, 1);
      expect(counts.tips, 1);
      expect(counts.corrections, 1);
      expect(counts.hasAny, isTrue);
    });

    test('une recette nue n\'a rien à proposer', () {
      final counts = PdfExtraCounts.of(recette(), const []);
      expect(counts.hasAny, isFalse);
      expect(counts.nutrition, isFalse);
      expect(counts.hasNutritionDetails, isFalse);
    });

    test('un calcul nutritionnel ouvre à lui seul le dialogue', () {
      final counts = PdfExtraCounts.of(recette(nutrition: bloc()), const []);
      expect(counts.nutrition, isTrue);
      expect(counts.hasAny, isTrue);
      // Deux ingrédients : le détail par ingrédient a de quoi se remplir.
      expect(counts.hasNutritionDetails, isTrue);
    });
  });

  group('la phrase du dialogue', () {
    String phrase({
      int images = 0,
      int notes = 0,
      int tips = 0,
      int corrections = 0,
      bool nutrition = false,
    }) => pdfExtrasSentence(
      PdfExtraCounts(
        images: images,
        notes: notes,
        tips: tips,
        corrections: corrections,
        nutrition: nutrition,
      ),
    );

    test('un seul élément ne prend ni virgule ni « et »', () {
      expect(phrase(images: 1), 'Cette recette contient 1 photo.');
    });

    test('deux éléments sont liés par « et », sans virgule', () {
      expect(
        phrase(images: 2, tips: 1),
        'Cette recette contient 2 photos et 1 astuce.',
      );
    });

    test('trois éléments : virgules, puis « et » devant le dernier', () {
      expect(
        phrase(images: 1, tips: 2, corrections: 1),
        'Cette recette contient 1 photo, 2 astuces et 1 correction.',
      );
    });

    test('la nutrition ne se compte pas et ferme l\'énumération', () {
      expect(
        phrase(images: 1, nutrition: true),
        'Cette recette contient 1 photo et des valeurs nutritionnelles.',
      );
    });

    test('seule, elle se dit sans virgule ni « et »', () {
      expect(
        phrase(nutrition: true),
        'Cette recette contient des valeurs nutritionnelles.',
      );
    });
  });

  group('le tri des annotations', () {
    test('chaque sorte suit sa propre case', () {
      const choix = PdfExportChoice(
        images: false,
        notes: true,
        tips: false,
        corrections: true,
      );
      final retenues = lesTrois.where((a) => choix.keeps(a.type)).toList();
      expect(retenues.map((a) => a.type), [
        AnnotationType.note,
        AnnotationType.correction,
      ]);
    });

    test('tout décoché ne laisse rien passer', () {
      expect(
        lesTrois.where((a) => PdfExportChoice.rien.keeps(a.type)),
        isEmpty,
      );
    });
  });

  group('le détail par ingrédient suit la synthèse', () {
    test('coché avec elle, il part', () {
      const choix = PdfExportChoice(
        images: false,
        notes: false,
        tips: false,
        corrections: false,
        nutrition: true,
        nutritionDetails: true,
      );
      expect(choix.wantsNutritionDetails, isTrue);
    });

    test('un réglage mémorisé ne le fait pas partir sans elle', () {
      // Le cas réel : le détail coché à un export précédent, la nutrition
      // décochée à celui-ci. Un tableau d'apports sans le total qu'il alimente
      // n'aurait rien à quoi se rapporter.
      const choix = PdfExportChoice(
        images: false,
        notes: false,
        tips: false,
        corrections: false,
        nutrition: false,
        nutritionDetails: true,
      );
      expect(choix.wantsNutritionDetails, isFalse);
    });
  });
}
