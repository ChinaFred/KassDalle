import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Un décalage de 32 bits ou plus ne dit pas la même chose sur le web.
///
/// dart2js compile les opérateurs de bits sur des entiers 32 bits. `1 << 32`
/// vaut 4 294 967 296 sur la machine virtuelle et **0** dans un navigateur.
/// Le code compile, l'analyse est propre, toute la suite de tests passe — et
/// l'application échoue chez l'utilisateur web, seul.
///
/// C'est arrivé le 1er septembre 2026. `Random().nextInt(1 << 32)` levait
/// `RangeError` dès la première ligne de la mise en file d'un scan : sur le
/// web, plus aucun import ne partait. Le bouton « Appliquer » de l'atelier de
/// retouche se contentait de refermer l'écran, sans erreur ni trace, et il a
/// fallu deux versions et une lecture directe de Firestore pour le voir.
///
/// Aucun test de cette suite ne pouvait l'attraper : ils tournent tous sur la
/// machine virtuelle, où le calcul est juste. D'où ce garde-fou textuel. Il ne
/// mesure rien, il interdit la construction — et c'est le seul moyen dont
/// dispose une suite qui ne s'exécute pas dans un navigateur.
///
/// Écrire la borne en littéral (`0x100000000`) donne la même valeur des deux
/// côtés.
void main() {
  test('aucun décalage de 32 bits ou plus dans lib/', () {
    // Un décalage de 32 ou plus, quelle que soit l'espace autour.
    final large = RegExp(r'<<\s*(3[2-9]|[4-9]\d|\d{3,})');

    final fautifs = <String>[];
    final lib = Directory('lib');
    for (final entite in lib.listSync(recursive: true)) {
      if (entite is! File || !entite.path.endsWith('.dart')) continue;
      final lignes = entite.readAsLinesSync();
      for (var i = 0; i < lignes.length; i++) {
        final ligne = lignes[i];
        // Un commentaire qui cite le piège n'est pas le piège.
        if (ligne.trimLeft().startsWith('//')) continue;
        if (large.hasMatch(ligne)) {
          fautifs.add('${entite.path}:${i + 1} — ${ligne.trim()}');
        }
      }
    }

    expect(
      fautifs,
      isEmpty,
      reason:
          'Ces décalages valent 0 sur le web, où dart2js travaille sur 32 bits.\n'
          'Écrire la valeur en littéral (0x100000000 pour 1 << 32).\n'
          '${fautifs.join('\n')}',
    );
  });
}
