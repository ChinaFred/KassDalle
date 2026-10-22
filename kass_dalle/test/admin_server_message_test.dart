import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/gemini_service.dart';
import 'package:kass_dalle/features/admin/data/gcp_billing_repository.dart';
import 'package:kass_dalle/features/admin/presentation/admin_server_message.dart';

void main() {
  const codes = {'failed-precondition'};

  test('un code de la liste blanche garde le message du serveur', () {
    final error = FirebaseFunctionsException(
      code: 'failed-precondition',
      message: 'Cette image n\'attend pas de décision.',
    );
    expect(
      adminFailureMessage('Image non publiée', error, codes: codes),
      'Image non publiée. Cette image n\'attend pas de décision.',
    );
  });

  test('un code hors de la liste blanche prend le titre lisible', () {
    final error = FirebaseFunctionsException(
      code: 'invalid-argument',
      message: 'moderationId et decision sont requis.',
    );
    expect(
      adminFailureMessage('Image non publiée', error, codes: codes),
      'Image non publiée. Une erreur inattendue est survenue.',
    );
  });

  test('internal, unknown, unavailable et deadline-exceeded jamais repris', () {
    for (final code in [
      'internal',
      'unknown',
      'unavailable',
      'deadline-exceeded',
    ]) {
      final error = FirebaseFunctionsException(
        code: code,
        message: 'Error: 13 INTERNAL',
      );
      expect(adminServerMessage(error, {code}), isNull, reason: code);
    }
  });

  test('GeminiCallableException et CallableFailure lus comme le SDK', () {
    expect(
      adminServerMessage(
        GeminiCallableException('FAILED_PRECONDITION', 'Désactivée.', null),
        codes,
      ),
      'Désactivée.',
    );
    const failure = CallableFailure(
      name: 'setNutritionSourcePolicyFn',
      code: 'permission-denied',
      message: 'Missing or insufficient permissions.',
      details: 'n/a',
    );
    expect(adminServerMessage(failure, codes), isNull);
    // Le code de la callable donne la cause lisible, pas le message.
    expect(
      adminFailureMessage('Politique nutrition non enregistrée', failure),
      'Politique nutrition non enregistrée. Accès refusé.',
    );
  });

  test('une erreur quelconque ne recopie pas son texte', () {
    expect(
      adminFailureMessage('Rôle non modifié', Exception('boom')),
      'Rôle non modifié. Une erreur inattendue est survenue.',
    );
  });

  test(
    'écrans de backfill : message du serveur écrit pour l\'admin, sinon cause lisible',
    () {
      const refused = CallableFailure(
        name: 'setBackfillScheduleFn',
        code: 'invalid-argument',
        message: 'Choisissez au moins un jour.',
        details: 'n/a',
      );
      expect(
        adminFailureMessage(
          'Programmation non enregistrée',
          refused,
          codes: kBackfillServerMessageCodes,
        ),
        'Programmation non enregistrée. Choisissez au moins un jour.',
      );
      const crashed = CallableFailure(
        name: 'backfillEnrichReferentialsFn',
        code: 'internal',
        message: 'Error: 13 INTERNAL: RST_STREAM',
        details: 'n/a',
      );
      final text = adminFailureMessage(
        'Passage « Reprendre le sel des ingrédients » non terminé',
        crashed,
        codes: kBackfillServerMessageCodes,
      );
      expect(text.contains('RST_STREAM'), isFalse);
      expect(
        text.startsWith(
          'Passage « Reprendre le sel des ingrédients » non terminé.',
        ),
        isTrue,
      );
      final other = adminFailureMessage(
        'Changement non enregistré',
        StateError('Bad state: x is null'),
        codes: kBackfillServerMessageCodes,
      );
      expect(other.contains('Bad state'), isFalse);
    },
  );
}
