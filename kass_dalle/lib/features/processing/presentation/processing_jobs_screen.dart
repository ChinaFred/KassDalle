import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../domain/processing_job.dart';
import 'processing_providers.dart';

class ProcessingJobsScreen extends ConsumerWidget {
  const ProcessingJobsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobsAsync = ref.watch(processingJobsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Etat des traitements')),
      body: jobsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e')),
        data: (jobs) {
          if (jobs.isEmpty) {
            return const Center(child: Text('Aucun traitement pour le moment'));
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemBuilder: (context, index) => _JobTile(job: jobs[index]),
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemCount: jobs.length,
          );
        },
      ),
    );
  }
}

class _JobTile extends StatelessWidget {
  final ProcessingJob job;

  const _JobTile({required this.job});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitleParts = <String>[
      _labelType(job.type),
      if ((job.bookTitre ?? '').isNotEmpty) 'Livre: ${job.bookTitre}',
      _formatDate(job.updatedAt),
    ];

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.secondaryContainer,
        child: Icon(
          _iconForType(job.type),
          color: theme.colorScheme.onSecondaryContainer,
        ),
      ),
      title: Text(job.fileName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(subtitleParts.join(' • ')),
          if ((job.errorMessage ?? '').isNotEmpty)
            Text(
              job.errorMessage!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
      trailing: _StatusChip(status: job.status),
      onTap: () {
        if ((job.createdRecipeIds).isNotEmpty) {
          context.go('/drafts');
          return;
        }
        if ((job.createdBookId ?? '').isNotEmpty) {
          context.push('/books/${job.createdBookId}/edit');
        }
      },
    );
  }

  IconData _iconForType(ProcessingJobType type) => switch (type) {
    ProcessingJobType.recipeScan => Icons.receipt_long_outlined,
    ProcessingJobType.bookCoverScan => Icons.photo_camera_outlined,
    ProcessingJobType.bookDocumentScan => Icons.auto_stories_outlined,
  };

  String _labelType(ProcessingJobType type) => switch (type) {
    ProcessingJobType.recipeScan => 'Scan recette',
    ProcessingJobType.bookCoverScan => 'Scan couverture livre',
    ProcessingJobType.bookDocumentScan => 'Scan livre complet',
  };

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'A l\'instant';
    if (diff.inHours < 1) return 'Il y a ${diff.inMinutes} min';
    if (diff.inDays < 1) return 'Il y a ${diff.inHours} h';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}

class _StatusChip extends StatelessWidget {
  final ProcessingJobStatus status;

  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final (label, bg, fg) = switch (status) {
      ProcessingJobStatus.queued => (
        'En file',
        theme.colorScheme.surfaceContainerHighest,
        theme.colorScheme.onSurface,
      ),
      ProcessingJobStatus.processing => (
        'Traitement',
        theme.colorScheme.secondaryContainer,
        theme.colorScheme.onSecondaryContainer,
      ),
      ProcessingJobStatus.done => (
        'Termine',
        theme.colorScheme.primaryContainer,
        theme.colorScheme.onPrimaryContainer,
      ),
      ProcessingJobStatus.error => (
        'Erreur',
        theme.colorScheme.errorContainer,
        theme.colorScheme.onErrorContainer,
      ),
    };

    return Chip(
      label: Text(label),
      backgroundColor: bg,
      labelStyle: TextStyle(color: fg, fontSize: 11),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }
}
