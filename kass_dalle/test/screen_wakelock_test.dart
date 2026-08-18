import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/screen_wakelock.dart';

/// Enregistre ce que la plateforme aurait reçu, sans plugin ni binding.
class _RecordedToggle {
  final calls = <bool>[];

  Future<void> call({required bool enable}) async => calls.add(enable);
}

void main() {
  group('ScreenWakelock', () {
    test(
      'la première prise allume, les suivantes ne réappliquent rien',
      () async {
        final toggle = _RecordedToggle();
        final wakelock = ScreenWakelock(toggle: toggle.call);

        await wakelock.acquire();
        await wakelock.acquire();

        expect(toggle.calls, [true]);
        expect(wakelock.holders, 2);
      },
    );

    test('le verrou ne tombe qu au dernier départ', () async {
      final toggle = _RecordedToggle();
      final wakelock = ScreenWakelock(toggle: toggle.call);

      await wakelock.acquire();
      await wakelock.acquire();
      await wakelock.release();

      // Deux recettes superposées : refermer la seconde ne doit pas éteindre
      // l'écran de celle qui reste ouverte.
      expect(toggle.calls, [true]);

      await wakelock.release();
      expect(toggle.calls, [true, false]);
      expect(wakelock.holders, 0);
    });

    test('une libération de trop ne descend pas sous zéro', () async {
      final toggle = _RecordedToggle();
      final wakelock = ScreenWakelock(toggle: toggle.call);

      await wakelock.release();

      expect(toggle.calls, isEmpty);
      expect(wakelock.holders, 0);
    });

    test('le retour d arrière-plan réapplique le verrou détenu', () async {
      final toggle = _RecordedToggle();
      final wakelock = ScreenWakelock(toggle: toggle.call);

      await wakelock.acquire();
      await wakelock.refresh();

      expect(toggle.calls, [true, true]);
    });

    test('sans détenteur, rien à réappliquer', () async {
      final toggle = _RecordedToggle();
      final wakelock = ScreenWakelock(toggle: toggle.call);

      await wakelock.refresh();

      expect(toggle.calls, isEmpty);
    });
  });
}
