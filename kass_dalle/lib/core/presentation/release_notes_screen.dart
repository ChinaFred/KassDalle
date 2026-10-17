import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:markdown/markdown.dart' as md;

import '../app_version.dart';
import '../services/release_notes.dart';
import '../widgets/app_states.dart';

/// « Nouveautés » : les dernières versions et ce qu'elles ont changé pour
/// l'utilisateur, ouvert depuis le menu du compte.
///
/// La liste vient de l'extrait du `CHANGELOG.md` embarqué au build
/// ([kReleaseNotesAsset]) : ni réseau, ni Firestore.
class ReleaseNotesScreen extends ConsumerWidget {
  const ReleaseNotesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(releaseNotesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Nouveautés')),
      body: notes.when(
        loading: () => const AppLoadingState(),
        error: (error, _) => AppErrorState(
          error: error,
          title: "Impossible d'afficher les nouveautés.",
          onRetry: () => ref.invalidate(releaseNotesProvider),
        ),
        data: (list) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: list.length,
              separatorBuilder: (_, _) => const SizedBox(height: 12),
              itemBuilder: (_, i) => _ReleaseNoteCard(note: list[i]),
            ),
          ),
        ),
      ),
    );
  }
}

class _ReleaseNoteCard extends StatelessWidget {
  final ReleaseNote note;

  const _ReleaseNoteCard({required this.note});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final date = note.date;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'v${note.version}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (note.version == kAppVersion)
                  Chip(
                    label: const Text('Installée'),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: cs.secondaryContainer,
                    labelStyle: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSecondaryContainer,
                    ),
                    side: BorderSide.none,
                  ),
              ],
            ),
            if (date != null)
              Text(
                DateFormat('d MMMM y', 'fr').format(date),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            const SizedBox(height: 12),
            MarkdownBody(
              data: note.text,
              selectable: true,
              extensionSet: md.ExtensionSet.gitHubFlavored,
              styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                p: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                listBullet: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
