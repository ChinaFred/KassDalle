import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/data/ai_routing_repository.dart';
import 'package:kass_dalle/features/admin/domain/ai_routing_diff.dart';

/// Configurations de routage : lecture et écart affiché.
///
/// Deux endroits où une panne ne lève rien.
///
/// La lecture d'abord : un champ absent du JSON disparaît sans erreur, et la
/// configuration s'affiche plausible. Une politique relue sans son plafond de
/// raisonnement se charge, s'enregistre, et ne se voit qu'à la facture.
///
/// L'écart ensuite : c'est le seul contrôle avant qu'un chargement ne remplace
/// quarante-trois postes. Une ligne oubliée laisse croire que rien ne bouge.
void main() {
  const catalogue = [
    RoutableFeature(id: 'transcription_page', label: 'Transcription'),
    RoutableFeature(id: 'generate', label: 'Génération'),
    RoutableFeature(
      id: 'image_moderation',
      label: 'Modération',
      providers: [AiProvider.vision],
    ),
  ];

  AiRoutingPolicy policy({
    AiProvider defaultProvider = AiProvider.gemini,
    Map<String, AiProvider> features = const {},
    String anthropicModel = 'claude-sonnet-5',
    bool fallbackEnabled = true,
    int? thinkingBudget,
    Map<String, int> thinkingBudgets = const {},
    Map<String, String> anthropicModels = const {},
    Map<String, String> anthropicEfforts = const {},
  }) => AiRoutingPolicy(
    defaultProvider: defaultProvider,
    features: features,
    anthropicModel: anthropicModel,
    fallbackEnabled: fallbackEnabled,
    thinkingBudget: thinkingBudget,
    thinkingBudgets: thinkingBudgets,
    anthropicModels: anthropicModels,
    anthropicEfforts: anthropicEfforts,
  );

  group('parseRoutingPolicy', () {
    test('les huit réglages survivent au transport', () {
      final read = parseRoutingPolicy({
        'defaultProvider': 'anthropic',
        'features': {'generate': 'gemini'},
        'anthropicModel': 'claude-opus-5',
        'fallbackEnabled': false,
        'thinkingBudget': 2048,
        'thinkingBudgets': {'generate': 0},
        'anthropicModels': {'transcription_page': 'claude-haiku-4-5'},
        'anthropicEfforts': {'transcription_page': 'medium'},
      });

      expect(read.defaultProvider, AiProvider.anthropic);
      expect(read.features, {'generate': AiProvider.gemini});
      expect(read.anthropicModel, 'claude-opus-5');
      expect(read.fallbackEnabled, isFalse);
      expect(read.thinkingBudget, 2048);
      expect(read.thinkingBudgets, {'generate': 0});
      expect(read.anthropicModels, {'transcription_page': 'claude-haiku-4-5'});
      expect(read.anthropicEfforts, {'transcription_page': 'medium'});
    });

    test('un plafond coupé ne se confond pas avec un plafond absent', () {
      // `0` coupe le raisonnement, `null` laisse le modèle décider. Les deux
      // s'affichent différemment et ne coûtent pas la même chose.
      expect(parseRoutingPolicy({'thinkingBudget': 0}).thinkingBudget, 0);
      expect(parseRoutingPolicy({}).thinkingBudget, isNull);
    });
  });

  group('parsePresets', () {
    test('lit le nom, la politique, la date et l\'auteur', () {
      final presets = parsePresets([
        {
          'id': 'haute-performance',
          'name': 'Haute performance',
          'policy': {
            'defaultProvider': 'anthropic',
            'anthropicModel': 'claude-opus-5',
          },
          'stale': <String>[],
          'updatedAt': '2026-08-30T12:00:00.000Z',
          'updatedBy': 'Frédéric China',
        },
      ]);

      expect(presets, hasLength(1));
      final preset = presets.single;
      expect(preset.name, 'Haute performance');
      expect(preset.policy.defaultProvider, AiProvider.anthropic);
      expect(preset.policy.anthropicModel, 'claude-opus-5');
      expect(preset.updatedBy, 'Frédéric China');
      expect(preset.updatedAt?.toUtc().hour, 12);
    });

    test('conserve ce que le serveur a écarté', () {
      final presets = parsePresets([
        {
          'id': 'ancienne',
          'name': 'Ancienne',
          'policy': const <String, dynamic>{},
          'stale': ['Poste inconnu : detect_duplicate_ingredients.'],
        },
      ]);

      expect(presets.single.stale, hasLength(1));
    });

    test('une configuration sans identifiant est ignorée', () {
      // Elle ne pourrait ni se charger, ni se supprimer : l'afficher promet un
      // geste qui échouerait.
      expect(
        parsePresets([
          {'name': 'Sans identifiant'},
        ]),
        isEmpty,
      );
    });

    test('une date illisible ne fait pas disparaître la configuration', () {
      final presets = parsePresets([
        {'id': 'x', 'name': 'X', 'updatedAt': 'avant-hier'},
      ]);
      expect(presets, hasLength(1));
      expect(presets.single.updatedAt, isNull);
    });

    test('une liste absente rend une liste vide', () {
      expect(parsePresets(null), isEmpty);
    });
  });

  group('AiRoutingDiff', () {
    test('deux politiques identiques ne montrent aucun écart', () {
      final diff = AiRoutingDiff.between(
        current: policy(features: {'generate': AiProvider.anthropic}),
        next: policy(features: {'generate': AiProvider.anthropic}),
        features: catalogue,
      );
      expect(diff.isEmpty, isTrue);
    });

    test('les réglages généraux sont nommés un par un', () {
      // Les deux postes sont fixés sur Gemini des deux côtés : seuls les
      // réglages généraux bougent, et on lit leurs quatre lignes seules.
      const surGemini = {
        'transcription_page': AiProvider.gemini,
        'generate': AiProvider.gemini,
      };
      final diff = AiRoutingDiff.between(
        current: policy(features: surGemini),
        next: policy(
          features: surGemini,
          defaultProvider: AiProvider.anthropic,
          fallbackEnabled: false,
          anthropicModel: 'claude-opus-5',
          thinkingBudget: 0,
        ),
        features: catalogue,
      );

      expect(diff.lines, hasLength(4));
      expect(diff.lines[0], contains('Gemini → Claude'));
      expect(diff.lines[1], contains('activé → coupé'));
      expect(diff.lines[2], contains('claude-opus-5'));
      expect(diff.lines[3], contains('le modèle décide → coupé'));
    });

    test('les bascules sont comptées par destination', () {
      final diff = AiRoutingDiff.between(
        current: policy(),
        next: policy(
          features: {
            'transcription_page': AiProvider.anthropic,
            'generate': AiProvider.anthropic,
          },
        ),
        features: catalogue,
      );

      expect(diff.lines, hasLength(1));
      expect(diff.lines.single, '2 postes passent à Claude');
    });

    test('un poste verrouillé ne compte pour aucune bascule', () {
      // La modération est servie par Cloud Vision. Une valeur laissée sur ce
      // poste ne commande rien, et le serveur la refuse à l'écriture :
      // l'annoncer comme un changement serait faux.
      final diff = AiRoutingDiff.between(
        current: policy(),
        next: policy(features: {'image_moderation': AiProvider.anthropic}),
        features: catalogue,
      );
      expect(diff.isEmpty, isTrue);
    });

    test('un changement de moteur par défaut déplace les postes muets', () {
      // Aucun poste n'a de valeur explicite : ils suivent tous le défaut. Le
      // remplacement est intégral, donc ils basculent réellement.
      final diff = AiRoutingDiff.between(
        current: policy(),
        next: policy(defaultProvider: AiProvider.anthropic),
        features: catalogue,
      );

      expect(diff.lines, hasLength(2));
      expect(diff.lines[0], contains('Moteur par défaut'));
      expect(diff.lines[1], '2 postes passent à Claude');
    });

    test('le modèle ne compte que sur un poste servi par Claude', () {
      final surClaude = AiRoutingDiff.between(
        current: policy(features: {'generate': AiProvider.anthropic}),
        next: policy(
          features: {'generate': AiProvider.anthropic},
          anthropicModels: {'generate': 'claude-haiku-4-5'},
        ),
        features: catalogue,
      );
      expect(surClaude.lines.single, contains('change de modèle'));

      final surGemini = AiRoutingDiff.between(
        current: policy(),
        next: policy(anthropicModels: {'generate': 'claude-haiku-4-5'}),
        features: catalogue,
      );
      expect(surGemini.isEmpty, isTrue);
    });

    test('l\'effort ne compte que sur un poste servi par Claude', () {
      final surClaude = AiRoutingDiff.between(
        current: policy(features: {'generate': AiProvider.anthropic}),
        next: policy(
          features: {'generate': AiProvider.anthropic},
          anthropicEfforts: {'generate': 'medium'},
        ),
        features: catalogue,
      );
      expect(surClaude.lines.single, contains('effort de réflexion'));

      final surGemini = AiRoutingDiff.between(
        current: policy(),
        next: policy(anthropicEfforts: {'generate': 'medium'}),
        features: catalogue,
      );
      expect(surGemini.isEmpty, isTrue);
    });

    test('un poste qui bascule vers Claude n\'est pas compté deux fois', () {
      // Il apparaît dans les bascules. L'ajouter aux changements de modèle
      // ferait un chiffre qui ne s'additionne pas : deux lignes pour un poste.
      final diff = AiRoutingDiff.between(
        current: policy(),
        next: policy(
          features: {'generate': AiProvider.anthropic},
          anthropicModels: {'generate': 'claude-haiku-4-5'},
        ),
        features: catalogue,
      );

      expect(diff.lines, hasLength(1));
      expect(diff.lines.single, '1 poste passe à Claude');
    });

    test('un plafond par poste est compté séparément du plafond global', () {
      final diff = AiRoutingDiff.between(
        current: policy(),
        next: policy(thinkingBudgets: {'generate': 512}),
        features: catalogue,
      );

      expect(diff.lines, hasLength(1));
      expect(diff.lines.single, contains('plafond de raisonnement'));
    });
  });
}
