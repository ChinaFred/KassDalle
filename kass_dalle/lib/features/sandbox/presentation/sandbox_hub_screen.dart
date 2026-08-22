import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/widgets/readable_width.dart';
import 'sandbox_registry.dart';

/// Liste des expériences du bac à sable.
///
/// Ce qui vit ici n'est promis à personne : une expérience peut disparaître
/// d'une version à l'autre, sans transition ni migration.
class SandboxHubScreen extends StatelessWidget {
  const SandboxHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Bac à sable')),
      body: ReadableWidth(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text(
                'Terrain d\'essai réservé aux administrateurs. Rien de ce qui '
                's\'y trouve n\'est une fonctionnalité de l\'application, et '
                'rien n\'y est enregistré.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (kExperiments.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
                child: Text(
                  'Aucune expérience en cours.',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            for (final experiment in kExperiments)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                child: Card(
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: theme.colorScheme.tertiaryContainer,
                      foregroundColor: theme.colorScheme.onTertiaryContainer,
                      child: Icon(experiment.icon),
                    ),
                    title: Text(experiment.title),
                    subtitle: Text(experiment.subtitle),
                    trailing: const Icon(Icons.chevron_right),
                    isThreeLine: true,
                    onTap: () => context.push(
                      AppRoutes.sandboxExperiment(experiment.id),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Résout une expérience depuis son identifiant d'URL.
///
/// Une expérience retirée laisse des liens qui pointent dans le vide : on le
/// dit, plutôt que d'afficher un écran blanc.
class SandboxExperimentScreen extends StatelessWidget {
  final String experimentId;

  const SandboxExperimentScreen({super.key, required this.experimentId});

  @override
  Widget build(BuildContext context) {
    final experiment = experimentById(experimentId);
    if (experiment == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Bac à sable')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Expérience « $experimentId » inconnue. Elle a sans doute été '
              'retirée du bac à sable.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ),
      );
    }
    return experiment.builder(context);
  }
}
