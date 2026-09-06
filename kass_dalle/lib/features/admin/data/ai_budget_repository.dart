import 'package:cloud_functions/cloud_functions.dart';

import '../../../core/services/error_report_service.dart';

/// Plafonds de dépense d'IA, tels que le serveur les applique.
///
/// Le plafond se règle en **euros**, la monnaie du foyer, alors que les
/// fournisseurs facturent en dollars : la comparaison passe par le taux relevé
/// sur la facture. Sans taux, le plafond monétaire devient inapplicable — et
/// c'est le plafond en **nombre d'appels** qui tient, lui qui ne dépend ni d'un
/// prix ni d'un taux.
class AiBudgetPolicy {
  /// Plafond quotidien par compte, en euros. `0` désactive ce critère.
  final double dailyCostEurPerUser;

  /// Plafond quotidien d'appels par compte. `0` désactive ce critère.
  final int dailyCallsPerUser;

  /// Seuil d'alerte mensuel, tous comptes confondus, en euros. `0` = aucune.
  final double monthlyAlertEur;

  /// Coupe les deux plafonds sans les effacer — le temps d'un import massif.
  final bool enabled;

  const AiBudgetPolicy({
    required this.dailyCostEurPerUser,
    required this.dailyCallsPerUser,
    required this.monthlyAlertEur,
    required this.enabled,
  });

  AiBudgetPolicy copyWith({
    double? dailyCostEurPerUser,
    int? dailyCallsPerUser,
    double? monthlyAlertEur,
    bool? enabled,
  }) {
    return AiBudgetPolicy(
      dailyCostEurPerUser: dailyCostEurPerUser ?? this.dailyCostEurPerUser,
      dailyCallsPerUser: dailyCallsPerUser ?? this.dailyCallsPerUser,
      monthlyAlertEur: monthlyAlertEur ?? this.monthlyAlertEur,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toMap() => {
    'dailyCostEurPerUser': dailyCostEurPerUser,
    'dailyCallsPerUser': dailyCallsPerUser,
    'monthlyAlertEur': monthlyAlertEur,
    'enabled': enabled,
  };

  static AiBudgetPolicy fromMap(Map<String, dynamic> map) {
    return AiBudgetPolicy(
      dailyCostEurPerUser:
          (map['dailyCostEurPerUser'] as num?)?.toDouble() ?? 0,
      dailyCallsPerUser: (map['dailyCallsPerUser'] as num?)?.toInt() ?? 0,
      monthlyAlertEur: (map['monthlyAlertEur'] as num?)?.toDouble() ?? 0,
      // Absent vaut actif : un plafond qui s'éteindrait faute de champ ne
      // protégerait plus, et rien ne le dirait.
      enabled: map['enabled'] != false,
    );
  }
}

/// Dépense d'un poste, pour un compte et sur la période demandée.
class FeatureSpend {
  final String feature;
  final double costUsd;
  final int calls;

  const FeatureSpend({
    required this.feature,
    required this.costUsd,
    required this.calls,
  });
}

/// Dépense d'un compte sur la période, avec sa ventilation par poste.
class UserSpend {
  final String uid;

  /// Nom d'affichage, ou l'identifiant quand le compte n'existe plus.
  final String label;
  final double costUsd;
  final int calls;
  final List<FeatureSpend> byFeature;

  const UserSpend({
    required this.uid,
    required this.label,
    required this.costUsd,
    required this.calls,
    required this.byFeature,
  });
}

/// Un jour `AAAA-MM-JJ` en date UTC, ou `null` si la chaîne n'a pas cette forme.
///
/// Le serveur reste juge de ce qu'il lit : cette lecture ne sert qu'à naviguer
/// — reculer d'un jour, ouvrir le calendrier sur la bonne case. Un 31 février
/// est refusé plutôt que normalisé en mars, sans quoi les flèches feraient
/// glisser d'un mois sans le dire.
DateTime? parseSpendDay(String day) {
  final parts = day.split('-');
  if (parts.length != 3) return null;
  final year = int.tryParse(parts[0]);
  final month = int.tryParse(parts[1]);
  final dayOfMonth = int.tryParse(parts[2]);
  if (year == null || month == null || dayOfMonth == null) return null;
  final parsed = DateTime.utc(year, month, dayOfMonth);
  if (parsed.month != month || parsed.day != dayOfMonth) return null;
  return parsed;
}

/// Une date en `AAAA-MM-JJ`, la forme que le serveur attend.
String formatSpendDay(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

/// L'uid que portent les appels lancés sans personne derrière.
///
/// Enrichissement du référentiel nutritionnel, tâches planifiées, backfills :
/// ils consomment de l'IA et se comptent, mais aucun membre de la famille ne
/// les a demandés.
const kSystemSpendUid = 'system';

/// Le nom sous lequel un compte apparaît dans la comptabilité.
///
/// Trois cas. Un compte connu porte son nom. [kSystemSpendUid] n'est pas un
/// compte, et se nomme donc pour ce qu'il est. Un compte supprimé garde son
/// identifiant : c'est la seule trace qu'il en reste, et l'effacer ferait
/// disparaître une dépense réelle de la lecture.
String spendUserLabel(String uid, Map<String, String> names) {
  if (uid == kSystemSpendUid) return 'Tâches automatiques (système)';
  final name = names[uid]?.trim() ?? '';
  return name.isEmpty ? uid : name;
}

/// La période que couvre le tableau des dépenses.
///
/// Deux sources derrière ce choix : l'agrégat mensuel, qui ne sait rien dire
/// d'un jour, et la ligne d'appel, qui porte l'heure. Le mois reste le mode
/// courant ; la journée se demande, et coûte une lecture par appel.
enum SpendScope { months, day }

/// Ce qu'un compte a consommé aujourd'hui — la seule unité où un plafond
/// quotidien a du sens.
class DailySpendRow {
  final String uid;

  /// Nom d'affichage, ou l'identifiant quand le compte n'existe plus.
  final String label;

  final double costUsd;
  final int calls;

  /// Appels passés pendant une panne de grille : comptés, jamais chiffrés.
  ///
  /// Affichés à part parce qu'ils rendent le montant **incomplet** : sans eux,
  /// une journée traversée par une panne paraîtrait simplement économe.
  final int unpricedCalls;

  const DailySpendRow({
    required this.uid,
    required this.label,
    required this.costUsd,
    required this.calls,
    required this.unpricedCalls,
  });
}

class AiBudgetSnapshot {
  final AiBudgetPolicy policy;

  /// Taux dollar → euro relevé sur la facture, `null` si aucun.
  ///
  /// `null` n'est pas un détail d'affichage : c'est l'état où le plafond en
  /// euros ne s'applique pas, et où seul le compteur d'appels protège.
  final double? usdToEur;

  /// Le compte qui dispose du multiplicateur, et sa valeur.
  final String? founderUid;
  final int founderMultiplier;

  /// Jour UTC couvert par [today], au format `AAAA-MM-JJ`.
  ///
  /// Pas forcément aujourd'hui : l'écran peut demander un jour passé. C'est le
  /// serveur qui tranche — il refuse une date impossible ou à venir et retombe
  /// alors sur le jour courant.
  final String day;

  /// Le jour courant sur le serveur, au format `AAAA-MM-JJ`.
  ///
  /// Il voyage à côté de [day] plutôt que d'être recalculé ici : le plafond
  /// s'applique sur le jour UTC du serveur, et un client dont l'horloge avance
  /// afficherait « aujourd'hui » sur une journée déjà close.
  final String currentDay;

  /// Ce que [spends] couvre réellement : des mois entiers, ou la journée [day].
  ///
  /// Vient du serveur et n'est pas déduit de ce que l'écran a demandé : le
  /// serveur refuse un jour à venir et retombe sur aujourd'hui. Un tableau
  /// titré « journée du 7 » qui montrerait le 6 se lirait comme une journée
  /// vide.
  final SpendScope spendScope;

  /// Journée coupée au plafond de lignes lues.
  ///
  /// Le total affiché est alors plus bas que la dépense réelle. Un coût
  /// manquant se voit, un coût faux ne se voit pas : l'écran le dit.
  final bool spendsTruncated;

  /// Mois réellement lus pour [spends]. Vide sur une journée.
  final List<String> periods;

  /// Mois trop anciens pour porter la ventilation par poste.
  ///
  /// Elle n'est écrite que depuis la v0.20.21 : avant, un mois ne connaît que
  /// le total par compte. Le dire vaut mieux qu'un détail vide, qui se lirait
  /// « rien dépensé ». Une reconstruction des agrégats les rattrape.
  final List<String> periodsWithoutBreakdown;

  final List<UserSpend> spends;
  final List<DailySpendRow> today;

  const AiBudgetSnapshot({
    required this.policy,
    required this.usdToEur,
    required this.founderUid,
    required this.founderMultiplier,
    required this.day,
    required this.currentDay,
    required this.spendScope,
    required this.spendsTruncated,
    required this.periods,
    required this.periodsWithoutBreakdown,
    required this.spends,
    required this.today,
  });

  /// Le jour regardé est la journée en cours.
  ///
  /// Ce que le plafond dit n'est vrai qu'ici : sur une journée close, les
  /// barres rapportent une dépense passée au plafond d'aujourd'hui, qui n'est
  /// pas forcément celui qui s'appliquait alors.
  bool get isToday => day == currentDay;

  /// Le plafond applicable à un compte, multiplicateur du fondateur compris.
  double costLimitEurFor(String uid) =>
      policy.dailyCostEurPerUser * (uid == founderUid ? founderMultiplier : 1);

  int callsLimitFor(String uid) =>
      policy.dailyCallsPerUser * (uid == founderUid ? founderMultiplier : 1);
}

class AiBudgetRepository {
  final FirebaseFunctions _functions;
  final ErrorReportService _errorReportService;

  AiBudgetRepository({
    FirebaseFunctions? functions,
    ErrorReportService? errorReportService,
  }) : _functions =
           functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1'),
       _errorReportService = errorReportService ?? ErrorReportService();

  /// [depth] : nombre de mois à lire, `null` pour tout l'historique — la même
  /// convention que les deux autres onglets de la comptabilité.
  ///
  /// [day] : le jour UTC dont on veut la dépense, `AAAA-MM-JJ`. `null` pour la
  /// journée en cours. Le serveur reste juge : une date à venir ou impossible
  /// retombe sur aujourd'hui, et le jour réellement lu revient dans
  /// [AiBudgetSnapshot.day].
  ///
  /// [scope] : ce que le TABLEAU couvre. [SpendScope.day] le ramène à la seule
  /// journée [day], lue sur la ligne d'appel. Le plafond, lui, porte toujours
  /// sur cette journée, quel que soit le mode.
  Future<AiBudgetSnapshot> fetch({
    int? depth,
    String? day,
    SpendScope scope = SpendScope.months,
  }) async {
    try {
      final raw = await _functions
          .httpsCallable('getAiBudgetFn')
          .call<Map<String, dynamic>>({
            'depth': depth,
            'day': day,
            'scope': scope == SpendScope.day ? 'day' : 'months',
          });
      return _parse(Map<String, dynamic>.from(raw.data));
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'aiBudget.fetch',
        error: e,
        stackTrace: st,
        context: {
          'depth': depth?.toString() ?? 'all',
          'day': day ?? 'today',
          'scope': scope.name,
        },
      );
      rethrow;
    }
  }

  Future<AiBudgetPolicy> save(AiBudgetPolicy policy) async {
    try {
      final raw = await _functions
          .httpsCallable('setAiBudgetFn')
          .call<Map<String, dynamic>>({'policy': policy.toMap()});
      final data = Map<String, dynamic>.from(raw.data);
      return AiBudgetPolicy.fromMap(
        Map<String, dynamic>.from(data['policy'] as Map? ?? const {}),
      );
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'aiBudget.save',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  AiBudgetSnapshot _parse(Map<String, dynamic> data) {
    final rawNames = Map<String, dynamic>.from(
      data['names'] as Map? ?? const {},
    );
    final names = <String, String>{
      for (final entry in rawNames.entries)
        if (entry.value is String) entry.key: entry.value as String,
    };

    final spends = (data['spends'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => Map<String, dynamic>.from(e))
        .map((e) {
          final uid = e['uid'] as String? ?? '';
          final rawFeatures = Map<String, dynamic>.from(
            e['byFeature'] as Map? ?? const {},
          );
          final features =
              rawFeatures.entries
                  .map(
                    (entry) => FeatureSpend(
                      feature: entry.key,
                      costUsd:
                          ((entry.value as Map?)?['costUsd'] as num?)
                              ?.toDouble() ??
                          0,
                      calls:
                          ((entry.value as Map?)?['calls'] as num?)?.toInt() ??
                          0,
                    ),
                  )
                  .toList()
                ..sort((a, b) => b.costUsd.compareTo(a.costUsd));

          return UserSpend(
            uid: uid,
            label: spendUserLabel(uid, names),
            costUsd: (e['costUsd'] as num?)?.toDouble() ?? 0,
            calls: (e['calls'] as num?)?.toInt() ?? 0,
            byFeature: features,
          );
        })
        .toList(growable: false);

    return AiBudgetSnapshot(
      policy: AiBudgetPolicy.fromMap(
        Map<String, dynamic>.from(data['policy'] as Map? ?? const {}),
      ),
      usdToEur: (data['usdToEur'] as num?)?.toDouble(),
      founderUid: data['founderUid'] as String?,
      founderMultiplier: (data['founderMultiplier'] as num?)?.toInt() ?? 1,
      day: data['day'] as String? ?? '',
      // Un serveur d'avant cette lecture n'envoie pas le jour courant : le jour
      // regardé fait alors office, et l'écran se comporte comme avant — il
      // montre aujourd'hui, et ne propose rien d'autre.
      currentDay: data['currentDay'] as String? ?? data['day'] as String? ?? '',
      // Un serveur d'avant la lecture par journée ne connaît que les mois : ce
      // qu'il rend est un tableau mensuel, et l'écran l'affiche comme tel
      // plutôt que de titrer une journée qu'il n'a pas lue.
      spendScope: data['spendScope'] == 'day'
          ? SpendScope.day
          : SpendScope.months,
      spendsTruncated: data['spendsTruncated'] == true,
      periods: (data['periods'] as List? ?? const [])
          .map((e) => e.toString())
          .toList(growable: false),
      periodsWithoutBreakdown:
          (data['periodsWithoutBreakdown'] as List? ?? const [])
              .map((e) => e.toString())
              .toList(growable: false),
      spends: spends,
      today: (data['today'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .map((e) {
            final uid = e['uid'] as String? ?? '';
            return DailySpendRow(
              uid: uid,
              label: spendUserLabel(uid, names),
              costUsd: (e['costUsd'] as num?)?.toDouble() ?? 0,
              calls: (e['calls'] as num?)?.toInt() ?? 0,
              unpricedCalls: (e['unpricedCalls'] as num?)?.toInt() ?? 0,
            );
          })
          .toList(growable: false),
    );
  }
}
