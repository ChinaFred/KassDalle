import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/utils/page_name_order.dart';

/// L'ordre des pages d'un import multi-fichiers.
///
/// Le sélecteur rend une sélection multiple dans l'ordre du système. Sans tri
/// numérique, « page10.jpg » passe devant « page2.jpg » et la recette part à
/// l'analyse dans le désordre, sans qu'aucune erreur soit levée.
void main() {
  List<String> sorted(List<String> names) =>
      List<String>.from(names)..sort(comparePageNames);

  test('les chiffres se comparent comme des nombres', () {
    expect(sorted(['page10.jpg', 'page2.jpg', 'page1.jpg']), [
      'page1.jpg',
      'page2.jpg',
      'page10.jpg',
    ]);
  });

  test('les photos numérotées par l\'appareil restent dans l\'ordre', () {
    expect(sorted(['IMG_9.jpg', 'IMG_10.jpg', 'IMG_100.jpg', 'IMG_8.jpg']), [
      'IMG_8.jpg',
      'IMG_9.jpg',
      'IMG_10.jpg',
      'IMG_100.jpg',
    ]);
  });

  test('les zéros de tête ne changent pas la valeur', () {
    expect(sorted(['p007.jpg', 'p8.jpg']), ['p007.jpg', 'p8.jpg']);
  });

  test('la casse n\'inverse rien', () {
    expect(sorted(['Recette_b.png', 'recette_a.png']), [
      'recette_a.png',
      'Recette_b.png',
    ]);
  });

  test('les noms sans chiffre restent alphabétiques', () {
    expect(sorted(['verso.jpg', 'recto.jpg']), ['recto.jpg', 'verso.jpg']);
  });

  test('la page sans numéro précède la page 2', () {
    expect(sorted(['recette2.jpg', 'recette.jpg']), [
      'recette.jpg',
      'recette2.jpg',
    ]);
  });

  test('un nombre plus grand qu\'un entier ne fait pas échouer le tri', () {
    expect(sorted(['scan_${'9' * 40}.jpg', 'scan_1.jpg']), [
      'scan_1.jpg',
      'scan_${'9' * 40}.jpg',
    ]);
  });

  test('deux nombres énormes se départagent quand même', () {
    final a = '1${'0' * 30}1';
    final b = '1${'0' * 30}2';
    expect(comparePageNames('scan_$b.jpg', 'scan_$a.jpg'), greaterThan(0));
  });

  test('deux noms identiques valent zéro', () {
    expect(comparePageNames('page3.jpg', 'page3.jpg'), 0);
  });
}
