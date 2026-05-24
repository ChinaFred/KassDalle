import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/utils/web_download.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../features/auth/presentation/auth_providers.dart';
import '../domain/processing_job.dart';
import '../domain/processing_step_labels.dart';

enum ProcessingJobAction {
  retry,
  delete,
  cancel,
  copyId,
  viewSource,
  downloadSource,
}

// ── Tuile d'un job ────────────────────────────────────────────────────────────

class ProcessingJobTile extends ConsumerWidget {
  final ProcessingJob job;
  final bool isSelected;
  final bool isSelecting;
  final bool showOwner;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onRetry;
  final VoidCallback onDelete;
  final VoidCallback? onCancel;
  final bool isAdmin;

  const ProcessingJobTile({
    super.key,
    required this.job,
    required this.isSelected,
    required this.isSelecting,
    this.showOwner = false,
    required this.onTap,
    required this.onLongPress,
    required this.onRetry,
    required this.onDelete,
    this.onCancel,
    this.isAdmin = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    final ownerName = showOwner
        ? ref.watch(userByUidProvider(job.createdBy)).value?.displayName
        : null;

    final subtitleParts = <String>[
      ?ownerName,
      _labelType(job.type),
      if ((job.bookTitre ?? '').isNotEmpty) 'Livre: ${job.bookTitre}',
    ];

    final leading = isSelecting
        ? Checkbox(value: isSelected, onChanged: (_) => onTap())
        : CircleAvatar(
            backgroundColor: theme.colorScheme.secondaryContainer,
            child: Icon(
              _iconForType(job.type),
              color: theme.colorScheme.onSecondaryContainer,
            ),
          );

    return ListTile(
      selected: isSelected,
      leading: leading,
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
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          if (job.errorId != null)
            GestureDetector(
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: job.errorId!));
                if (context.mounted) {
                  context.showSuccessSnackBar('Code erreur copié : ${job.errorId}');
                }
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.content_copy,
                    size: 11,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    'Code : ${job.errorId}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.error,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ],
              ),
            ),
          if (job.currentStep != null &&
              job.status == ProcessingJobStatus.processing)
            Text(
              formatProcessingStep(job.currentStep),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.secondary,
                fontStyle: FontStyle.italic,
              ),
            ),
        ],
      ),
      trailing: isSelecting
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ProcessingJobStatusChip(status: job.status),
                const SizedBox(width: 8),
                Text(
                  _formatDate(job.updatedAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                PopupMenuButton<ProcessingJobAction>(
                  tooltip: 'Actions',
                  onSelected: (action) async {
                    if (action == ProcessingJobAction.retry) onRetry();
                    if (action == ProcessingJobAction.delete) onDelete();
                    if (action == ProcessingJobAction.cancel) onCancel?.call();
                    if (action == ProcessingJobAction.copyId) {
                      await Clipboard.setData(ClipboardData(text: job.id));
                      if (context.mounted) {
                        context.showSuccessSnackBar('ID copié : ${job.id}');
                      }
                    }
                    if (action == ProcessingJobAction.viewSource) {
                      final uri = Uri.parse(job.fileUrl);
                      if (!await launchUrl(
                            uri,
                            mode: LaunchMode.platformDefault,
                          ) &&
                          context.mounted) {
                        context.showSnackBar('Impossible d\'ouvrir le document.');
                      }
                    }
                    if (action == ProcessingJobAction.downloadSource) {
                      final url = job.fileUrl;
                      if (kIsWeb) {
                        final filename = filenameFromStorageUrl(
                          url,
                          fallback: 'document',
                        );
                        final ok = await triggerWebDownload(url, filename);
                        if (ok) return;
                      }
                      final uri = Uri.parse(url);
                      if (!await launchUrl(
                            uri,
                            mode: LaunchMode.externalApplication,
                          ) &&
                          context.mounted) {
                        context.showSnackBar('Impossible de télécharger le document.');
                      }
                    }
                  },
                  itemBuilder: (_) => [
                    if (job.fileUrl.isNotEmpty) ...[
                      const PopupMenuItem(
                        value: ProcessingJobAction.viewSource,
                        child: ListTile(
                          leading: Icon(Icons.document_scanner_outlined),
                          title: Text('Voir le document'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuItem(
                        value: ProcessingJobAction.downloadSource,
                        child: ListTile(
                          leading: Icon(Icons.download_outlined),
                          title: Text('Télécharger'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                    if (isAdmin)
                      PopupMenuItem(
                        value: ProcessingJobAction.copyId,
                        child: ListTile(
                          leading: const Icon(Icons.fingerprint),
                          title: Text(
                            'Copier l\'ID',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.secondary,
                            ),
                          ),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    if (job.status == ProcessingJobStatus.processing)
                      const PopupMenuItem(
                        value: ProcessingJobAction.cancel,
                        child: ListTile(
                          leading: Icon(Icons.stop_circle_outlined),
                          title: Text('Forcer l\'arrêt'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    const PopupMenuItem(
                      value: ProcessingJobAction.retry,
                      child: ListTile(
                        leading: Icon(Icons.refresh),
                        title: Text('Relancer'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    const PopupMenuItem(
                      value: ProcessingJobAction.delete,
                      child: ListTile(
                        leading: Icon(Icons.delete_outline),
                        title: Text('Supprimer'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
              ],
            ),
      onTap: onTap,
      onLongPress: onLongPress,
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
    if (diff.inMinutes < 1) return 'À l\'instant';
    if (diff.inHours < 1) return 'Il y a ${diff.inMinutes} min';
    if (diff.inDays < 1) return 'Il y a ${diff.inHours} h';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}

// ── Chip de statut ────────────────────────────────────────────────────────────

class ProcessingJobStatusChip extends StatelessWidget {
  final ProcessingJobStatus status;

  const ProcessingJobStatusChip({super.key, required this.status});

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
        'Terminé',
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
