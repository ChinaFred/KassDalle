import 'package:cloud_functions/cloud_functions.dart';

import '../../../core/services/error_report_service.dart';

/// Coûts de l'application, mois par mois.
///
/// Tout vient du serveur, déjà agrégé et déjà chiffré. Les écrans ne
/// recalculent plus rien : le coût d'un appel est figé au moment où il a lieu,
/// par la grille tarifaire du backend. La version précédente relisait chaque
/// ligne d'appel — plafonnée à mille — et appliquait la grille Dart par-dessus.
/// Deux grilles pour un même appel finissent toujours par diverger, et un
/// plafond de lecture transforme un total en échantillon sans le dire.

/// Part d'un moteur dans un poste fonctionnel.
class FeatureProviderCost {
  final double costUsd;
  final int calls;
  final int inputTokens;
  final int outputTokens;

  /// Jetons de raisonnement, facturés au tarif de sortie.
  final int thinkingTokens;

  const FeatureProviderCost({
    required this.costUsd,
    required this.calls,
    required this.inputTokens,
    required this.outputTokens,
    required this.thinkingTokens,
  });

  static const empty = FeatureProviderCost(
    costUsd: 0,
    calls: 0,
    inputTokens: 0,
    outputTokens: 0,
    thinkingTokens: 0,
  );

  /// Coût moyen d'un appel — la grandeur qui rend deux moteurs comparables.
  ///
  /// Un poste peut coûter cher parce qu'il est appelé souvent ou parce que
  /// chaque appel est lourd ; le total seul ne distingue pas les deux.
  double get unitCostUsd => calls > 0 ? costUsd / calls : 0;

  FeatureProviderCost operator +(FeatureProviderCost other) =>
      FeatureProviderCost(
        costUsd: costUsd + other.costUsd,
        calls: calls + other.calls,
        inputTokens: inputTokens + other.inputTokens,
        outputTokens: outputTokens + other.outputTokens,
        thinkingTokens: thinkingTokens + other.thinkingTokens,
      );

  factory FeatureProviderCost.fromMap(Map<String, dynamic> data) =>
      FeatureProviderCost(
        costUsd: _toDouble(data['cost_usd']),
        calls: _toInt(data['calls']),
        inputTokens: _toInt(data['input_tokens']),
        outputTokens: _toInt(data['output_tokens']),
        thinkingTokens: _toInt(data['thinking_tokens']),
      );
}

/// Consommation d'un poste fonctionnel sur un mois.
class FeatureCost {
  final String feature;
  final double costUsd;
  final int calls;
  final int inputTokens;
  final int outputTokens;
  final int thinkingTokens;
  final int imageOutputs;

  /// Détail par moteur à l'intérieur du poste — ce qui permet de juger une
  /// bascule : sans lui, on voit le coût monter sans savoir lequel des deux
  /// moteurs le fait monter.
  final Map<String, FeatureProviderCost> byProvider;

  const FeatureCost({
    required this.feature,
    required this.costUsd,
    required this.calls,
    required this.inputTokens,
    required this.outputTokens,
    required this.thinkingTokens,
    required this.imageOutputs,
    required this.byProvider,
  });

  FeatureProviderCost provider(String name) =>
      byProvider[name] ?? FeatureProviderCost.empty;

  /// Coût moyen d'un appel, tous moteurs confondus.
  double get unitCostUsd => calls > 0 ? costUsd / calls : 0;

  factory FeatureCost.fromMap(String feature, Map<String, dynamic> data) {
    final providers = <String, FeatureProviderCost>{};
    final raw = data['by_provider'];
    if (raw is Map) {
      for (final entry in raw.entries) {
        final value = entry.value;
        if (value is Map) {
          providers[entry.key.toString()] = FeatureProviderCost.fromMap(
            Map<String, dynamic>.from(value),
          );
        }
      }
    }
    return FeatureCost(
      feature: feature,
      costUsd: _toDouble(data['cost_usd']),
      calls: _toInt(data['calls']),
      inputTokens: _toInt(data['input_tokens']),
      outputTokens: _toInt(data['output_tokens']),
      thinkingTokens: _toInt(data['thinking_tokens']),
      imageOutputs: _toInt(data['image_outputs']),
      byProvider: providers,
    );
  }
}

/// Ce qu'un moteur d'IA a consommé et coûté sur un mois.
///
/// Deux mesures de la même dépense cohabitent ici sans jamais s'additionner :
/// ce que nous avons estimé au moment de l'appel, et ce que le fournisseur a
/// réellement facturé. Les sommer compterait la dépense deux fois ; ne garder
/// que l'estimation laisserait une dérive s'installer sans témoin.
class ProviderCost {
  final double estimatedUsd;

  /// Facturé par le fournisseur, ou null quand la facture est illisible.
  ///
  /// `null` n'est pas zéro : un export en panne ne prouve pas une dépense nulle.
  final double? billedUsd;

  final int calls;
  final int inputTokens;
  final int outputTokens;

  /// Jetons de raisonnement : invisibles dans la réponse, facturés au tarif de
  /// sortie. Les compter à part est ce qui distingue un poste qui produit
  /// beaucoup d'un poste qui fait beaucoup réfléchir.
  final int thinkingTokens;

  /// Jetons de prompt passés par le cache : écrits, puis relus.
  ///
  /// Ce sont des jetons d'entrée que le fournisseur compte à part et facture à
  /// un autre tarif — 1,25 fois l'entrée à l'écriture, un dixième à la
  /// relecture. Aucun prompt du projet ne demande de cache : ils devraient donc
  /// rester à zéro, et l'écran ne les montre que s'ils ne le sont pas.
  final int cacheWriteTokens;
  final int cacheReadTokens;

  /// Le détail de la facture du fournisseur, ligne par ligne.
  ///
  /// Un écart réduit à un seul nombre ne se diagnostique pas. Rapproché des
  /// lignes de la facture, il désigne le poste sous-compté.
  final List<BilledLine> billedLines;

  /// Instant du relevé du montant facturé, ou null s'il n'a jamais été relevé.
  ///
  /// Un montant facturé est une photographie ; nos compteurs, eux, sont
  /// vivants. Comparer les deux sans dire l'âge du relevé fabrique un écart
  /// qui n'est qu'un décalage d'horloge.
  final DateTime? billedAt;

  /// Jetons réellement facturés, `null` quand le fournisseur ne les détaille pas.
  ///
  /// C'est la confrontation qui explique un écart : un écart en euros
  /// n'apprend rien, deux millions de jetons de sortie facturés contre trois
  /// cent mille comptés désignent le raisonnement sans ambiguïté.
  final int? billedInputTokens;
  final int? billedOutputTokens;

  const ProviderCost({
    required this.estimatedUsd,
    required this.billedUsd,
    required this.calls,
    required this.inputTokens,
    required this.outputTokens,
    required this.thinkingTokens,
    this.cacheWriteTokens = 0,
    this.cacheReadTokens = 0,
    this.billedAt,
    this.billedLines = const [],
    this.billedInputTokens,
    this.billedOutputTokens,
  });

  /// Vrai quand le relevé est trop ancien pour que l'écart signifie quelque
  /// chose : de la consommation a très probablement eu lieu depuis.
  ///
  /// Deux heures — le relevé du mois courant est rafraîchi toutes les six.
  bool get billedIsDated {
    final at = billedAt;
    if (at == null) return false;
    return DateTime.now().difference(at) > const Duration(hours: 2);
  }

  /// Jetons de sortie facturés que l'application n'a pas comptés.
  ///
  /// `null` quand la comparaison n'est pas possible. Positif, c'est de la
  /// consommation invisible ; c'est par là qu'un écart s'explique avant de se
  /// corriger.
  int? get uncountedOutputTokens {
    final billed = billedOutputTokens;
    if (billed == null || billed == 0) return null;
    final counted = outputTokens + thinkingTokens;
    final missing = billed - counted;
    return missing > 0 ? missing : null;
  }

  static const empty = ProviderCost(
    estimatedUsd: 0,
    billedUsd: null,
    calls: 0,
    inputTokens: 0,
    outputTokens: 0,
    thinkingTokens: 0,
  );

  int get totalTokens =>
      inputTokens +
      outputTokens +
      thinkingTokens +
      cacheWriteTokens +
      cacheReadTokens;

  /// Le montant retenu pour les totaux : le facturé s'il existe, l'estimé sinon.
  double get effectiveUsd => billedUsd ?? estimatedUsd;

  /// Écart entre facturé et estimé, ou null si l'un des deux manque.
  double? get deltaUsd {
    final billed = billedUsd;
    if (billed == null) return null;
    return billed - estimatedUsd;
  }

  /// Écart relatif à la facture, ou null quand il n'est pas calculable.
  double? get deltaRatio {
    final billed = billedUsd;
    if (billed == null || billed == 0) return null;
    return (billed - estimatedUsd) / billed;
  }

  /// Vrai quand le moteur n'a ni consommé ni été facturé : rien à afficher.
  bool get isEmpty => calls == 0 && estimatedUsd == 0 && (billedUsd ?? 0) == 0;

  factory ProviderCost.fromMap(Map<String, dynamic> data) => ProviderCost(
    estimatedUsd: _toDouble(data['estimatedUsd']),
    billedUsd: data['billedUsd'] == null ? null : _toDouble(data['billedUsd']),
    calls: _toInt(data['calls']),
    inputTokens: _toInt(data['inputTokens']),
    outputTokens: _toInt(data['outputTokens']),
    thinkingTokens: _toInt(data['thinkingTokens']),
    cacheWriteTokens: _toInt(data['cacheWriteTokens']),
    cacheReadTokens: _toInt(data['cacheReadTokens']),
    billedAt: data['billedAtMs'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(_toInt(data['billedAtMs'])),
    billedLines: (data['billedLines'] as List? ?? const [])
        .whereType<Map>()
        .map((e) => BilledLine.fromMap(Map<String, dynamic>.from(e)))
        .toList(growable: false),
    billedInputTokens: data['billedInputTokens'] == null
        ? null
        : _toInt(data['billedInputTokens']),
    billedOutputTokens: data['billedOutputTokens'] == null
        ? null
        : _toInt(data['billedOutputTokens']),
  );
}

/// Une ligne de la facture du fournisseur, telle qu'il la libelle.
class BilledLine {
  final String label;
  final double costUsd;

  /// Quantité facturée et son unité, quand le fournisseur les renseigne.
  final double amount;
  final String unit;

  const BilledLine({
    required this.label,
    required this.costUsd,
    required this.amount,
    required this.unit,
  });

  factory BilledLine.fromMap(Map<String, dynamic> data) => BilledLine(
    label: data['sku']?.toString() ?? 'Ligne non libellée',
    costUsd: _toDouble(data['costUsd']),
    amount: _toDouble(data['amount']),
    unit: data['unit']?.toString() ?? '',
  );
}

/// Premier jour où les jetons de raisonnement sont comptés.
///
/// Gemini 2.5 Flash raisonne par défaut et facture ces jetons au tarif de
/// sortie ; l'application ne les lisait pas avant cette date. Pour un mois
/// entièrement antérieur, l'écart n'est donc pas une anomalie à instruire mais
/// un fait acquis : la donnée n'a jamais été enregistrée, aucune
/// reconstruction ne la fera apparaître. Le signaler en rouge indéfiniment
/// reviendrait à demander d'enquêter sur une cause déjà connue — et à noyer
/// le jour où un vrai écart se produira.
final DateTime thinkingCountedSince = DateTime.utc(2026, 8, 14);

/// Ce qu'un fournisseur a offert sur un modèle, pour un mois donné.
///
/// La franchise est **mensuelle**, jamais par appel : deux appels identiques ne
/// peuvent pas finir à deux prix selon leur rang dans le mois. Elle arrive donc
/// à part du coût, et s'affiche sur sa propre ligne — une remise fondue dans un
/// total est une remise que personne ne peut vérifier.
class FreeTierCredit {
  final String model;

  /// Unités consommées dans le mois.
  final int units;

  /// Unités offertes chaque mois par le fournisseur.
  final int freeUnits;

  /// Unités effectivement couvertes — jamais plus que consommées.
  final int coveredUnits;

  /// Avoir en dollars, à retrancher du mois.
  final double creditUsd;

  const FreeTierCredit({
    required this.model,
    required this.units,
    required this.freeUnits,
    required this.coveredUnits,
    required this.creditUsd,
  });

  factory FreeTierCredit.fromMap(Map<String, dynamic> data) => FreeTierCredit(
    model: data['model']?.toString() ?? '',
    units: _toInt(data['units']),
    freeUnits: _toInt(data['freeUnits']),
    coveredUnits: _toInt(data['coveredUnits']),
    creditUsd: _toDouble(data['creditUsd']),
  );

  /// Vrai quand la franchise est entièrement consommée : au-delà, chaque unité
  /// est facturée. C'est le moment où la remise cesse de croître.
  bool get exhausted => units >= freeUnits;
}

/// Coût d'un service d'infrastructure sur un mois.
class ServiceCost {
  final String service;
  final double costUsd;

  const ServiceCost({required this.service, required this.costUsd});
}

/// Ce que l'application a coûté sur un mois donné.
class MonthlyCost {
  /// `AAAA-MM`.
  final String period;

  /// Taux USD → EUR de ce mois-là, tel que Google l'a appliqué à sa facture.
  ///
  /// Un taux par mois, pas un taux global : convertir une dépense de l'an
  /// dernier au cours d'aujourd'hui donne un montant que personne n'a payé.
  final double usdToEur;

  final double aiCostUsd;
  final int aiCalls;

  /// Appels partis chez le fournisseur puis échoués : facturés sans rien rendre.
  final int failedCalls;

  final int inputTokens;
  final int outputTokens;
  final int thinkingTokens;
  final int imageOutputs;

  /// Unités d'image ANALYSÉE consommées — la modération, facturée à l'unité.
  ///
  /// Vaut zéro pour les mois antérieurs à leur comptage : la donnée n'a jamais
  /// été enregistrée, et aucune reconstruction ne la fera apparaître. Un mois
  /// sans unités comptées ne reçoit donc aucune franchise, ce qui est exact.
  final int analyzedImageUnits;

  /// Ce que les fournisseurs ont offert ce mois-ci, modèle par modèle.
  final List<FreeTierCredit> freeTier;

  /// Somme des avoirs du mois.
  final double freeTierUsd;

  final List<FeatureCost> features;

  /// Claude et Gemini, rendus sous la même forme pour être comparables.
  final ProviderCost anthropic;
  final ProviderCost gemini;

  /// Ce qui n'est pas de l'inférence — scan de sécurité, traitements internes.
  final ProviderCost internal;

  /// Coût IA par utilisateur.
  final Map<String, double> costByUser;

  /// Infrastructure : Functions, Storage, Tasks, BigQuery… L'inférence Gemini
  /// en est retirée, elle a sa propre section.
  final List<ServiceCost> services;
  final double gcpCostUsd;

  /// Total du mois, calculé par le serveur : facturé quand il est connu,
  /// estimé sinon.
  final double totalCostUsd;

  const MonthlyCost({
    required this.period,
    required this.usdToEur,
    required this.aiCostUsd,
    required this.aiCalls,
    required this.failedCalls,
    required this.inputTokens,
    required this.outputTokens,
    required this.thinkingTokens,
    required this.imageOutputs,
    required this.analyzedImageUnits,
    required this.freeTier,
    required this.freeTierUsd,
    required this.features,
    required this.anthropic,
    required this.gemini,
    required this.internal,
    required this.costByUser,
    required this.services,
    required this.gcpCostUsd,
    required this.totalCostUsd,
  });

  /// Jetons consommés sur le mois, raisonnement compris.
  int get totalTokens => inputTokens + outputTokens + thinkingTokens;

  /// Estimation IA une fois les franchises retranchées.
  ///
  /// [aiCostUsd] reste brut : c'est la somme de ce que les appels ont coûté, et
  /// c'est elle qui se rapproche des ventilations par poste et par moteur. Le
  /// net est ce qui se compare à une facture.
  double get aiNetCostUsd => aiCostUsd - freeTierUsd;

  /// Ce qu'Anthropic a réellement facturé, ou null si inconnu.
  double? get anthropicBilledUsd => anthropic.billedUsd;

  /// Année de la période, pour les regroupements annuels.
  String get year => period.split('-').first;

  /// Premier instant du mois suivant, en UTC — la borne de fin du mois.
  DateTime? get _endsAt {
    final parts = period.split('-');
    if (parts.length != 2) return null;
    final year = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    if (year == null || month == null) return null;
    return DateTime.utc(year, month + 1, 1);
  }

  /// Vrai quand le mois s'achève avant le comptage du raisonnement : son écart
  /// Gemini est définitif, et aucune reconstruction ne le réduira.
  bool get predatesThinkingCount {
    final end = _endsAt;
    return end != null && !end.isAfter(thinkingCountedSince);
  }

  /// Vrai quand le comptage du raisonnement a commencé **pendant** ce mois :
  /// une partie des appels le porte, l'autre non.
  bool get spansThinkingCount {
    final end = _endsAt;
    if (end == null) return false;
    final start = DateTime.utc(end.year, end.month - 1, 1);
    return start.isBefore(thinkingCountedSince) &&
        end.isAfter(thinkingCountedSince);
  }

  /// Libellé court du mois, ex. « août 2026 ».
  String get label {
    final parts = period.split('-');
    if (parts.length != 2) return period;
    const mois = [
      'janvier',
      'février',
      'mars',
      'avril',
      'mai',
      'juin',
      'juillet',
      'août',
      'septembre',
      'octobre',
      'novembre',
      'décembre',
    ];
    final index = int.tryParse(parts[1]) ?? 0;
    if (index < 1 || index > 12) return period;
    return '${mois[index - 1]} ${parts[0]}';
  }

  factory MonthlyCost.fromMap(Map<String, dynamic> data) {
    final ai = Map<String, dynamic>.from(data['ai'] as Map? ?? const {});
    final gcp = Map<String, dynamic>.from(data['gcp'] as Map? ?? const {});

    final features = <FeatureCost>[];
    final rawFeatures = ai['byFeature'];
    if (rawFeatures is Map) {
      for (final entry in rawFeatures.entries) {
        final value = entry.value;
        if (value is Map) {
          features.add(
            FeatureCost.fromMap(
              entry.key.toString(),
              Map<String, dynamic>.from(value),
            ),
          );
        }
      }
    }
    features.sort((a, b) => b.costUsd.compareTo(a.costUsd));

    final services = <ServiceCost>[];
    final rawServices = gcp['services'];
    if (rawServices is List) {
      for (final entry in rawServices) {
        if (entry is Map) {
          services.add(
            ServiceCost(
              service: entry['service']?.toString() ?? 'Autre',
              costUsd: _toDouble(entry['costUsd']),
            ),
          );
        }
      }
    }

    final freeTier = <FreeTierCredit>[];
    final rawFreeTier = ai['freeTier'];
    if (rawFreeTier is List) {
      for (final entry in rawFreeTier) {
        if (entry is Map) {
          freeTier.add(
            FreeTierCredit.fromMap(Map<String, dynamic>.from(entry)),
          );
        }
      }
    }

    final gcpCostUsd = _toDouble(gcp['totalCostUsd']);
    final aiCostUsd = _toDouble(ai['totalCostUsd']);

    return MonthlyCost(
      period: data['period']?.toString() ?? '',
      usdToEur: _toDouble(data['usdToEur']),
      aiCostUsd: aiCostUsd,
      aiCalls: _toInt(ai['calls']),
      failedCalls: _toInt(ai['failedCalls']),
      inputTokens: _toInt(ai['inputTokens']),
      outputTokens: _toInt(ai['outputTokens']),
      thinkingTokens: _toInt(ai['thinkingTokens']),
      imageOutputs: _toInt(ai['imageOutputs']),
      analyzedImageUnits: _toInt(ai['analyzedImageUnits']),
      freeTier: freeTier,
      freeTierUsd: _toDouble(ai['freeTierUsd']),
      features: features,
      anthropic: _provider(data['anthropic']),
      gemini: _provider(data['gemini']),
      internal: _provider(data['internal']),
      costByUser: _costMap(ai['byUser']),
      services: services,
      gcpCostUsd: gcpCostUsd,
      totalCostUsd: data['totalCostUsd'] == null
          ? aiCostUsd + gcpCostUsd
          : _toDouble(data['totalCostUsd']),
    );
  }
}

/// Série mensuelle complète, telle que servie par le backend.
class MonthlyCostsReport {
  final List<MonthlyCost> months;

  /// Taux de dernier recours, pour les mois sans facture Google.
  final double usdToEur;

  /// Vrai quand la facturation Google n'a pas pu être lue : les montants
  /// d'infrastructure de ce rapport ne veulent alors rien dire.
  final bool gcpQueryFailed;

  /// Vrai quand l'historique IA remonte plus loin que la facturation Google :
  /// les mois les plus anciens n'ont alors pas de coût d'infrastructure.
  final bool gcpTruncated;

  /// Vrai quand le rapport de coûts Anthropic a pu être lu.
  final bool anthropicAvailable;

  /// Message d'échec de la lecture Anthropic, ou null.
  final String? anthropicError;

  /// Vrai quand les montants Anthropic viennent du cache, la relecture ayant
  /// échoué. Les mois clos restent justes ; seul le mois courant peut avoir
  /// bougé depuis.
  final bool anthropicStale;

  /// Vrai quand tous les mois n'ont pas encore été relevés chez Anthropic.
  ///
  /// La lecture est volontairement bornée par affichage pour ménager la limite
  /// de débit : elle se complète d'elle-même aux affichages suivants. Ce n'est
  /// pas une panne, et l'écran ne doit pas l'annoncer comme telle.
  final bool anthropicPartial;

  const MonthlyCostsReport({
    required this.months,
    required this.usdToEur,
    required this.gcpQueryFailed,
    this.gcpTruncated = false,
    this.anthropicAvailable = false,
    this.anthropicError,
    this.anthropicStale = false,
    this.anthropicPartial = false,
  });

  double get totalCostUsd =>
      months.fold(0, (sum, month) => sum + month.totalCostUsd);

  /// Jetons consommés sur toute la période affichée.
  int get totalTokens =>
      months.fold(0, (sum, month) => sum + month.totalTokens);

  /// Taux du mois le plus récent qui en porte un — celui du haut de l'écran.
  double get latestRate {
    for (final month in months.reversed) {
      if (month.usdToEur > 0) return month.usdToEur;
    }
    return usdToEur;
  }

  /// Les mois regroupés par année, de la plus récente à la plus ancienne.
  Map<String, List<MonthlyCost>> get byYear {
    final grouped = <String, List<MonthlyCost>>{};
    for (final month in months) {
      grouped.putIfAbsent(month.year, () => []).add(month);
    }
    return Map.fromEntries(
      grouped.entries.toList()..sort((a, b) => b.key.compareTo(a.key)),
    );
  }
}

class MonthlyCostsRepository {
  final FirebaseFunctions _functions;
  final ErrorReportService _errorReportService;

  MonthlyCostsRepository({
    FirebaseFunctions? functions,
    ErrorReportService? errorReportService,
  }) : _functions =
           functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1'),
       _errorReportService = errorReportService ?? ErrorReportService();

  /// Les [months] derniers mois, IA et infrastructure réunies.
  ///
  /// [all] remonte à la première consommation enregistrée. L'IA est alors
  /// complète ; l'infrastructure s'arrête à la fenêtre d'export de la
  /// facturation Google, ce que le rapport signale.
  /// [refreshAnthropicPeriods] relit ces mois chez Anthropic en ignorant le
  /// cache. Ciblé plutôt que global : son API d'administration rend des
  /// journées et limite sévèrement le débit, et relire un seul mois coûte une
  /// requête là où relire l'année en coûte treize.
  Future<MonthlyCostsReport> fetch({
    int months = 12,
    bool all = false,
    List<String> refreshAnthropicPeriods = const [],
  }) async {
    try {
      final result = await _functions
          .httpsCallable('getMonthlyCostsFn')
          .call<dynamic>({
            'months': months,
            if (all) 'all': true,
            if (refreshAnthropicPeriods.isNotEmpty)
              'refreshAnthropicPeriods': refreshAnthropicPeriods,
          });
      final data = Map<String, dynamic>.from(result.data as Map);
      final rawMonths = (data['months'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => MonthlyCost.fromMap(Map<String, dynamic>.from(m)))
          .toList(growable: false);
      return MonthlyCostsReport(
        months: rawMonths,
        usdToEur: _toDouble(data['usdToEur']),
        gcpQueryFailed: data['gcpQueryFailed'] == true,
        gcpTruncated: data['gcpTruncated'] == true,
        anthropicAvailable: data['anthropicAvailable'] == true,
        anthropicError: data['anthropicError'] as String?,
        anthropicStale: data['anthropicStale'] == true,
        anthropicPartial: data['anthropicPartial'] == true,
      );
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'monthly_costs_fetch',
        error: error,
        stackTrace: stackTrace,
        context: {'months': months, 'all': all},
      );
      rethrow;
    }
  }

  /// Reconstruit les agrégats depuis les lignes d'appel.
  ///
  /// Sert au rattrapage de l'historique comme à la réparation d'un mois dont
  /// les compteurs auraient dérivé.
  /// [recomputeCosts] recalcule le coût de chaque appel au lieu de relire celui
  /// qui y a été figé. À n'employer que lorsque la grille tarifaire elle-même
  /// était fausse : c'est la seule réparation possible dans ce cas, et elle
  /// réécrit des montants déjà publiés.
  Future<int> rebuild({int months = 12, bool recomputeCosts = false}) async {
    try {
      final result = await _functions
          .httpsCallable('rebuildAiUsageMonthlyFn')
          .call<dynamic>({
            'months': months,
            if (recomputeCosts) 'recomputeCosts': true,
          });
      final data = Map<String, dynamic>.from(result.data as Map);
      return (data['rebuilt'] as List? ?? const []).length;
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'monthly_costs_rebuild',
        error: error,
        stackTrace: stackTrace,
        context: {'months': months},
      );
      rethrow;
    }
  }
}

ProviderCost _provider(dynamic raw) => raw is Map
    ? ProviderCost.fromMap(Map<String, dynamic>.from(raw))
    : ProviderCost.empty;

Map<String, double> _costMap(dynamic raw) {
  final result = <String, double>{};
  if (raw is Map) {
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is Map) {
        result[entry.key.toString()] = _toDouble(value['cost_usd']);
      }
    }
  }
  return result;
}

double _toDouble(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

int _toInt(dynamic value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
