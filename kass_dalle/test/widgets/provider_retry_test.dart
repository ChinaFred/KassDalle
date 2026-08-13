import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/widgets/provider_retry.dart';

/// Riverpod 3 réessaie par défaut **dix fois** toute exception levée par un
/// provider, en backoff exponentiel plafonné à 6,4 s — et l'état reste
/// `AsyncLoading` pendant tout ce temps. Une coupure réseau produisait donc
/// une trentaine de secondes de roue qui tourne avant que le message d'erreur
/// et son bouton Réessayer apparaissent.
///
/// Ces tests fixent la politique de remplacement. Ils ne vérifient pas un
/// détail cosmétique : c'est ce qui décide combien de temps la famille regarde
/// un écran qui ne dit rien.
void main() {
  FirebaseException firestore(String code) =>
      FirebaseException(plugin: 'cloud_firestore', code: code);

  group('appProviderRetry', () {
    test('un refus de droits n\'est jamais réessayé', () {
      expect(appProviderRetry(0, firestore('permission-denied')), isNull);
    });

    test('une session expirée n\'est jamais réessayée', () {
      expect(appProviderRetry(0, firestore('unauthenticated')), isNull);
    });

    test('un document absent n\'est jamais réessayé', () {
      expect(appProviderRetry(0, firestore('not-found')), isNull);
    });

    test('une indisponibilité a droit à deux tentatives, pas plus', () {
      final error = firestore('unavailable');
      expect(appProviderRetry(0, error), isNotNull);
      expect(appProviderRetry(1, error), isNotNull);
      expect(appProviderRetry(2, error), isNull);
      expect(appProviderRetry(9, error), isNull);
    });

    test('les deux tentatives tiennent en moins d\'une seconde et demie', () {
      final error = firestore('unavailable');
      final total =
          appProviderRetry(0, error)! + appProviderRetry(1, error)!;
      expect(total, lessThan(const Duration(milliseconds: 1500)));
    });

    test('le délai croît entre la première et la seconde tentative', () {
      final error = firestore('unavailable');
      expect(
        appProviderRetry(1, error)!,
        greaterThan(appProviderRetry(0, error)!),
      );
    });

    test('un délai dépassé est réessayable', () {
      expect(appProviderRetry(0, TimeoutException('trop long')), isNotNull);
    });

    test('une exception inconnue garde droit au réessai', () {
      expect(appProviderRetry(0, Exception('surprise')), isNotNull);
    });
  });
}
