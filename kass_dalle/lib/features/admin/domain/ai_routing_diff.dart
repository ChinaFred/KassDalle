import '../data/ai_routing_repository.dart';

/// Ce qu'un chargement de configuration changerait, en clair.
///
/// Charger une configuration remplace huit réglages, dont quatre par poste :
/// quarante-trois bascules, quarante-trois modèles Claude, quarante-trois
/// efforts de réflexion, quarante-trois plafonds de raisonnement. Appliquer
/// cela sans rien montrer, c'est écrire à l'aveugle — et une bascule n'échoue
/// pas, elle change la facture du mois.
///
/// Le calcul reste hors de l'écran pour être rejoué par un test : une ligne
/// oubliée ne lève aucune erreur, elle laisse seulement croire que rien ne
/// bouge.
class AiRoutingDiff {
  final List<String> lines;

  const AiRoutingDiff(this.lines);

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;

  static AiRoutingDiff between({
    required AiRoutingPolicy current,
    required AiRoutingPolicy next,
    required List<RoutableFeature> features,
  }) {
    final lines = <String>[];

    if (current.defaultProvider != next.defaultProvider) {
      lines.add(
        'Moteur par défaut : ${current.defaultProvider.label} → '
        '${next.defaultProvider.label}',
      );
    }
    if (current.fallbackEnabled != next.fallbackEnabled) {
      lines.add(
        'Repli automatique : ${_onOff(current.fallbackEnabled)} → '
        '${_onOff(next.fallbackEnabled)}',
      );
    }
    if (current.anthropicModel != next.anthropicModel) {
      lines.add(
        'Modèle Claude par défaut : ${current.anthropicModel} → '
        '${next.anthropicModel}',
      );
    }
    if (current.thinkingBudget != next.thinkingBudget) {
      lines.add(
        'Raisonnement de Gemini : ${_budget(current.thinkingBudget)} → '
        '${_budget(next.thinkingBudget)}',
      );
    }

    var versClaude = 0;
    var versGemini = 0;
    var modeles = 0;
    var efforts = 0;
    var plafonds = 0;

    for (final feature in features) {
      // Un poste verrouillé ne se route pas : sa valeur ne commanderait rien,
      // et le serveur la refuse à l'écriture.
      if (feature.lockedProvider != null) continue;

      final avant = current.providerFor(feature.id);
      final apres = next.providerFor(feature.id);
      if (avant != apres) {
        if (apres == AiProvider.anthropic) {
          versClaude++;
        } else {
          versGemini++;
        }
      }

      // Le modèle ne compte que sur un poste servi par Claude AVANT comme
      // APRÈS. Un poste servi par Gemini ne facture rien à Claude, et un poste
      // qui vient de basculer est déjà annoncé par la ligne des bascules — l'y
      // compter une seconde fois ferait un chiffre qui ne s'additionne pas.
      if (avant == AiProvider.anthropic && apres == AiProvider.anthropic) {
        if (current.anthropicModelFor(feature.id) !=
            next.anthropicModelFor(feature.id)) {
          modeles++;
        }
        // Même garde que le modèle : un effort réglé sur un poste servi par
        // Gemini ne commande rien, et un poste qui vient de basculer est déjà
        // annoncé par la ligne des bascules.
        if (current.anthropicEffortFor(feature.id) !=
            next.anthropicEffortFor(feature.id)) {
          efforts++;
        }
      }

      // Comparaison des exceptions seules : le plafond global est déjà annoncé
      // par sa propre ligne, et le compter une seconde fois sur chacun des
      // quarante-trois postes ferait un chiffre qui n'apprend rien.
      if (current.thinkingBudgets[feature.id] !=
          next.thinkingBudgets[feature.id]) {
        plafonds++;
      }
    }

    if (versClaude > 0) {
      lines.add(
        '$versClaude ${_postes(versClaude)} ${_passent(versClaude)} à Claude',
      );
    }
    if (versGemini > 0) {
      lines.add(
        '$versGemini ${_postes(versGemini)} ${_passent(versGemini)} à Gemini',
      );
    }
    if (modeles > 0) {
      lines.add(
        '$modeles ${_postes(modeles)} servi${modeles > 1 ? 's' : ''} par Claude '
        '${modeles > 1 ? 'changent' : 'change'} de modèle',
      );
    }
    if (efforts > 0) {
      lines.add(
        '$efforts ${_postes(efforts)} servi${efforts > 1 ? 's' : ''} par Claude '
        '${efforts > 1 ? 'changent' : 'change'} d\'effort de réflexion',
      );
    }
    if (plafonds > 0) {
      lines.add(
        '$plafonds ${_postes(plafonds)} ${plafonds > 1 ? 'changent' : 'change'} '
        'de plafond de raisonnement',
      );
    }

    return AiRoutingDiff(lines);
  }

  static String _onOff(bool value) => value ? 'activé' : 'coupé';

  static String _budget(int? value) => switch (value) {
    null => 'le modèle décide',
    0 => 'coupé',
    _ => '$value jetons',
  };

  static String _postes(int count) => count > 1 ? 'postes' : 'poste';

  static String _passent(int count) => count > 1 ? 'passent' : 'passe';
}
