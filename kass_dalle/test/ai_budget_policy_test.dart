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
        'dailyCostEurPerUser': 2.5,
        'dailyCallsPerUser': 400,
        'monthlyAlertEur': 25.0,
        'enabled': true,
      });
      expect(policy.dailyCostEurPerUser, 2.5);
      expect(policy.dailyCallsPerUser, 400);
      expect(policy.monthlyAlertEur, 25.0);
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
      expect(policy.dailyCostEurPerUser, 0);
      expect(policy.dailyCallsPerUser, 0);
    });
  });

  group('aller-retour vers le serveur', () {
    test('ce qui est envoyé se relit à l\'identique', () {
      const policy = AiBudgetPolicy(
        dailyCostEurPerUser: 1.75,
        dailyCallsPerUser: 120,
        monthlyAlertEur: 30,
        enabled: false,
      );
      final relu = AiBudgetPolicy.fromMap(policy.toMap());
      expect(relu.dailyCostEurPerUser, policy.dailyCostEurPerUser);
      expect(relu.dailyCallsPerUser, policy.dailyCallsPerUser);
      expect(relu.monthlyAlertEur, policy.monthlyAlertEur);
      expect(relu.enabled, policy.enabled);
    });

    test('copyWith ne touche que ce qu\'on lui donne', () {
      const policy = AiBudgetPolicy(
        dailyCostEurPerUser: 2,
        dailyCallsPerUser: 400,
        monthlyAlertEur: 25,
        enabled: true,
      );
      final modifie = policy.copyWith(dailyCostEurPerUser: 5);
      expect(modifie.dailyCostEurPerUser, 5);
      expect(modifie.dailyCallsPerUser, 400);
      expect(modifie.monthlyAlertEur, 25);
      expect(modifie.enabled, isTrue);
    });
  });

  group("le multiplicateur du fondateur", () {
    AiBudgetSnapshot snapshot({String? founder}) => AiBudgetSnapshot(
      policy: const AiBudgetPolicy(
        dailyCostEurPerUser: 2,
        dailyCallsPerUser: 400,
        monthlyAlertEur: 25,
        enabled: true,
      ),
      usdToEur: 0.9,
      founderUid: founder,
      founderMultiplier: 5,
      day: "2026-08-18",
      currentDay: "2026-08-18",
      periods: const [],
      periodsWithoutBreakdown: const [],
      spends: const [],
      today: const [],
    );

    test("il porte sur les deux plafonds du seul fondateur", () {
      final s = snapshot(founder: "uid-fondateur");
      expect(s.costLimitEurFor("uid-fondateur"), 10);
      expect(s.callsLimitFor("uid-fondateur"), 2000);
      expect(s.costLimitEurFor("uid-autre"), 2);
      expect(s.callsLimitFor("uid-autre"), 400);
    });

    test("sans fondateur connu, personne ne l obtient", () {
      // Compte Auth introuvable : le serveur rend null, et l ecran ne doit pas
      // afficher un plafond plus large que celui reellement applique.
      final s = snapshot();
      expect(s.costLimitEurFor("uid-fondateur"), 2);
      expect(s.callsLimitFor("uid-fondateur"), 400);
    });
  });

  group('le jour regardé', () {
    AiBudgetSnapshot snapshot({required String day, required String current}) =>
        AiBudgetSnapshot(
          policy: AiBudgetPolicy.fromMap(const {}),
          usdToEur: 0.92,
          founderUid: null,
          founderMultiplier: 10,
          day: day,
          currentDay: current,
          periods: const [],
          periodsWithoutBreakdown: const [],
          spends: const [],
          today: const [],
        );

    test('le jour courant vient du serveur, pas de l horloge du client', () {
      // Un client dont l horloge avance afficherait « aujourd hui » sur une
      // journee deja close, et un plafond epuise comme s il courait encore.
      final s = snapshot(day: '2026-08-30', current: '2026-08-30');
      expect(s.isToday, isTrue);
      expect(snapshot(day: '2026-08-29', current: '2026-08-30').isToday, false);
    });

    test('une date se relit et se réécrit à l identique', () {
      final jour = parseSpendDay('2026-08-30');
      expect(jour, DateTime.utc(2026, 8, 30));
      expect(formatSpendDay(jour!), '2026-08-30');
    });

    test('reculer d un jour traverse le changement de mois', () {
      final premier = parseSpendDay('2026-03-01')!;
      expect(
        formatSpendDay(premier.subtract(const Duration(days: 1))),
        '2026-02-28',
      );
    });

    test('une date impossible est refusée, pas décalée', () {
      // 2026-02-31 se normaliserait en mars : les fleches feraient alors
      // glisser d un mois sans le dire.
      expect(parseSpendDay('2026-02-31'), isNull);
      expect(parseSpendDay('hier'), isNull);
      expect(parseSpendDay(''), isNull);
      expect(parseSpendDay('2026-08'), isNull);
    });

    test('un mois et un jour à un chiffre se réécrivent sur deux', () {
      expect(formatSpendDay(DateTime.utc(2026, 1, 5)), '2026-01-05');
    });
  });

  group('le nom affiché dans la comptabilité', () {
    const names = {'uid-1': 'Frédéric China', 'uid-2': '  '};

    test('un compte connu porte son nom', () {
      expect(spendUserLabel('uid-1', names), 'Frédéric China');
    });

    test('« system » se nomme pour ce qu\'il est', () {
      // Ce n'est pas un compte : c'est l'uid des appels lancés sans personne
      // derrière. Affiché tel quel, il se lisait comme un membre de la famille.
      expect(spendUserLabel('system', names), 'Tâches automatiques (système)');
    });

    test('un compte supprimé garde son identifiant', () {
      // La seule trace qu'il en reste. L'effacer ferait disparaître une
      // dépense réelle de la lecture.
      expect(spendUserLabel('uid-parti', names), 'uid-parti');
    });

    test('un nom vide ne remplace pas l\'identifiant', () {
      expect(spendUserLabel('uid-2', names), 'uid-2');
    });
  });
}
