import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/features/admin/data/app_check_repository.dart';

/// Le mode App Check, tel qu'il voyage entre le serveur et l'écran.
///
/// Trois valeurs seulement, et un repli qui n'invente rien : un mode inconnu
/// doit se lire « observation », le seul état qui ne refuse rien et ne masque
/// rien. Le lire « exigé » couperait l'application sur un mot mal orthographié ;
/// le lire « désactivé » éteindrait silencieusement la surveillance.
void main() {
  group('lecture du mode', () {
    test('les trois modes connus se relisent tels quels', () {
      expect(AppCheckMode.fromWire('off'), AppCheckMode.off);
      expect(AppCheckMode.fromWire('monitor'), AppCheckMode.monitor);
      expect(AppCheckMode.fromWire('enforce'), AppCheckMode.enforce);
    });

    test('un mode inconnu, vide ou absent vaut « observation »', () {
      expect(AppCheckMode.fromWire('enforced'), AppCheckMode.monitor);
      expect(AppCheckMode.fromWire(''), AppCheckMode.monitor);
      expect(AppCheckMode.fromWire(null), AppCheckMode.monitor);
    });

    test('le nom transmis au serveur est celui qu\'il attend', () {
      expect(AppCheckMode.values.map((m) => m.wireName), [
        'off',
        'monitor',
        'enforce',
      ]);
    });
  });

  group('libellés', () {
    test(
      'chaque mode dit ce qu\'il fait, et « exigé » nomme sa contrepartie',
      () {
        for (final mode in AppCheckMode.values) {
          expect(mode.label, isNotEmpty);
          expect(mode.description, isNotEmpty);
        }
        expect(AppCheckMode.enforce.description, contains('Windows'));
      },
    );
  });
}
