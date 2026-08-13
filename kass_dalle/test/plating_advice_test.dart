import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/plating_advice.dart';

/// L'enchaînement des visuels de montage.
///
/// Chaque image est produite à partir de la précédente. Cette règle gouverne
/// toute l'interface : ce qu'on peut lancer, ce qu'on peut refaire, et ce qu'il
/// faut effacer pour repartir. Elle est vérifiée ici plutôt que dans l'écran,
/// où elle serait invisible.

PlatingAdvice _advice(List<String?> urls) {
  return PlatingAdvice(
    complexite: PlatingComplexity.complexe,
    resume: '',
    contenant: '',
    etapes: [
      for (var i = 0; i < urls.length; i++)
        PlatingStep(titre: 'Étape $i', geste: 'Geste $i', imageUrl: urls[i]),
    ],
    pieges: const [],
    derniereMinute: const [],
  );
}

void main() {
  group('missingImageIndexesUpTo', () {
    test('illustrer la 3e sans les précédentes demande les trois', () {
      expect(_advice([null, null, null]).missingImageIndexesUpTo(2), [0, 1, 2]);
    });

    test('les étapes déjà illustrées ne sont pas refaites', () {
      final advice = _advice(['https://x/0.jpg', null, null]);
      expect(advice.missingImageIndexesUpTo(2), [1, 2]);
    });

    test('un trou au milieu est comblé', () {
      // Peut arriver après un échec en cours de série : la reprise doit
      // repasser par l'étape manquante, sinon la suivante naîtrait d'un vide.
      final advice = _advice(['https://x/0.jpg', null, 'https://x/2.jpg']);
      expect(advice.missingImageIndexesUpTo(2), [1]);
    });

    test('une étape déjà illustrée ne demande rien', () {
      expect(_advice(['https://x/0.jpg']).missingImageIndexesUpTo(0), isEmpty);
    });

    test('un index hors bornes ne demande rien', () {
      final advice = _advice([null, null]);
      expect(advice.missingImageIndexesUpTo(5), isEmpty);
      expect(advice.missingImageIndexesUpTo(-1), isEmpty);
    });
  });

  group('lastIllustratedIndex', () {
    test('sans visuel, il n\'y a rien à refaire', () {
      expect(_advice([null, null]).lastIllustratedIndex, -1);
      expect(_advice([null, null]).hasImages, isFalse);
    });

    test('le dernier visuel produit est le seul à pouvoir être refait', () {
      final advice = _advice(['https://x/0.jpg', 'https://x/1.jpg', null]);
      expect(advice.lastIllustratedIndex, 1);
      expect(advice.hasImages, isTrue);
    });

    test('un trou ne fait pas reculer le repère', () {
      final advice = _advice(['https://x/0.jpg', null, 'https://x/2.jpg']);
      expect(advice.lastIllustratedIndex, 2);
    });
  });

  group('withoutImage', () {
    test('efface le visuel en conservant le geste et sa description', () {
      const step = PlatingStep(
        titre: 'Le lit',
        geste: 'Étaler le confit.',
        elements: ['confit'],
        imagePrompt: 'un disque de confit mat',
        imageUrl: 'https://x/0.jpg',
      );
      final vide = step.withoutImage();
      expect(vide.imageUrl, isNull);
      expect(vide.imagePrompt, 'un disque de confit mat');
      expect(vide.geste, 'Étaler le confit.');
      expect(vide.elements, ['confit']);
    });
  });
}
