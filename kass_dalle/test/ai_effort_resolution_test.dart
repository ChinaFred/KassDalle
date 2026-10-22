import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/admin/data/ai_routing_repository.dart';

/// Effort de réflexion Claude que reçoit un poste, côté Dart.
///
/// Le serveur décide de l'appel (`resolveAnthropicEffort` puis
/// `codeEffortFor`) ; l'écran Moteur d'IA rejoue le même ordre pour
/// l'affichage (`AiRoutingPolicy.effectiveEffortFor`). Un écart ne lève aucune
/// erreur : l'écran annonce une réflexion que le poste ne reçoit pas. Les cas
/// viennent donc de `test-fixtures/`, rejoués aussi par
/// `functions/src/tests/aiEffortResolution.test.ts`.
///
/// La section `model_cases` est serveur seul : le client reçoit
/// `supportsEffort` du serveur.
void main() {
  final file = File('test-fixtures/ai_effort_resolution.json');
  if (!file.existsSync()) {
    fail(
      'Fixture introuvable : ${file.absolute.path}. '
      'Les tests doivent être lancés depuis le dossier kass_dalle/.',
    );
  }
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final cases = (fixture['cases'] as List).cast<Map<String, dynamic>>();

  group('effort reçu par un poste (fixture partagée)', () {
    for (final c in cases) {
      test(c['name'] as String, () {
        final policy = AiRoutingPolicy(
          defaultProvider: AiProvider.anthropic,
          features: const {},
          anthropicModel: 'claude-sonnet-5',
          fallbackEnabled: true,
          anthropicEfforts: (c['anthropic_efforts'] as Map)
              .cast<String, String>(),
          anthropicEffort: c['anthropic_effort'] as String?,
        );
        final feature = RoutableFeature(
          id: c['feature'] as String,
          label: c['feature'] as String,
          codeEffort: c['code_effort'] as String,
        );
        expect(policy.effectiveEffortFor(feature), c['expected']);
      });
    }
  });
}
