import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/gemini_service.dart'
    show GeminiCallableException;
import 'package:kass_dalle/core/widgets/error_message.dart' show kAiBudgetScope;
import 'package:kass_dalle/features/planning/presentation/batch_planning_screen.dart';

/// La génération par lot ne s'arrête en silence que sur le plafond de la
/// génération (`PlanningRunDenied`, sans `details.scope`). Le plafond d'IA du
/// compte porte `scope: ai_budget` : son message est affiché, et un refus
/// `concurrency` ne coupe pas la boucle.
void main() {
  GeminiCallableException err(String code, Object? details) =>
      GeminiCallableException(code, 'Texte', details);

  group('isPlanningRunDenial', () {
    test('plafond de la génération : refus, quel que soit le code', () {
      for (final reason in ['count', 'cost', 'expired']) {
        expect(
          isPlanningRunDenial(err('resource-exhausted', {'reason': reason})),
          isTrue,
        );
        expect(
          isPlanningRunDenial(err('resource_exhausted', {'reason': reason})),
          isTrue,
        );
      }
      expect(
        isPlanningRunDenial(err('not-found', {'reason': 'unknown'})),
        isTrue,
      );
    });

    test('plafond d\'IA du compte : pas un refus de la génération', () {
      for (final reason in ['cost', 'calls', 'concurrency']) {
        expect(
          isPlanningRunDenial(
            err('resource-exhausted', {
              'reason': reason,
              'scope': kAiBudgetScope,
            }),
          ),
          isFalse,
          reason: reason,
        );
      }
    });

    test('sans raison, ou autre code : non', () {
      expect(isPlanningRunDenial(err('resource-exhausted', null)), isFalse);
      expect(isPlanningRunDenial(err('internal', {'reason': 'x'})), isFalse);
    });
  });

  group('isConcurrencyRefusal', () {
    test('seul `concurrency` du plafond du compte', () {
      expect(
        isConcurrencyRefusal(
          err('resource-exhausted', {
            'reason': 'concurrency',
            'scope': kAiBudgetScope,
          }),
        ),
        isTrue,
      );
      expect(
        isConcurrencyRefusal(
          err('resource-exhausted', {
            'reason': 'cost',
            'scope': kAiBudgetScope,
          }),
        ),
        isFalse,
      );
      expect(
        isConcurrencyRefusal(
          err('resource-exhausted', {'reason': 'concurrency'}),
        ),
        isFalse,
      );
    });
  });
}
