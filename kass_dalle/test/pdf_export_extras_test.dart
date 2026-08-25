import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/recipe_pdf_export.dart';
import 'package:kass_dalle/features/annotations/domain/annotation.dart';
import 'package:kass_dalle/features/recipes/domain/recipe.dart';

/// Ce que l'export emporte en plus de la méthode : photos, annotations, note.
///
/// Deux dangers ici, et aucun ne se voit à la relecture du code. Le premier est
/// la mise en page : l'étoile de la note est une forme vectorielle, et une
/// forme mal contrainte lève à la composition — le fichier n'existe alors
/// jamais. Le second est le tri : une annotation qui traverse alors que
/// l'utilisateur l'a décochée est une confidence imprimée sans son accord.
void main() {
  Recipe recette({List<String> imageUrls = const []}) => Recipe(
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
    });
  });

  group('la phrase du dialogue', () {
    String phrase({
      int images = 0,
      int notes = 0,
      int tips = 0,
      int corrections = 0,
    }) => pdfExtrasSentence(
      PdfExtraCounts(
        images: images,
        notes: notes,
        tips: tips,
        corrections: corrections,
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
}
