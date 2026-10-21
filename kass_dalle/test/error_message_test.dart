import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/gemini_service.dart'
    show GeminiCallableException;
import 'package:kass_dalle/core/widgets/error_message.dart';

/// Exception Firebase minimale : `FirebaseException` est concrète et n'exige
/// que `plugin`, ce qui suffit à rejouer l'aiguillage sur `code`.
FirebaseException _firebaseError(String code) =>
    FirebaseException(plugin: 'cloud_firestore', code: code);

void main() {
  group('describeError', () {
    test('un réseau coupé est réessayable et le dit en français', () {
      final m = describeError(_firebaseError('unavailable'));
      expect(m.title, 'Connexion perdue');
      expect(m.retryable, isTrue);
      expect(m.advice, contains('connexion internet'));
    });

    test('un refus de droits n\'est pas réessayable', () {
      final m = describeError(_firebaseError('permission-denied'));
      expect(m.title, 'Accès refusé');
      // Le distinguer n'est pas cosmétique : proposer « Réessayer » sur un
      // refus de droits promet un résultat que le deuxième appui ne donnera pas.
      expect(m.retryable, isFalse);
    });

    test('une session expirée oriente vers la reconnexion', () {
      final m = describeError(_firebaseError('unauthenticated'));
      expect(m.title, 'Session expirée');
      expect(m.retryable, isFalse);
    });

    test('un document absent n\'invite pas à réessayer', () {
      final m = describeError(_firebaseError('not-found'));
      expect(m.title, 'Contenu introuvable');
      expect(m.retryable, isFalse);
    });

    test('un délai dépassé est réessayable', () {
      final m = describeError(TimeoutException('trop long'));
      expect(m.title, contains('trop de temps'));
      expect(m.retryable, isTrue);
    });

    test('une panne réseau sans code Firebase est reconnue au texte', () {
      final m = describeError(
        Exception(
          'SocketException: Failed host lookup: firestore.googleapis.com',
        ),
      );
      expect(m.title, 'Connexion perdue');
    });

    test(
      'une exception inconnue reste réessayable, sans mentir sur sa nature',
      () {
        final m = describeError(StateError('bizarre'));
        expect(m.title, 'Une erreur inattendue est survenue');
        expect(m.advice, kUnexpectedErrorAdvice);
        expect(m.retryable, isTrue);
      },
    );

    test('une erreur nulle ne fait pas planter le message', () {
      expect(describeError(null).title, isNotEmpty);
    });

    test('une erreur de callable d\'IA est lue par son code', () {
      // SDK : `resource-exhausted` ; appel HTTP du web : `resource_exhausted`.
      for (final code in ['resource-exhausted', 'resource_exhausted']) {
        // Sans `details` : le fournisseur d'IA saturé.
        expect(
          describeError(GeminiCallableException(code, 'x', null)).title,
          'Service d\'IA saturé',
        );
        // Avec une raison (plafond d'une génération, des tickets…).
        expect(
          describeError(
            GeminiCallableException(code, 'x', {'reason': 'count'}),
          ).title,
          'Limite du jour atteinte',
        );
      }
      // Hors callable d'IA : le libellé générique d'un plafond.
      expect(
        describeError(_firebaseError('resource-exhausted')).title,
        'Limite du jour atteinte',
      );
      final denied = describeError(
        GeminiCallableException('permission-denied', 'x', null),
      );
      expect(denied.title, 'Accès refusé');
      expect(denied.retryable, isFalse);
      expect(
        describeError(GeminiCallableException('unavailable', 'x', null)).title,
        'Connexion perdue',
      );
      expect(
        describeError(GeminiCallableException('internal', 'x', null)).title,
        'Une erreur inattendue est survenue',
      );
    });
  });

  group('failureMessage', () {
    test('deux phrases : ce qui n\'a pas eu lieu, puis la cause', () {
      expect(
        failureMessage('Photo non enregistrée', _firebaseError('unavailable')),
        'Photo non enregistrée. Connexion perdue.',
      );
      expect(
        failureMessage(
          'Recette non supprimée',
          _firebaseError('permission-denied'),
        ),
        'Recette non supprimée. Accès refusé.',
      );
      expect(
        failureMessage('Repas non enregistré', StateError('bizarre')),
        'Repas non enregistré. Une erreur inattendue est survenue.',
      );
    });

    test('un libellé déjà ponctué ne reçoit pas un second point', () {
      expect(
        failureMessage('Livre non vérifié.', TimeoutException('x')),
        'Livre non vérifié. '
        'Le serveur met trop de temps à répondre.',
      );
    });

    test('le texte brut de l\'exception n\'apparaît jamais', () {
      final text = failureMessage(
        'Photo non enregistrée',
        GeminiCallableException('internal', 'stack trace interne', null),
      );
      expect(text, isNot(contains('GeminiCallableException')));
      expect(text, isNot(contains('stack trace')));
    });
  });

  group('failureMessage — plafond d\'IA du compte', () {
    const serverMessage =
        'Limite d\'utilisation de l\'IA atteinte pour aujourd\'hui. Réessayez '
        'demain, ou demandez à un administrateur de relever la limite.';

    test('reason cost : la seconde phrase est le message du serveur', () {
      expect(
        failureMessage(
          'Recette non conçue',
          GeminiCallableException('resource-exhausted', serverMessage, {
            'reason': 'cost',
            'scope': kAiBudgetScope,
          }),
        ),
        'Recette non conçue. $serverMessage',
      );
    });

    test('reason calls, appel HTTP du web (`resource_exhausted`)', () {
      expect(
        failureMessage(
          'Idées non proposées',
          GeminiCallableException('resource_exhausted', 'Revenez demain', {
            'reason': 'calls',
            'scope': kAiBudgetScope,
          }),
        ),
        'Idées non proposées. Revenez demain.',
      );
    });

    test('reason concurrency : le message du serveur aussi', () {
      expect(
        failureMessage(
          'Recette non conçue',
          GeminiCallableException(
            'resource-exhausted',
            'L\'IA traite déjà vos autres demandes. Réessayez dans un instant.',
            {'reason': 'concurrency', 'scope': kAiBudgetScope},
          ),
        ),
        'Recette non conçue. L\'IA traite déjà vos autres demandes. '
        'Réessayez dans un instant.',
      );
    });

    test('FirebaseFunctionsException du SDK : même lecture', () {
      expect(
        failureMessage(
          'Image non publiée',
          FirebaseFunctionsException(
            code: 'resource-exhausted',
            message: serverMessage,
            details: {'reason': 'calls', 'scope': kAiBudgetScope},
          ),
        ),
        'Image non publiée. $serverMessage',
      );
    });

    test('fournisseur saturé, sans details : « Service d\'IA saturé »', () {
      final error = GeminiCallableException(
        'resource-exhausted',
        'Le service d\'IA est saturé. Réessayez plus tard.',
        null,
      );
      expect(
        failureMessage('Recette non conçue', error),
        'Recette non conçue. Service d\'IA saturé.',
      );
      final m = describeError(error);
      expect(m.title, 'Service d\'IA saturé');
      expect(m.advice, 'Réessayez plus tard.');
    });

    test('autres raisons ou sans scope : « Limite du jour atteinte »', () {
      for (final details in [
        {'reason': 'import', 'scope': kAiBudgetScope},
        // Plafond d'une génération de planning (`PlanningRunDenied`).
        {'reason': 'cost'},
        {'reason': 'cost', 'scope': 'autre'},
      ]) {
        expect(
          failureMessage(
            'Recette non conçue',
            GeminiCallableException('resource-exhausted', 'Texte', details),
          ),
          'Recette non conçue. Limite du jour atteinte.',
          reason: '$details',
        );
      }
    });

    test('un autre code avec les mêmes details : libellé de son code', () {
      expect(
        failureMessage(
          'Recette non conçue',
          GeminiCallableException('internal', 'Texte', {
            'reason': 'cost',
            'scope': kAiBudgetScope,
          }),
        ),
        'Recette non conçue. Une erreur inattendue est survenue.',
      );
    });

    test('message vide : libellé générique', () {
      expect(
        aiBudgetRefusalMessage(
          GeminiCallableException('resource-exhausted', '  ', {
            'reason': 'cost',
            'scope': kAiBudgetScope,
          }),
        ),
        isNull,
      );
    });
  });
}
