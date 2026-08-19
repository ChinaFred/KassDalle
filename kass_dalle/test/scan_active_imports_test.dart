import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/data/scan_state.dart';

/// Les envois en vol vivent à côté de l'état de l'écran, pas à sa place.
///
/// C'est toute la mécanique qui permet aux boutons de rester disponibles :
/// l'envoi n'entre plus dans [ScanState.isRunning], donc il ne cache plus rien.
void main() {
  ActiveImport upload(
    String id, {
    ScanUploadPhase? phase,
    double progress = 0,
  }) {
    return ActiveImport(
      id: id,
      filename: '$id.jpg',
      intent: ScanIntent.recipe,
      phase: phase ?? ScanUploadPhase.uploading,
      progress: progress,
    );
  }

  group('isRunning', () {
    test('un envoi en vol ne verrouille pas l\'écran', () {
      final state = ScanState(activeImports: [upload('a')]);
      expect(state.hasActiveImports, isTrue);
      // Le point de tout le changement : c'est faux, donc les boutons restent.
      expect(state.isRunning, isFalse);
    });

    test('un sélecteur ouvert, lui, verrouille toujours', () {
      // Deux sélecteurs de fichiers ouverts en même temps n'ont aucun sens :
      // celui-là doit continuer de bloquer.
      const state = ScanState(status: ScanStatus.picking);
      expect(state.isRunning, isTrue);
    });

    test('une image en cours d\'amélioration verrouille aussi', () {
      const state = ScanState(status: ScanStatus.pendingEnhancement);
      expect(state.isRunning, isTrue);
    });

    test('sans envoi, il n\'y a rien à afficher', () {
      const state = ScanState();
      expect(state.hasActiveImports, isFalse);
    });
  });

  group('ActiveImport', () {
    test('chaque phase porte son libellé français', () {
      expect(upload('a').label, 'Envoi');
      expect(
        upload('a', phase: ScanUploadPhase.scanning).label,
        'Contrôle de sécurité',
      );
      expect(
        upload('a', phase: ScanUploadPhase.queueing).label,
        'Mise en file',
      );
    });

    test('avancer garde l\'identité de l\'envoi', () {
      // L'identifiant et le nom du fichier ne changent pas en route : c'est ce
      // qui permet de retrouver la bonne ligne parmi plusieurs envois.
      final started = upload('a1');
      final scanning = started.copyWith(
        phase: ScanUploadPhase.scanning,
        progress: 1,
      );
      expect(scanning.id, 'a1');
      expect(scanning.filename, 'a1.jpg');
      expect(scanning.phase, ScanUploadPhase.scanning);
      expect(scanning.progress, 1);
    });

    test('avancer sans rien préciser ne change rien', () {
      final u = upload('a', phase: ScanUploadPhase.scanning, progress: 0.5);
      final same = u.copyWith();
      expect(same.phase, ScanUploadPhase.scanning);
      expect(same.progress, 0.5);
    });
  });

  group('copyWith de ScanState', () {
    test('remplace la liste des envois', () {
      final state = ScanState(activeImports: [upload('a'), upload('b')]);
      final after = state.copyWith(activeImports: [upload('b')]);
      expect(after.activeImports.map((u) => u.id), ['b']);
    });

    test('sans mention, la liste survit', () {
      // Toutes les transitions d'écran passent par là : un envoi ne doit pas
      // disparaître parce que l'écran a changé d'état.
      final state = ScanState(activeImports: [upload('a')]);
      final after = state.copyWith(status: ScanStatus.pendingFiles);
      expect(after.activeImports.map((u) => u.id), ['a']);
    });
  });
}
