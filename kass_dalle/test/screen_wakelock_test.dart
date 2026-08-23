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
        final wakelock = ScreenWakelock(toggle: toggle.call, supported: true);

        await wakelock.acquire();
        await wakelock.acquire();

        expect(toggle.calls, [true]);
        expect(wakelock.holders, 2);
      },
    );

    test('le verrou ne tombe qu au dernier départ', () async {
      final toggle = _RecordedToggle();
      final wakelock = ScreenWakelock(toggle: toggle.call, supported: true);

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
      final wakelock = ScreenWakelock(toggle: toggle.call, supported: true);

      await wakelock.release();

      expect(toggle.calls, isEmpty);
      expect(wakelock.holders, 0);
    });

    test('le retour d arrière-plan réapplique le verrou détenu', () async {
      final toggle = _RecordedToggle();
      final wakelock = ScreenWakelock(toggle: toggle.call, supported: true);

      await wakelock.acquire();
      await wakelock.refresh();

      expect(toggle.calls, [true, true]);
    });

    test('sans détenteur, rien à réappliquer', () async {
      final toggle = _RecordedToggle();
      final wakelock = ScreenWakelock(toggle: toggle.call, supported: true);

      await wakelock.refresh();

      expect(toggle.calls, isEmpty);
    });

    // ── Hors Android ────────────────────────────────────────────────────────
    //
    // Le maintien d'écran est réservé à l'APK. Ce n'est pas une limite du
    // plugin — il tient aussi l'écran sur Windows — mais un choix : la
    // fonctionnalité vise le téléphone posé sur le plan de travail.
    //
    // Le web y était en plus cassé : son implémentation n'entrait pas dans le
    // bundle, et chaque ouverture de recette envoyait l'appel vers un canal
    // natif absent. Un rapport d'erreur par session, pour une fonctionnalité
    // que personne n'avait demandée là.

    test('hors Android, la plateforme n\'est jamais sollicitée', () async {
      final toggle = _RecordedToggle();
      final wakelock = ScreenWakelock(toggle: toggle.call, supported: false);

      await wakelock.acquire();
      await wakelock.acquire();
      await wakelock.refresh();
      await wakelock.release();

      expect(toggle.calls, isEmpty);
      expect(wakelock.holders, 0);
    });
  });
}
