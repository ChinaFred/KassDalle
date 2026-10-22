import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/data/ai_routing_repository.dart';
import 'package:kass_dalle/features/admin/domain/ai_routing_defaults.dart';

/// Changer un défaut ne touche aucun poste existant.
///
/// Les postes qui suivaient l'ancien défaut reçoivent l'ancienne valeur en
/// choix explicite, puis le défaut change. Un écart ici ne lève aucune
/// erreur : un poste change de moteur, de modèle ou de réflexion, et la
/// facture du mois suivant le montre.
void main() {
  const catalogue = [
    RoutableFeature(
      id: 'transcription_page',
      label: 'Transcription',
      codeEffort: 'high',
    ),
    RoutableFeature(id: 'generate', label: 'Génération', codeEffort: 'low'),
    RoutableFeature(id: 'search', label: 'Recherche', codeEffort: 'low'),
    RoutableFeature(
      id: 'image_moderation',
      label: 'Modération',
      providers: [AiProvider.vision],
    ),
  ];

  AiRoutingPolicy policy({
    AiProvider defaultProvider = AiProvider.anthropic,
    Map<String, AiProvider> features = const {},
    String anthropicModel = 'claude-sonnet-5',
    Map<String, String> anthropicModels = const {},
    Map<String, String> anthropicEfforts = const {},
    String? anthropicEffort,
  }) => AiRoutingPolicy(
    defaultProvider: defaultProvider,
    features: features,
    anthropicModel: anthropicModel,
    fallbackEnabled: true,
    anthropicModels: anthropicModels,
    anthropicEfforts: anthropicEfforts,
    anthropicEffort: anthropicEffort,
  );

  group('qui suit quel défaut', () {
    test('un poste verrouillé ne suit aucun défaut', () {
      final p = policy();
      final ids = AiRoutingDefaults.followingProvider(
        p,
        catalogue,
      ).map((f) => f.id);
      expect(ids, isNot(contains('image_moderation')));
      expect(AiRoutingDefaults.followsAnyDefault(p, catalogue.last), isFalse);
    });

    test('un choix explicite égal au défaut ne suit pas le défaut', () {
      final p = policy(
        features: {'generate': AiProvider.anthropic},
        anthropicModels: {'generate': 'claude-sonnet-5'},
      );
      expect(
        AiRoutingDefaults.followingProvider(p, catalogue).map((f) => f.id),
        ['transcription_page', 'search'],
      );
      expect(AiRoutingDefaults.followingModel(p, catalogue).map((f) => f.id), [
        'transcription_page',
        'search',
      ]);
    });

    test('le modèle et la réflexion ne comptent que sous Claude', () {
      final p = policy(defaultProvider: AiProvider.gemini);
      expect(AiRoutingDefaults.followingModel(p, catalogue), isEmpty);
      expect(AiRoutingDefaults.followingEffort(p, catalogue), isEmpty);
    });

    test('un poste à trois choix propres ne suit aucun défaut', () {
      final p = policy(
        features: {'generate': AiProvider.anthropic},
        anthropicModels: {'generate': 'claude-opus-5'},
        anthropicEfforts: {'generate': 'medium'},
      );
      expect(AiRoutingDefaults.followsAnyDefault(p, catalogue[1]), isFalse);
      expect(AiRoutingDefaults.followsAnyDefault(p, catalogue[0]), isTrue);
    });
  });

  group('changer un défaut fige d\'abord', () {
    test('le moteur : les postes qui suivaient gardent l\'ancien', () {
      final p = policy(features: {'search': AiProvider.gemini});
      final next = AiRoutingDefaults.changeDefaultProvider(
        p,
        catalogue,
        AiProvider.gemini,
      );
      expect(next.defaultProvider, AiProvider.gemini);
      expect(next.features, {
        'search': AiProvider.gemini,
        'transcription_page': AiProvider.anthropic,
        'generate': AiProvider.anthropic,
      });
      for (final f in catalogue) {
        expect(
          AiRoutingDefaults.providerOf(next, f),
          AiRoutingDefaults.providerOf(p, f),
          reason: f.id,
        );
      }
    });

    test('le modèle : les postes servis par Claude gardent l\'ancien', () {
      final p = policy(features: {'search': AiProvider.gemini});
      final next = AiRoutingDefaults.changeDefaultModel(
        p,
        catalogue,
        'claude-haiku-4-5',
      );
      expect(next.anthropicModel, 'claude-haiku-4-5');
      expect(next.anthropicModels, {
        'transcription_page': 'claude-sonnet-5',
        'generate': 'claude-sonnet-5',
      });
    });

    test('la réflexion « Selon le poste » se fige sur l\'effort du code', () {
      final p = policy();
      final next = AiRoutingDefaults.changeDefaultEffort(p, catalogue, 'low');
      expect(next.anthropicEffort, 'low');
      expect(next.anthropicEfforts, {
        'transcription_page': 'high',
        'generate': 'low',
        'search': 'low',
      });
      for (final f in catalogue.take(3)) {
        expect(next.effectiveEffortFor(f), p.effectiveEffortFor(f));
      }
    });

    test('une réflexion par défaut se fige sur sa valeur', () {
      final p = policy(
        anthropicEffort: 'medium',
        anthropicEfforts: {'generate': 'high'},
      );
      final next = AiRoutingDefaults.changeDefaultEffort(p, catalogue, null);
      expect(next.anthropicEffort, isNull);
      expect(next.anthropicEfforts, {
        'generate': 'high',
        'transcription_page': 'medium',
        'search': 'medium',
      });
    });

    test('un effort du code inconnu n\'est pas inventé', () {
      const sansEffort = [RoutableFeature(id: 'generate', label: 'G')];
      final p = policy();
      final next = AiRoutingDefaults.changeDefaultEffort(p, sansEffort, 'low');
      expect(next.anthropicEfforts, isEmpty);
    });

    test('le même défaut ne change rien', () {
      final p = policy();
      expect(
        identical(
          AiRoutingDefaults.changeDefaultModel(p, catalogue, 'claude-sonnet-5'),
          p,
        ),
        isTrue,
      );
    });
  });

  group('texte de la confirmation', () {
    test('pluriel', () {
      expect(
        defaultChangeMessage(
          count: 12,
          subject: 'le modèle par défaut',
          kept: 'Sonnet 5',
        ),
        '12 postes suivent le modèle par défaut : ils garderont Sonnet 5. '
        'Le nouveau défaut servira aux postes que vous remettrez sur '
        '« Défaut » et à ceux qu\'ajoutera une mise à jour.',
      );
    });

    test('modèle : un poste passé sur Claude suivra le nouveau défaut', () {
      expect(
        defaultChangeMessage(
          count: 12,
          subject: 'le modèle par défaut',
          kept: 'Sonnet 5',
          claudeOnly: true,
        ),
        '12 postes suivent le modèle par défaut : ils garderont Sonnet 5. '
        'Le nouveau défaut servira aux postes que vous remettrez sur '
        '« Défaut », à ceux que vous passerez sur Claude et à ceux '
        'qu\'ajoutera une mise à jour.',
      );
    });

    test('singulier', () {
      expect(
        defaultChangeMessage(
          count: 1,
          subject: 'la réflexion par défaut',
          kept: 'la réflexion basse',
        ),
        startsWith(
          '1 poste suit la réflexion par défaut : il gardera la réflexion '
          'basse.',
        ),
      );
    });

    test('le libellé d\'un effort vient de la liste du serveur', () {
      const choices = [
        AnthropicEffortChoice(id: 'low', label: 'Basse', hint: ''),
      ];
      expect(effortWord('low', choices), 'basse');
      expect(effortWord('xhigh', choices), 'xhigh');
    });
  });
}
