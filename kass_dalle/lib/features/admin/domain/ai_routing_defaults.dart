import '../data/ai_routing_repository.dart';

/// Les trois défauts de l'écran Moteur d'IA, et comment en changer un sans
/// toucher un poste existant.
///
/// Un poste « suit un défaut » quand la politique n'a pas de clé pour lui :
/// `features` pour le moteur, `anthropicModels` pour le modèle de Claude,
/// `anthropicEfforts` pour la réflexion de Claude. Un choix explicite égal au
/// défaut est un choix propre : il ne bouge pas quand le défaut change.
///
/// Changer un défaut « fige d'abord » : chaque poste qui suivait l'ancien
/// défaut reçoit l'ancienne valeur en choix explicite, puis le défaut change.
/// Le nouveau défaut ne sert donc qu'aux postes remis sur « Défaut », à ceux
/// qu'ajoute une mise à jour et, pour le modèle et la réflexion de Claude, aux
/// postes passés ensuite sur Claude.
///
/// Logique pure, hors de l'écran, pour être rejouée par un test.
class AiRoutingDefaults {
  const AiRoutingDefaults._();

  /// Moteur qui sert le poste : celui qu'il impose, sinon celui de la
  /// politique.
  static AiProvider providerOf(AiRoutingPolicy policy, RoutableFeature f) =>
      f.lockedProvider ?? policy.providerFor(f.id);

  static bool servedByClaude(AiRoutingPolicy policy, RoutableFeature f) =>
      providerOf(policy, f) == AiProvider.anthropic;

  /// Postes basculables sans moteur propre.
  static List<RoutableFeature> followingProvider(
    AiRoutingPolicy policy,
    Iterable<RoutableFeature> features,
  ) => [
    for (final f in features)
      if (f.lockedProvider == null && !policy.features.containsKey(f.id)) f,
  ];

  /// Postes servis par Claude sans modèle propre.
  ///
  /// Un poste servi par Gemini n'est pas compté : le modèle de Claude ne le
  /// concerne pas tant qu'il n'est pas basculé.
  static List<RoutableFeature> followingModel(
    AiRoutingPolicy policy,
    Iterable<RoutableFeature> features,
  ) => [
    for (final f in features)
      if (servedByClaude(policy, f) &&
          !policy.anthropicModels.containsKey(f.id))
        f,
  ];

  /// Postes servis par Claude sans réflexion propre.
  static List<RoutableFeature> followingEffort(
    AiRoutingPolicy policy,
    Iterable<RoutableFeature> features,
  ) => [
    for (final f in features)
      if (servedByClaude(policy, f) &&
          !policy.anthropicEfforts.containsKey(f.id))
        f,
  ];

  /// Vrai si le poste suit au moins un des trois défauts.
  static bool followsAnyDefault(AiRoutingPolicy policy, RoutableFeature f) {
    if (f.lockedProvider == null && !policy.features.containsKey(f.id)) {
      return true;
    }
    if (!servedByClaude(policy, f)) return false;
    return !policy.anthropicModels.containsKey(f.id) ||
        !policy.anthropicEfforts.containsKey(f.id);
  }

  /// Change le moteur par défaut après avoir figé les postes qui le suivaient.
  static AiRoutingPolicy changeDefaultProvider(
    AiRoutingPolicy policy,
    Iterable<RoutableFeature> features,
    AiProvider next,
  ) {
    if (next == policy.defaultProvider) return policy;
    final frozen = Map<String, AiProvider>.from(policy.features);
    for (final f in followingProvider(policy, features)) {
      frozen[f.id] = policy.defaultProvider;
    }
    return policy.copyWith(defaultProvider: next, features: frozen);
  }

  /// Change le modèle de Claude par défaut après avoir figé les postes qui le
  /// suivaient.
  static AiRoutingPolicy changeDefaultModel(
    AiRoutingPolicy policy,
    Iterable<RoutableFeature> features,
    String next,
  ) {
    if (next == policy.anthropicModel) return policy;
    final frozen = Map<String, String>.from(policy.anthropicModels);
    for (final f in followingModel(policy, features)) {
      frozen[f.id] = policy.anthropicModel;
    }
    return policy.copyWith(anthropicModel: next, anthropicModels: frozen);
  }

  /// Change la réflexion de Claude par défaut (`null` : « Selon le poste »)
  /// après avoir figé les postes qui la suivaient.
  ///
  /// Sous « Selon le poste », un poste reçoit l'effort de son code : c'est
  /// cette valeur qui est figée. Un poste dont le serveur n'a pas envoyé
  /// l'effort du code (backend antérieur) n'est pas figé : aucune valeur
  /// connue à écrire, et aucune n'est inventée.
  static AiRoutingPolicy changeDefaultEffort(
    AiRoutingPolicy policy,
    Iterable<RoutableFeature> features,
    String? next,
  ) {
    if (next == policy.anthropicEffort) return policy;
    final frozen = Map<String, String>.from(policy.anthropicEfforts);
    for (final f in followingEffort(policy, features)) {
      final kept = policy.anthropicEffort ?? f.codeEffort;
      if (kept != null) frozen[f.id] = kept;
    }
    return policy.copyWith(
      anthropicEfforts: frozen,
      anthropicEffort: next,
      clearAnthropicEffort: next == null,
    );
  }
}

/// Le texte de la confirmation qui précède le changement d'un défaut.
///
/// [subject] nomme le défaut (« le modèle par défaut »), [kept] ce que les
/// postes qui le suivent garderont (« Sonnet 5 », « la réflexion basse »).
///
/// [claudeOnly] : le défaut ne sert que les postes servis par Claude (modèle,
/// réflexion). Un poste passé plus tard sur Claude le suivra aussi, et le
/// texte le dit.
String defaultChangeMessage({
  required int count,
  required String subject,
  required String kept,
  bool claudeOnly = false,
}) {
  final plural = count > 1;
  final servedBy = claudeOnly
      ? 'aux postes que vous remettrez sur « Défaut », à ceux que vous '
            'passerez sur Claude et à ceux qu\'ajoutera une mise à jour.'
      : 'aux postes que vous remettrez sur « Défaut » et à ceux '
            'qu\'ajoutera une mise à jour.';
  return '$count ${plural ? 'postes suivent' : 'poste suit'} $subject : '
      '${plural ? 'ils garderont' : 'il gardera'} $kept. Le nouveau défaut '
      'servira $servedBy';
}

/// Libellé en minuscules d'un effort (`low` → « basse »), ou l'identifiant
/// tel quel quand l'écran ne le connaît pas.
String effortWord(String? effort, List<AnthropicEffortChoice> choices) {
  if (effort == null) return '';
  final choice = choices.where((c) => c.id == effort).firstOrNull;
  return choice == null ? effort : choice.label.toLowerCase();
}
