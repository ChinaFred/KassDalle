import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/utils/web_download.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../processing/domain/processing_job.dart';
import '../../../processing/domain/processing_step_labels.dart';
import '../../../processing/presentation/processing_providers.dart';
import '../../domain/recipe.dart';

// ── Mode de filtre (public car utilisé par le screen) ─────────────────────────

enum WorkQueueFilter { me, family, allUsers }

// ── Filtre dropdown ────────────────────────────────────────────────────────────

class WorkQueueFilterDropdown extends StatelessWidget {
  final bool isAdmin;
  final WorkQueueFilter filterMode;
  final ValueChanged<WorkQueueFilter> onChanged;

  const WorkQueueFilterDropdown({
    super.key,
    required this.isAdmin,
    required this.filterMode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final options = [
      (WorkQueueFilter.me, 'Mes éléments'),
      (WorkQueueFilter.family, 'Groupe familial'),
      if (isAdmin) (WorkQueueFilter.allUsers, 'Tous les utilisateurs'),
    ];
    return DropdownButtonHideUnderline(
      child: DropdownButton<WorkQueueFilter>(
        value: filterMode,
        isDense: true,
        items: options
            .map((opt) => DropdownMenuItem(value: opt.$1, child: Text(opt.$2)))
            .toList(),
        onChanged: (mode) {
          if (mode != null) onChanged(mode);
        },
      ),
    );
  }
}

// ── Filtre UID admin ──────────────────────────────────────────────────────────

class WorkQueueAdminUidFilter extends ConsumerWidget {
  final List<ProcessingJob> allJobs;
  final List<Recipe> allDrafts;

  const WorkQueueAdminUidFilter({
    super.key,
    required this.allJobs,
    required this.allDrafts,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentFilter = ref.watch(adminJobUserFilterProvider);
    final uids = {
      ...allJobs.map((j) => j.createdBy),
      ...allDrafts.map((d) => d.createdBy),
    }.toList();
    if (uids.length <= 1) return const SizedBox.shrink();
    return DropdownButtonHideUnderline(
      child: DropdownButton<String?>(
        value: currentFilter,
        hint: const Text('Tous'),
        isDense: true,
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('Tous')),
          ...uids.map(
            (uid) => DropdownMenuItem<String?>(
              value: uid,
              child: _UserNameText(uid: uid),
            ),
          ),
        ],
        onChanged: (uid) =>
            ref.read(adminJobUserFilterProvider.notifier).setFilter(uid),
      ),
    );
  }
}

class _UserNameText extends ConsumerWidget {
  final String uid;
  const _UserNameText({required this.uid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name =
        ref.watch(userByUidProvider(uid)).value?.displayName ??
        uid.substring(0, 8);
    return Text(name);
  }
}

// ── En-tête de section par propriétaire ───────────────────────────────────────

class WorkQueueSectionHeader extends ConsumerWidget {
  final String ownerUid;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;

  const WorkQueueSectionHeader({
    super.key,
    required this.ownerUid,
    required this.count,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final name = ownerUid == '__me'
        ? 'Mes éléments'
        : ref.watch(userByUidProvider(ownerUid)).value?.displayName ?? '…';

    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Row(
          children: [
            Text(
              name,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Chip(
              label: Text('$count'),
              labelStyle: theme.textTheme.labelSmall,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
            const Spacer(),
            Icon(
              expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Tuile traitement ──────────────────────────────────────────────────────────

class QueueJobTile extends StatelessWidget {
  final ProcessingJob job;
  final bool isSelected;
  final bool isSelecting;
  final bool isAdmin;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onRetry;
  final VoidCallback onDelete;
  final VoidCallback? onCancel;

  const QueueJobTile({
    super.key,
    required this.job,
    required this.isSelected,
    required this.isSelecting,
    required this.onTap,
    required this.onLongPress,
    required this.onRetry,
    required this.onDelete,
    this.isAdmin = false,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasError = (job.errorMessage ?? '').isNotEmpty;

    final subtitle = [
      _labelType(job.type),
      if ((job.bookTitre ?? '').isNotEmpty) job.bookTitre!,
    ].join(' • ');

    return ListTile(
      selected: isSelected,
      selectedTileColor: theme.colorScheme.primaryContainer.withValues(
        alpha: 0.3,
      ),
      leading: isSelecting
          ? Checkbox(value: isSelected, onChanged: (_) => onTap())
          : CircleAvatar(
              backgroundColor: theme.colorScheme.secondaryContainer,
              child: Icon(
                _iconForType(job.type),
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
      title: Text(job.fileName, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(subtitle, style: theme.textTheme.bodySmall),
          if (job.status == ProcessingJobStatus.processing &&
              job.currentStep != null)
            Text(
              formatProcessingStep(job.currentStep),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.secondary,
                fontStyle: FontStyle.italic,
              ),
            ),
          if (hasError) _ErrorBadge(errorMessage: job.errorMessage!),
          if (job.errorId != null) _ErrorIdChip(errorId: job.errorId!),
        ],
      ),
      isThreeLine:
          hasError ||
          (job.status == ProcessingJobStatus.processing &&
              job.currentStep != null),
      trailing: isSelecting
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _JobStatusChip(status: job.status),
                const SizedBox(width: 8),
                Text(
                  _formatDate(job.updatedAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                PopupMenuButton<_JobMenuAction>(
                  tooltip: 'Actions',
                  onSelected: (action) async {
                    if (action == _JobMenuAction.retry) onRetry();
                    if (action == _JobMenuAction.delete) onDelete();
                    if (action == _JobMenuAction.cancel) onCancel?.call();
                    if (action == _JobMenuAction.copyId) {
                      await Clipboard.setData(ClipboardData(text: job.id));
                      if (context.mounted) {
                        context.showSuccessSnackBar('ID copié : ${job.id}');
                      }
                    }
                    if (action == _JobMenuAction.viewSource) {
                      final uri = Uri.parse(job.fileUrl);
                      if (!await launchUrl(
                            uri,
                            mode: LaunchMode.platformDefault,
                          ) &&
                          context.mounted) {
                        context.showSnackBar(
                          'Impossible d\'ouvrir le document.',
                        );
                      }
                    }
                    if (action == _JobMenuAction.downloadSource) {
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
                        context.showSnackBar(
                          'Impossible de télécharger le document.',
                        );
                      }
                    }
                  },
                  itemBuilder: (_) => [
                    if (job.fileUrl.isNotEmpty) ...[
                      const PopupMenuItem(
                        value: _JobMenuAction.viewSource,
                        child: ListTile(
                          leading: Icon(Icons.document_scanner_outlined),
                          title: Text('Voir le document'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuItem(
                        value: _JobMenuAction.downloadSource,
                        child: ListTile(
                          leading: Icon(Icons.download_outlined),
                          title: Text('Télécharger'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                    if (job.status == ProcessingJobStatus.processing)
                      const PopupMenuItem(
                        value: _JobMenuAction.cancel,
                        child: ListTile(
                          leading: Icon(Icons.stop_circle_outlined),
                          title: Text('Forcer l\'arrêt'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    if (isAdmin)
                      PopupMenuItem(
                        value: _JobMenuAction.copyId,
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
                    if (job.status != ProcessingJobStatus.rejected)
                      const PopupMenuItem(
                        value: _JobMenuAction.retry,
                        child: ListTile(
                          leading: Icon(Icons.refresh),
                          title: Text('Relancer'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    const PopupMenuItem(
                      value: _JobMenuAction.delete,
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
    ProcessingJobType.bookCoverScan => 'Scan couverture',
    ProcessingJobType.bookDocumentScan => 'Scan livre',
  };

  String _formatDate(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return "À l'instant";
    if (diff.inHours < 1) return 'Il y a ${diff.inMinutes} min';
    if (diff.inDays < 1) return 'Il y a ${diff.inHours} h';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}

enum _JobMenuAction {
  retry,
  delete,
  cancel,
  copyId,
  viewSource,
  downloadSource,
}

// ── Tuile brouillon ───────────────────────────────────────────────────────────

class QueueDraftTile extends StatelessWidget {
  final Recipe recipe;
  final bool isSelected;
  final bool isSelecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onValidate;
  final VoidCallback onDelete;

  const QueueDraftTile({
    super.key,
    required this.recipe,
    required this.isSelected,
    required this.isSelecting,
    required this.onTap,
    required this.onLongPress,
    required this.onValidate,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListTile(
      selected: isSelected,
      selectedTileColor: theme.colorScheme.primaryContainer.withValues(
        alpha: 0.3,
      ),
      leading: isSelecting
          ? Checkbox(value: isSelected, onChanged: (_) => onTap())
          : CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(
                Icons.edit_document,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
      title: Text(recipe.titre, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (recipe.sourceFileName != null)
            Text(
              recipe.sourceFileName!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          if (recipe.bookTitre != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.menu_book,
                  size: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    recipe.bookTitre!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
        ],
      ),
      trailing: isSelecting
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _DraftStatusChip(status: recipe.reviewStatus),
                const SizedBox(width: 4),
                Text(
                  _formatDate(recipe.updatedAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                PopupMenuButton<_DraftMenuAction>(
                  tooltip: 'Actions',
                  onSelected: (action) async {
                    if (action == _DraftMenuAction.validate) onValidate();
                    if (action == _DraftMenuAction.delete) onDelete();
                    if (action == _DraftMenuAction.viewSource) {
                      final url = recipe.sourceFileUrl;
                      if (url != null && url.isNotEmpty) {
                        await launchUrl(
                          Uri.parse(url),
                          mode: LaunchMode.platformDefault,
                        );
                      }
                    }
                    if (action == _DraftMenuAction.downloadSource) {
                      final url = recipe.sourceFileUrl;
                      if (url != null && url.isNotEmpty) {
                        if (kIsWeb) {
                          final filename = filenameFromStorageUrl(
                            url,
                            fallback: recipe.sourceFileName ?? 'document',
                          );
                          final ok = await triggerWebDownload(url, filename);
                          if (ok) return;
                        }
                        await launchUrl(
                          Uri.parse(url),
                          mode: LaunchMode.externalApplication,
                        );
                      }
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: _DraftMenuAction.validate,
                      child: ListTile(
                        leading: Icon(Icons.check_circle_outline),
                        title: Text('Valider'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    if (recipe.sourceFileUrl != null &&
                        recipe.sourceFileUrl!.isNotEmpty) ...[
                      const PopupMenuItem(
                        value: _DraftMenuAction.viewSource,
                        child: ListTile(
                          leading: Icon(Icons.visibility_outlined),
                          title: Text('Voir le document'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuItem(
                        value: _DraftMenuAction.downloadSource,
                        child: ListTile(
                          leading: Icon(Icons.download_outlined),
                          title: Text('Télécharger'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                    const PopupMenuItem(
                      value: _DraftMenuAction.delete,
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

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return "\u00c0 l'instant";
    if (diff.inHours < 1) return 'Il y a ${diff.inMinutes} min';
    if (diff.inDays < 1) return 'Il y a ${diff.inHours} h';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}

enum _DraftMenuAction { validate, delete, viewSource, downloadSource }

// ── Chip statut traitement ────────────────────────────────────────────────────

class _JobStatusChip extends StatelessWidget {
  final ProcessingJobStatus status;
  const _JobStatusChip({required this.status});

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
      ProcessingJobStatus.rejected => (
        'Rejeté',
        theme.colorScheme.error,
        theme.colorScheme.onError,
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

// ── Chip statut brouillon ─────────────────────────────────────────────────────

class _DraftStatusChip extends StatelessWidget {
  final ReviewStatus status;
  const _DraftStatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, bg, fg) = switch (status) {
      ReviewStatus.draft => (
        'Brouillon',
        theme.colorScheme.surfaceContainerHighest,
        theme.colorScheme.onSurface,
      ),
      ReviewStatus.inReview => (
        'En révision',
        theme.colorScheme.secondaryContainer,
        theme.colorScheme.onSecondaryContainer,
      ),
      ReviewStatus.validated => (
        'Validé',
        theme.colorScheme.primaryContainer,
        theme.colorScheme.onPrimaryContainer,
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

// ── Badge d'erreur avec tooltip + dialogue copie ──────────────────────────────

class _ErrorBadge extends StatelessWidget {
  final String errorMessage;
  const _ErrorBadge({required this.errorMessage});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onLongPress: () => _showErrorDialog(context, errorMessage),
      child: Tooltip(
        message: errorMessage,
        child: Text(
          errorMessage,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.error,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  void _showErrorDialog(BuildContext context, String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Détail de l'erreur"),
        content: SelectableText(message),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: message));
              Navigator.pop(ctx);
              context.showSuccessSnackBar('Copié dans le presse-papier');
            },
            child: const Text('Copier'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  }
}

// ── Chip code erreur (copiable en 1 tap) ─────────────────────────────────────

class _ErrorIdChip extends StatelessWidget {
  final String errorId;
  const _ErrorIdChip({required this.errorId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: errorId));
        if (context.mounted) {
          context.showSuccessSnackBar('Code erreur copié : $errorId');
        }
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.content_copy, size: 11, color: theme.colorScheme.error),
          const SizedBox(width: 3),
          Text(
            'Code : $errorId',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.error,
              decoration: TextDecoration.underline,
            ),
          ),
        ],
      ),
    );
  }
}
