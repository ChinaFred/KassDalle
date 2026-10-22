import 'package:cloud_functions/cloud_functions.dart';

import '../../../core/services/error_report_service.dart';

/// Fournisseurs d'inférence connus de l'application.
enum AiProvider {
  gemini,
  anthropic,

  /// Cloud Vision — sert la modération d'images, et elle seule.
  ///
  /// Ce n'est pas un moteur comme les deux autres : la modération ne passe pas
  /// par `callModel` et ne se bascule pas. Il figure ici pour que l'écran
  /// puisse NOMMER qui sert ces postes. Sans lui, [fromWire] repliait
  /// « vision » sur Gemini et l'écran affirmait un moteur qui n'a jamais servi
  /// ce poste — un mensonge silencieux, jamais démenti par une erreur.
  vision;

  String get wireName => name;

  String get label => switch (this) {
    AiProvider.gemini => 'Gemini',
    AiProvider.anthropic => 'Claude',
    AiProvider.vision => 'Vision',
  };

  /// Lecture stricte : `null` sur un fournisseur que ce client ne connaît pas.
  ///
  /// Le repli sur Gemini appartient à la politique, où une valeur absente vaut
  /// le moteur par défaut. Il n'a rien à faire dans la lecture d'une liste de
  /// fournisseurs admis : y replier un nom inconnu ferait afficher « Gemini »
  /// pour un moteur dont on ne sait rien.
  static AiProvider? tryFromWire(String? value) => switch (value) {
    'gemini' => AiProvider.gemini,
    'anthropic' => AiProvider.anthropic,
    'vision' => AiProvider.vision,
    _ => null,
  };

  static AiProvider fromWire(String? value) =>
      tryFromWire(value) ?? AiProvider.gemini;
}

/// Poste fonctionnel routable, tel que le backend le déclare.
///
/// La liste vient du serveur et n'est pas dupliquée ici : deux listes de postes
/// finiraient par diverger, et une bascule sur un poste que le backend ignore
/// ne produit aucune erreur — elle ne route simplement rien.
class RoutableFeature {
  final String id;
  final String label;

  /// Famille du poste (Import, Nutrition, Rédaction…).
  ///
  /// Sert uniquement à regrouper l'écran : une trentaine de postes en liste
  /// plate se bascule mal, et un poste qu'on ne retrouve pas est un poste qu'on
  /// ne bascule pas.
  final String group;

  /// Fournisseurs que le serveur accepte pour ce poste, `null` s'il n'en
  /// déclare aucun — auquel cas les deux moteurs routables conviennent.
  ///
  /// Le serveur refuse à l'écriture tout fournisseur hors de cette liste, et
  /// il refuse alors la politique ENTIÈRE. Ignorer ce champ ne coûtait pas
  /// qu'un libellé faux : un clic sur « Tout Claude » écrivait `anthropic` sur
  /// la modération et rendait l'écran insauvegardable, pour les quarante et un
  /// autres postes aussi.
  final List<AiProvider>? providers;

  /// Pourquoi le choix est verrouillé, tel que le serveur le formule.
  final String? lockedReason;

  /// Effort de réflexion Claude que le code du poste demande (`low`,
  /// `medium`, `high`), `null` sur un backend qui ne l'envoie pas.
  ///
  /// C'est ce que le poste reçoit quand ni lui ni le défaut n'ont de réglage
  /// (« Selon le poste (haute) »). La valeur vit côté serveur, dans
  /// `ai/featureEfforts.ts` : ce client ne la recopie pas.
  final String? codeEffort;

  const RoutableFeature({
    required this.id,
    required this.label,
    this.group = 'Autres',
    this.providers,
    this.lockedReason,
    this.codeEffort,
  });

  /// Fournisseurs proposables à l'écran pour ce poste.
  List<AiProvider> get allowedProviders =>
      providers ?? const [AiProvider.gemini, AiProvider.anthropic];

  bool allows(AiProvider provider) => allowedProviders.contains(provider);

  /// Le fournisseur imposé quand il n'y a pas de choix, `null` sinon.
  ///
  /// C'est lui qu'il faut afficher sur un poste verrouillé : sa valeur dans la
  /// politique ne commanderait rien, et le moteur par défaut n'a jamais servi
  /// ce poste.
  AiProvider? get lockedProvider =>
      allowedProviders.length == 1 ? allowedProviders.single : null;
}

/// Lit la liste des postes déclarée par le serveur.
///
/// Fonction de module plutôt que méthode privée : c'est ici qu'un champ oublié
/// ne lève aucune erreur — il disparaît simplement, et l'écran affiche une
/// valeur plausible à la place. Un test la rejoue donc directement.
List<RoutableFeature> parseRoutableFeatures(Object? raw) {
  return (raw as List? ?? const [])
      .whereType<Map>()
      .map((e) {
        final map = Map<String, dynamic>.from(e);
        final declared = map['providers'];
        return RoutableFeature(
          id: map['id'] as String? ?? '',
          label: map['label'] as String? ?? '',
          group: map['group'] as String? ?? 'Autres',
          // Une liste déclarée est conservée même si ce client n'en reconnaît
          // aucune entrée : elle reste vide, le poste n'offre aucun choix, et
          // c'est plus honnête que de proposer les deux moteurs habituels.
          providers: declared is List
              ? declared
                    .map((p) => AiProvider.tryFromWire(p as String?))
                    .nonNulls
                    .toList(growable: false)
              : null,
          lockedReason: map['lockedReason'] as String?,
          codeEffort: _nonEmptyString(map['codeEffort']),
        );
      })
      .where((f) => f.id.isNotEmpty)
      .toList(growable: false);
}

class AiRoutingPolicy {
  final AiProvider defaultProvider;
  final Map<String, AiProvider> features;
  final String anthropicModel;
  final bool fallbackEnabled;

  /// Plafond de jetons de raisonnement pour Gemini, `null` = le modèle décide.
  ///
  /// Le raisonnement est facturé au tarif de sortie sans jamais apparaître
  /// dans une réponse. Sur un mois observé, il pesait 2,1 millions de jetons
  /// sur les 2,4 millions de sortie facturés : c'est le seul réglage qui agit
  /// sur la ligne la plus chère de la facture Gemini.
  final int? thinkingBudget;

  /// Plafond par poste — l'emporte sur le plafond global.
  final Map<String, int> thinkingBudgets;

  /// Modèle Claude par poste — l'emporte sur [anthropicModel].
  ///
  /// Le fournisseur se choisissait poste par poste, le modèle non : basculer
  /// un poste sur Claude imposait le même modèle à tous les autres. Or les
  /// postes n'ont pas les mêmes exigences — transcrire une page de livre
  /// demande de la précision et se paie à la page, estimer les calories d'une
  /// carotte est un rappel de connaissances répété quinze fois par recette.
  final Map<String, String> anthropicModels;

  /// Effort de réflexion Claude par poste — l'emporte sur [anthropicEffort].
  ///
  /// Le modèle se choisissait déjà poste par poste ; l'effort restait une
  /// constante de code, qui ne se changeait qu'en redéployant. Une mesure du
  /// 27 septembre 2026 a montré que, pour la lecture de page, le levier qui
  /// économise vraiment est le modèle — et que l'effort mérite le même geste
  /// sans déploiement.
  final Map<String, String> anthropicEfforts;

  /// Effort de réflexion Claude par défaut, `null` pour « Selon le poste ».
  ///
  /// `null` : un poste sans réglage propre garde l'effort de son code
  /// ([RoutableFeature.codeEffort]). Sinon, cet effort sert les postes sans
  /// réglage propre.
  final String? anthropicEffort;

  const AiRoutingPolicy({
    required this.defaultProvider,
    required this.features,
    required this.anthropicModel,
    required this.fallbackEnabled,
    this.thinkingBudget,
    this.thinkingBudgets = const {},
    this.anthropicModels = const {},
    this.anthropicEfforts = const {},
    this.anthropicEffort,
  });

  AiProvider providerFor(String featureId) =>
      features[featureId] ?? defaultProvider;

  /// Plafond effectif d'un poste : le sien, à défaut le global.
  int? thinkingBudgetFor(String featureId) =>
      thinkingBudgets[featureId] ?? thinkingBudget;

  /// Modèle Claude effectif d'un poste : le sien, à défaut le global.
  String anthropicModelFor(String featureId) =>
      anthropicModels[featureId] ?? anthropicModel;

  /// Effort que reçoit un poste servi par Claude : le sien, à défaut celui de
  /// la politique, à défaut celui de son code. `null` quand aucun n'est connu
  /// (backend qui n'envoie pas l'effort du code).
  ///
  /// Même ordre que `resolveAnthropicEffort` côté serveur, rejoué ici pour
  /// l'affichage seul : le serveur décide de l'appel.
  String? effectiveEffortFor(RoutableFeature feature) =>
      anthropicEfforts[feature.id] ?? anthropicEffort ?? feature.codeEffort;

  AiRoutingPolicy copyWith({
    AiProvider? defaultProvider,
    Map<String, AiProvider>? features,
    String? anthropicModel,
    bool? fallbackEnabled,
    // `null` est une valeur signifiante pour un plafond : un booléen dit
    // explicitement qu'on veut l'effacer, sinon « ne pas toucher » et
    // « remettre à zéro » seraient indistinguables.
    int? thinkingBudget,
    bool clearThinkingBudget = false,
    Map<String, int>? thinkingBudgets,
    Map<String, String>? anthropicModels,
    Map<String, String>? anthropicEfforts,
    // Même raison que le plafond : `null` veut dire « Selon le poste ».
    String? anthropicEffort,
    bool clearAnthropicEffort = false,
  }) {
    return AiRoutingPolicy(
      defaultProvider: defaultProvider ?? this.defaultProvider,
      features: features ?? this.features,
      anthropicModel: anthropicModel ?? this.anthropicModel,
      fallbackEnabled: fallbackEnabled ?? this.fallbackEnabled,
      thinkingBudget: clearThinkingBudget
          ? null
          : (thinkingBudget ?? this.thinkingBudget),
      thinkingBudgets: thinkingBudgets ?? this.thinkingBudgets,
      anthropicModels: anthropicModels ?? this.anthropicModels,
      anthropicEfforts: anthropicEfforts ?? this.anthropicEfforts,
      anthropicEffort: clearAnthropicEffort
          ? null
          : (anthropicEffort ?? this.anthropicEffort),
    );
  }

  Map<String, dynamic> toMap() => {
    'defaultProvider': defaultProvider.wireName,
    'features': {
      for (final entry in features.entries) entry.key: entry.value.wireName,
    },
    'anthropicModel': anthropicModel,
    'fallbackEnabled': fallbackEnabled,
    'thinkingBudget': thinkingBudget,
    'thinkingBudgets': thinkingBudgets,
    'anthropicModels': anthropicModels,
    'anthropicEfforts': anthropicEfforts,
    'anthropicEffort': anthropicEffort,
  };
}

/// Politique de routage accompagnée de ce qu'il faut pour la lire sans se
/// tromper : les postes disponibles, et la présence effective de la clé Claude.
/// Un modèle Claude proposé à l'écran, et ce à quoi il sert.
///
/// Le choix ne se devine pas depuis un identifiant, et le mauvais choix ne se
/// voit ni dans un sens ni dans l'autre : un modèle trop petit rend une page
/// abîmée qui a l'air correcte, un modèle trop grand rend une facture qui a
/// l'air normale.
class AnthropicModelChoice {
  const AnthropicModelChoice({
    required this.id,
    required this.label,
    required this.hint,
    this.supportsEffort = true,
  });

  final String id;
  final String label;
  final String hint;

  /// Faux quand le modèle part sans réflexion (Haiku 4.5) : l'écran remplace
  /// alors les puces de réflexion par « Pas de réflexion avec … ». Le serveur
  /// le déduit de `requestShapeFor`.
  final bool supportsEffort;
}

/// Un effort de réflexion Claude proposé à l'écran, et ce à quoi il sert.
class AnthropicEffortChoice {
  const AnthropicEffortChoice({
    required this.id,
    required this.label,
    required this.hint,
  });

  final String id;
  final String label;
  final String hint;
}

/// Une configuration de routage enregistrée.
///
/// Elle porte tous les réglages de l'écran, moteur par défaut compris. La
/// charger REMPLACE le brouillon en entier : un poste absent de la
/// configuration retombe sur le moteur par défaut, il ne conserve pas sa valeur
/// courante. Une fusion rendrait le résultat dépendant de ce qui était en place
/// avant, et deux essais successifs ne seraient plus comparables.
class AiRoutingPreset {
  final String id;
  final String name;
  final AiRoutingPolicy policy;

  /// Ce que le serveur a écarté en relisant cette configuration : postes
  /// retirés depuis, modèles Claude sortis de la grille tarifaire.
  ///
  /// La liste des postes routables perd des entrées à chaque version. Une
  /// configuration de juillet reste chargeable, amputée de ce qui n'existe
  /// plus — et elle le dit, plutôt que d'appliquer en silence un état qui
  /// n'est plus le sien.
  final List<String> stale;

  final DateTime? updatedAt;

  /// Nom d'affichage de l'auteur, jamais son identifiant technique.
  final String? updatedBy;

  const AiRoutingPreset({
    required this.id,
    required this.name,
    required this.policy,
    this.stale = const [],
    this.updatedAt,
    this.updatedBy,
  });
}

class AiRoutingSnapshot {
  final AiRoutingPolicy policy;
  final bool anthropicKeyPresent;
  final List<RoutableFeature> routableFeatures;

  /// Modèles Claude proposés, du plus soigneux au plus rapide.
  ///
  /// Vide sur un backend antérieur : le sélecteur disparaît alors, plutôt que
  /// de proposer une liste devinée qui se ferait refuser à l'écriture.
  final List<AnthropicModelChoice> anthropicModelChoices;

  /// Efforts de réflexion Claude proposés, du plus rapide au plus appliqué.
  ///
  /// Vide sur un backend antérieur : le sélecteur disparaît alors, comme pour
  /// [anthropicModelChoices].
  final List<AnthropicEffortChoice> anthropicEffortChoices;

  /// Postes qui produisent une image — affichés, jamais basculables.
  ///
  /// Aucun modèle Anthropic ne fabrique d'image. Les taire laissait croire que
  /// la retouche suivait les postes de *détection* voisins, eux basculables :
  /// l'écran montre désormais qui les sert, sans leur offrir un choix qui
  /// n'existe pas.
  final List<RoutableFeature> imageGenerationFeatures;

  /// Identifiant du modèle image, tel qu'il apparaît dans le reporting.
  final String imageModel;

  /// Nom commercial du même modèle, pour l'écran.
  final String imageModelLabel;

  /// Configurations enregistrées, par ordre alphabétique.
  final List<AiRoutingPreset> presets;

  /// Vrai quand le serveur n'a pas su lire les configurations.
  ///
  /// La liste est alors vide, et une liste vide se lit « aucune configuration
  /// enregistrée » — ce qui est faux, et pousse à en recréer une par-dessus.
  /// L'écran annonce la panne au lieu d'afficher un état plausible.
  final bool presetsFailed;

  const AiRoutingSnapshot({
    required this.policy,
    required this.anthropicKeyPresent,
    required this.routableFeatures,
    this.anthropicModelChoices = const [],
    this.anthropicEffortChoices = const [],
    this.imageGenerationFeatures = const [],
    this.imageModel = '',
    this.imageModelLabel = '',
    this.presets = const [],
    this.presetsFailed = false,
  });

  /// Remplace ce que l'écriture rapporte, garde ce qu'elle ne renvoie pas.
  ///
  /// L'écran reconstruisait ce snapshot champ par champ après chaque
  /// enregistrement : un champ ajouté ici et oublié là-bas disparaissait de
  /// l'écran jusqu'au rechargement suivant, sans erreur.
  AiRoutingSnapshot copyWith({
    AiRoutingPolicy? policy,
    bool? anthropicKeyPresent,
    List<AiRoutingPreset>? presets,
    bool? presetsFailed,
  }) {
    return AiRoutingSnapshot(
      policy: policy ?? this.policy,
      anthropicKeyPresent: anthropicKeyPresent ?? this.anthropicKeyPresent,
      routableFeatures: routableFeatures,
      anthropicModelChoices: anthropicModelChoices,
      anthropicEffortChoices: anthropicEffortChoices,
      imageGenerationFeatures: imageGenerationFeatures,
      imageModel: imageModel,
      imageModelLabel: imageModelLabel,
      presets: presets ?? this.presets,
      presetsFailed: presetsFailed ?? this.presetsFailed,
    );
  }
}

class AiRoutingRepository {
  final FirebaseFunctions _functions;
  final ErrorReportService _errorReportService;

  AiRoutingRepository({
    FirebaseFunctions? functions,
    ErrorReportService? errorReportService,
  }) : _functions =
           functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1'),
       _errorReportService = errorReportService ?? ErrorReportService();

  Future<AiRoutingSnapshot> fetch() async {
    try {
      final raw = await _functions
          .httpsCallable('getAiRoutingPolicyFn')
          .call<Map<String, dynamic>>();
      return _parse(Map<String, dynamic>.from(raw.data));
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'aiRouting.fetch',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  Future<AiRoutingSnapshot> save(AiRoutingPolicy policy) async {
    try {
      final raw = await _functions
          .httpsCallable('setAiRoutingPolicyFn')
          .call<Map<String, dynamic>>({'policy': policy.toMap()});
      final data = Map<String, dynamic>.from(raw.data);
      // L'écriture ne renvoie pas la liste des postes : on conserve celle que
      // l'écran affiche déjà plutôt que d'inventer une liste vide.
      return AiRoutingSnapshot(
        policy: _parsePolicy(
          Map<String, dynamic>.from(data['policy'] as Map? ?? const {}),
        ),
        anthropicKeyPresent: data['anthropicKeyPresent'] == true,
        routableFeatures: const [],
      );
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'aiRouting.save',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  /// Enregistre le brouillon courant sous un nouveau nom.
  Future<List<AiRoutingPreset>> createPreset({
    required String name,
    required AiRoutingPolicy policy,
  }) => _presetAction('save', {'name': name, 'policy': policy.toMap()});

  /// Écrase une configuration existante par le brouillon courant.
  Future<List<AiRoutingPreset>> updatePreset({
    required String id,
    required AiRoutingPolicy policy,
  }) => _presetAction('update', {'id': id, 'policy': policy.toMap()});

  Future<List<AiRoutingPreset>> renamePreset({
    required String id,
    required String name,
  }) => _presetAction('rename', {'id': id, 'name': name});

  Future<List<AiRoutingPreset>> deletePreset(String id) =>
      _presetAction('delete', {'id': id});

  /// Un seul point d'entrée HTTPS pour les quatre gestes, aiguillé sur
  /// « action » : le bundle porte déjà cinquante fonctions, et le budget de
  /// découverte du déploiement est de dix secondes.
  ///
  /// La réponse rapporte la liste entière. Sans elle, chaque geste demanderait
  /// un second aller-retour, et l'écran afficherait un état d'avant l'écriture.
  Future<List<AiRoutingPreset>> _presetAction(
    String action,
    Map<String, dynamic> payload,
  ) async {
    try {
      final raw = await _functions
          .httpsCallable('aiRoutingPresetsFn')
          .call<Map<String, dynamic>>({'action': action, ...payload});
      final data = Map<String, dynamic>.from(raw.data);
      return parsePresets(data['presets']);
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'aiRouting.preset.$action',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }

  AiRoutingSnapshot _parse(Map<String, dynamic> data) {
    final features = _parseFeatures(data['routableFeatures']);
    // Une liste absente n'est pas une anomalie : elle signale un backend
    // antérieur à ces postes. La section disparaît alors, plutôt que de
    // s'afficher vide.
    final imageFeatures = _parseFeatures(data['imageGenerationFeatures']);

    return AiRoutingSnapshot(
      policy: _parsePolicy(
        Map<String, dynamic>.from(data['policy'] as Map? ?? const {}),
      ),
      anthropicKeyPresent: data['anthropicKeyPresent'] == true,
      routableFeatures: features,
      anthropicModelChoices: _parseModelChoices(data['anthropicModelChoices']),
      anthropicEffortChoices: _parseEffortChoices(
        data['anthropicEffortChoices'],
      ),
      imageGenerationFeatures: imageFeatures,
      imageModel: data['imageModel'] as String? ?? '',
      imageModelLabel: data['imageModelLabel'] as String? ?? '',
      presets: parsePresets(data['presets']),
      presetsFailed: data['presetsFailed'] == true,
    );
  }

  List<AnthropicModelChoice> _parseModelChoices(Object? raw) {
    return (raw as List? ?? const [])
        .whereType<Map>()
        .map((e) {
          final m = Map<String, dynamic>.from(e);
          return AnthropicModelChoice(
            id: m['id'] as String? ?? '',
            label: m['label'] as String? ?? '',
            hint: m['hint'] as String? ?? '',
            supportsEffort: m['supportsEffort'] != false,
          );
        })
        .where((c) => c.id.isNotEmpty)
        .toList(growable: false);
  }

  List<AnthropicEffortChoice> _parseEffortChoices(Object? raw) {
    return (raw as List? ?? const [])
        .whereType<Map>()
        .map((e) {
          final m = Map<String, dynamic>.from(e);
          return AnthropicEffortChoice(
            id: m['id'] as String? ?? '',
            label: m['label'] as String? ?? '',
            hint: m['hint'] as String? ?? '',
          );
        })
        .where((c) => c.id.isNotEmpty)
        .toList(growable: false);
  }

  List<RoutableFeature> _parseFeatures(Object? raw) =>
      parseRoutableFeatures(raw);

  AiRoutingPolicy _parsePolicy(Map<String, dynamic> data) =>
      parseRoutingPolicy(data);
}

/// Lit une politique de routage telle que le serveur l'envoie.
///
/// Fonction de module, comme [parseRoutableFeatures] et [parsePresets] : un
/// champ oublié ici ne lève aucune erreur, il disparaît et laisse une valeur
/// plausible. Une configuration relue sans son plafond de raisonnement ne se
/// verrait qu'à la facture du mois suivant.
AiRoutingPolicy parseRoutingPolicy(Map<String, dynamic> data) {
  final rawFeatures = Map<String, dynamic>.from(
    data['features'] as Map? ?? const {},
  );
  return AiRoutingPolicy(
    defaultProvider: AiProvider.fromWire(data['defaultProvider'] as String?),
    features: {
      for (final entry in rawFeatures.entries)
        entry.key: AiProvider.fromWire(entry.value as String?),
    },
    anthropicModel: data['anthropicModel'] as String? ?? 'claude-sonnet-5',
    fallbackEnabled: data['fallbackEnabled'] != false,
    thinkingBudget: (data['thinkingBudget'] as num?)?.toInt(),
    thinkingBudgets: {
      for (final entry in Map<String, dynamic>.from(
        data['thinkingBudgets'] as Map? ?? const {},
      ).entries)
        if (entry.value is num) entry.key: (entry.value as num).toInt(),
    },
    anthropicModels: {
      for (final entry in Map<String, dynamic>.from(
        data['anthropicModels'] as Map? ?? const {},
      ).entries)
        if (entry.value is String && (entry.value as String).isNotEmpty)
          entry.key: entry.value as String,
    },
    anthropicEfforts: {
      for (final entry in Map<String, dynamic>.from(
        data['anthropicEfforts'] as Map? ?? const {},
      ).entries)
        if (entry.value is String && (entry.value as String).isNotEmpty)
          entry.key: entry.value as String,
    },
    anthropicEffort: _nonEmptyString(data['anthropicEffort']),
  );
}

/// Une chaîne non vide, sinon `null` : un champ absent, nul ou vide vaut
/// « pas de réglage ».
String? _nonEmptyString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// Lit la liste des configurations déclarée par le serveur.
///
/// Fonction de module plutôt que méthode privée, pour la même raison que
/// [parseRoutableFeatures] : c'est ici qu'un champ oublié ne lève aucune
/// erreur — il disparaît, et l'écran affiche une valeur plausible à la place.
/// Un test la rejoue donc directement.
List<AiRoutingPreset> parsePresets(Object? raw) {
  return (raw as List? ?? const [])
      .whereType<Map>()
      .map((e) {
        final map = Map<String, dynamic>.from(e);
        final updatedAt = map['updatedAt'];
        return AiRoutingPreset(
          id: map['id'] as String? ?? '',
          name: map['name'] as String? ?? '',
          policy: parseRoutingPolicy(
            Map<String, dynamic>.from(map['policy'] as Map? ?? const {}),
          ),
          stale: (map['stale'] as List? ?? const []).whereType<String>().toList(
            growable: false,
          ),
          updatedAt: updatedAt is String
              ? DateTime.tryParse(updatedAt)?.toLocal()
              : null,
          updatedBy: map['updatedBy'] as String?,
        );
      })
      .where((p) => p.id.isNotEmpty)
      .toList(growable: false);
}
