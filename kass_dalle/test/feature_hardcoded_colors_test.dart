import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Garde du thème sombre : pas de couleur Material fixe dans les features.
///
/// `Colors.green`, `Colors.orange`, `Colors.red`, `Colors.grey` (et leurs
/// `shadeXXX`) ne suivent pas le thème : en sombre, un fond `shade100` reste
/// clair et un texte `shade800` devient illisible. On emploie le
/// `ColorScheme` (`primary`, `tertiary`, `error`, `outline`,
/// `onSurfaceVariant`…).
///
/// Exemptés : le bac à sable (`features/sandbox/`), code d'essai, et les
/// fichiers de [_exceptions], chacun avec sa raison.
const _exceptions = <String, String>{
  // Aucune exception à ce jour. Exemple de forme :
  // 'lib/features/x/y.dart': 'dessin sur une photo, indépendant du thème',
};

final _forbidden = RegExp(r'\bColors\.(green|orange|red|grey)\b');

void main() {
  test('aucune couleur fixe green/orange/red/grey dans lib/features/', () {
    final offenders = <String>[];
    final files = Directory('lib/features')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final file in files) {
      final path = file.path.replaceAll('\\', '/');
      if (path.startsWith('lib/features/sandbox/')) continue;
      if (_exceptions.containsKey(path)) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (_forbidden.hasMatch(lines[i])) {
          offenders.add('$path:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('la garde détecte les teintes et leurs nuances', () {
    expect(_forbidden.hasMatch('color: Colors.green,'), isTrue);
    expect(_forbidden.hasMatch('Colors.grey.shade400'), isTrue);
    expect(_forbidden.hasMatch('Colors.red.shade100'), isTrue);
    expect(_forbidden.hasMatch('Colors.orange'), isTrue);
    expect(_forbidden.hasMatch('Colors.redAccent'), isFalse);
    expect(_forbidden.hasMatch('Colors.deepOrange'), isFalse);
    expect(_forbidden.hasMatch('Colors.transparent'), isFalse);
  });
}
