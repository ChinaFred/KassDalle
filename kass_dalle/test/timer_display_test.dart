/// Les minuteurs d'une étape : ce qui part au rendu, et ce qui s'affiche.
///
/// Deux défauts, une seule cause visible à l'écran.
///
/// **Le normaliseur réécrivait l'intérieur d'un jeton.** Il enveloppe les
/// durées écrites en texte brut — `3%minutes` devient `~{3%minutes}` — et ne
/// vérifiait, pour savoir s'il était déjà dans un jeton, que le caractère
/// précédent. Dans `~{1-2%minutes}`, ce caractère est un tiret : la garde
/// passait. Il produisait `~{1-~{2%minutes}}`, et l'étape affichait une puce
/// « 1-~{2 min » suivie d'une accolade orpheline. C'est ce que montrait la
/// capture d'écran.
///
/// **Et la fourchette se lisait au tiret.** « 1-2 min » ressemble à une
/// soustraction ; le livre dit « 1 à 2 minutes ».
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/utils/timer_display.dart';
import 'package:kass_dalle/features/recipes/presentation/cooklang_preview_helpers.dart';

void main() {
  group('cooklangNormalizeStepTimers', () {
    test('un minuteur déjà formé n\'est pas retouché', () {
      const step = 'Laisser reposer ~{1-2%minutes} puis servir.';
      expect(cooklangNormalizeStepTimers(step), step);
    });

    test('une fourchette au tiret ne se fait plus couper en deux', () {
      // La régression écrivait « ~{1-~{2%minutes}} ».
      final rendu = cooklangNormalizeStepTimers('Reposer ~{1-2%minutes}.');
      expect(rendu.contains('~{1-~{'), isFalse);
      expect('~'.allMatches(rendu).length, 1);
    });

    test('une durée en texte brut est bien enveloppée', () {
      expect(
        cooklangNormalizeStepTimers('Cuire 25%minutes à feu doux.'),
        'Cuire ~{25%minutes} à feu doux.',
      );
    });

    test('une fourchette en texte brut est enveloppée d\'un seul tenant', () {
      expect(
        cooklangNormalizeStepTimers('Cuire 1-2%minutes.'),
        'Cuire ~{1-2%minutes}.',
      );
    });

    test('un ingrédient voisin n\'est pas touché', () {
      const step = 'Ajouter @sel{5%g} et cuire 10%minutes.';
      expect(
        cooklangNormalizeStepTimers(step),
        'Ajouter @sel{5%g} et cuire ~{10%minutes}.',
      );
    });

    test('la quantité d\'un ingrédient n\'est jamais prise pour une durée', () {
      const step = 'Verser @lait{30%minutes de repos}.';
      expect(cooklangNormalizeStepTimers(step), step);
    });
  });

  group('cooklangFormatTimer', () {
    test('une fourchette au tiret se lit « à »', () {
      expect(cooklangFormatTimer('1-2%minutes'), '1 à 2 min');
    });

    test('la fourchette déjà écrite « à » est gardée telle quelle', () {
      expect(cooklangFormatTimer('5 à 8%min'), '5 à 8 min');
    });

    test('une durée simple ne bouge pas', () {
      expect(cooklangFormatTimer('30%minutes'), '30 min');
      expect(cooklangFormatTimer('2%heures'), '2 h');
    });

    test('le format horaire reste lu comme avant', () {
      expect(cooklangFormatTimer('0:30:00'), '30 minutes');
      expect(cooklangFormatTimer('1:30:00'), '1h30');
    });
  });

  group('formatTimerRange', () {
    test('un tiret entre deux chiffres devient « à »', () {
      expect(formatTimerRange('1-2'), '1 à 2');
      expect(formatTimerRange('10 - 15'), '10 à 15');
    });

    test('un tiret qui ne sépare pas deux nombres est laissé', () {
      // « demi-heure » n'est pas une fourchette.
      expect(formatTimerRange('demi-heure'), 'demi-heure');
      expect(formatTimerRange('-5'), '-5');
    });
  });
  group('formatRestTime', () {
    test("moins d'une heure reste en minutes", () {
      expect(formatRestTime(30), '30 min');
    });

    test("une heure ronde s'écrit en heures", () {
      expect(formatRestTime(60), '1 h');
      expect(formatRestTime(720), '12 h');
    });

    test("les minutes qui restent suivent l'heure", () {
      expect(formatRestTime(150), '2 h 30');
    });

    test("au-delà d'un jour, on compte en jours", () {
      expect(formatRestTime(1440), '1 jour');
      expect(formatRestTime(2880), '2 jours');
    });
  });
}
