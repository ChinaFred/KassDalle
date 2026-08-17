import 'package:flutter_test/flutter_test.dart';

import 'package:kass_dalle/features/admin/data/ai_budget_repository.dart';

/// Lecture des plafonds côté client.
///
/// Le piège est le champ `enabled` : un plafond qui s'éteindrait parce qu'un
/// champ manque ne protégerait plus, et l'écran affirmerait pourtant qu'il est
/// désactivé — c'est-à-dire la vérité sur l'écran, et le contraire sur le
/// serveur, qui, lui, considère l'absence comme actif.
void main() {
  group('lecture de la politique', () {
    test('les quatre réglages se relisent tels quels', () {
      final policy = AiBudgetPolicy.fromMap({
        'dailyCostUsdPerUser': 2.5,
        'dailyCallsPerUser': 400,
        'monthlyAlertUsd': 25.0,
        'enabled': true,
      });
      expect(policy.dailyCostUsdPerUser, 2.5);
      expect(policy.dailyCallsPerUser, 400);
      expect(policy.monthlyAlertUsd, 25.0);
      expect(policy.enabled, isTrue);
    });

    test('un champ « enabled » absent vaut actif, comme sur le serveur', () {
      expect(AiBudgetPolicy.fromMap(const {}).enabled, isTrue);
    });

    test('« enabled: false » est le seul état qui désactive', () {
      expect(AiBudgetPolicy.fromMap(const {'enabled': false}).enabled, isFalse);
      expect(AiBudgetPolicy.fromMap(const {'enabled': 0}).enabled, isTrue);
    });

    test('des plafonds absents se lisent à zéro, jamais au hasard', () {
      final policy = AiBudgetPolicy.fromMap(const {});
      expect(policy.dailyCostUsdPerUser, 0);
      expect(policy.dailyCallsPerUser, 0);
    });
  });

  group('aller-retour vers le serveur', () {
    test('ce qui est envoyé se relit à l\'identique', () {
      const policy = AiBudgetPolicy(
        dailyCostUsdPerUser: 1.75,
        dailyCallsPerUser: 120,
        monthlyAlertUsd: 30,
        enabled: false,
      );
      final relu = AiBudgetPolicy.fromMap(policy.toMap());
      expect(relu.dailyCostUsdPerUser, policy.dailyCostUsdPerUser);
      expect(relu.dailyCallsPerUser, policy.dailyCallsPerUser);
      expect(relu.monthlyAlertUsd, policy.monthlyAlertUsd);
      expect(relu.enabled, policy.enabled);
    });

    test('copyWith ne touche que ce qu\'on lui donne', () {
      const policy = AiBudgetPolicy(
        dailyCostUsdPerUser: 2,
        dailyCallsPerUser: 400,
        monthlyAlertUsd: 25,
        enabled: true,
      );
      final modifie = policy.copyWith(dailyCostUsdPerUser: 5);
      expect(modifie.dailyCostUsdPerUser, 5);
      expect(modifie.dailyCallsPerUser, 400);
      expect(modifie.monthlyAlertUsd, 25);
      expect(modifie.enabled, isTrue);
    });
  });
}
