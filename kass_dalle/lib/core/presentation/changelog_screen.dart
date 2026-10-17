import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:markdown/markdown.dart' as md;

import '../app_version.dart';
import '../services/changelog_service.dart';
import '../widgets/app_states.dart';

const _months = [
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

String _formatDate(DateTime d) =>
    '${d.day == 1 ? '1er' : d.day} ${_months[d.month - 1]} ${d.year}';

/// « Nouveautés » (`/changelog`) : les dernières versions et ce qu'elles
/// changent pour l'utilisateur.
class ChangelogScreen extends ConsumerWidget {
  const ChangelogScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(changelogProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Nouveautés')),
      body: entries.when(
        skipLoadingOnRefresh: false,
        loading: () => const AppLoadingState(label: 'Chargement…'),
        error: (error, _) => AppErrorState(
          error: error,
          title: 'Impossible d\'afficher les nouveautés.',
          onRetry: () => ref.invalidate(changelogProvider),
        ),
        data: (list) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: list.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (_, i) => _ChangelogCard(entry: list[i]),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChangelogCard extends StatelessWidget {
  final ChangelogEntry entry;
  const _ChangelogCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final installed = entry.version == kAppVersion;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('v${entry.version}', style: theme.textTheme.titleLarge),
                if (installed) ...[
                  const SizedBox(width: 8),
                  const Chip(
                    label: Text('Installée'),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ],
            ),
            Text(
              _formatDate(entry.date),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            MarkdownBody(
              data: entry.text,
              extensionSet: md.ExtensionSet.gitHubFlavored,
              styleSheet: MarkdownStyleSheet.fromTheme(theme),
            ),
          ],
        ),
      ),
    );
  }
}
