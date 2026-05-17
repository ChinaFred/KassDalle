import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/utils/web_download.dart';
import '../../../features/auth/presentation/auth_providers.dart';
import '../../../features/recipes/presentation/recipe_providers.dart';
import '../domain/processing_job.dart';
import 'processing_providers.dart';

class ProcessingJobsScreen extends ConsumerStatefulWidget {
  const ProcessingJobsScreen({super.key});

  @override
  ConsumerState<ProcessingJobsScreen> createState() =>
      _ProcessingJobsScreenState();
}

class _ProcessingJobsScreenState extends ConsumerState<ProcessingJobsScreen> {
  final Set<String> _selected = {};

  bool get _isSelecting => _selected.isNotEmpty;

  bool _showDone = false;

  List<ProcessingJob> _filterJobs(List<ProcessingJob> all) => _showDone
      ? all
      : all
            .where(
              (j) =>
                  j.status == ProcessingJobStatus.queued ||
                  j.status == ProcessingJobStatus.processing ||
                  j.status == ProcessingJobStatus.error,
            )
            .toList();

  void _toggleSelect(String id) => setState(() {
    _selected.contains(id) ? _selected.remove(id) : _selected.add(id);
  });

  void _selectAll(List<ProcessingJob> jobs) =>
      setState(() => _selected.addAll(jobs.map((j) => j.id)));

  void _clearSelection() => setState(() => _selected.clear());

  Future<void> _retrySelected(List<ProcessingJob> jobs) async {
    final toRetry = jobs.where((j) => _selected.contains(j.id)).toList();
    _clearSelection();
    final notifier = ref.read(scanUploadProvider.notifier);
    for (final job in toRetry) {
      await notifier.retryJob(job);
    }
  }

  Future<void> _deleteSelected(List<ProcessingJob> all) async {
    final count = _selected.length;
    final confirmed = await _showDeleteDialog(count);
    if (!confirmed) return;
    final ids = Set<String>.from(_selected);
    _clearSelection();
    final repo = ref.read(processingJobRepositoryProvider);
    for (final id in ids) {
      await repo.deleteJob(id);
    }
  }

  Future<bool> _showDeleteDialog(int count) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          count == 1
              ? 'Supprimer ce traitement ?'
              : 'Supprimer $count traitements ?',
        ),
        content: const Text('Cette action est irréversible.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _handleTap(BuildContext context, ProcessingJob job) {
    if (_isSelecting) {
      _toggleSelect(job.id);
      return;
    }
    if (job.createdRecipeIds.isNotEmpty) {
      context.go('/drafts');
    } else if ((job.createdBookId ?? '').isNotEmpty) {
      context.push('/books/${job.createdBookId}/edit');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    final jobsAsync = isAdmin
        ? ref.watch(filteredAdminJobsProvider)
        : ref.watch(processingJobsProvider);

    final rawJobs = jobsAsync.value;
    final jobs = rawJobs != null ? _filterJobs(rawJobs) : null;
    final allSelected =
        jobs != null && jobs.isNotEmpty && _selected.length == jobs.length;

    return Scaffold(
      appBar: jobs == null
          ? AppBar(title: const Text('Traitements'))
          : _isSelecting
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Annuler la sélection',
                onPressed: _clearSelection,
              ),
              title: Text('${_selected.length} sélectionné(s)'),
              actions: [
                IconButton(
                  icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
                  tooltip: allSelected
                      ? 'Tout désélectionner'
                      : 'Tout sélectionner',
                  onPressed: allSelected
                      ? _clearSelection
                      : () => _selectAll(jobs),
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Relancer la sélection',
                  onPressed: () => _retrySelected(jobs),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Supprimer la sélection',
                  onPressed: () => _deleteSelected(jobs),
                ),
              ],
            )
          : AppBar(
              title: const Text('Traitements'),
              actions: [
                IconButton(
                  icon: Icon(
                    _showDone ? Icons.check_circle : Icons.check_circle_outline,
                  ),
                  tooltip: _showDone
                      ? 'Masquer les terminés'
                      : 'Afficher les terminés',
                  isSelected: _showDone,
                  onPressed: () => setState(() {
                    _showDone = !_showDone;
                    if (!_showDone) _clearSelection();
                  }),
                ),
                if (isAdmin) _AdminUserFilter(),
                const SizedBox(width: 8),
              ],
            ),
      body: jobsAsync.when(
        skipLoadingOnReload: true,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e')),
        data: (rawJobs) {
          final jobs = _filterJobs(rawJobs);
          if (jobs.isEmpty) {
            if (!_showDone && rawJobs.isNotEmpty) {
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Aucun traitement en cours ou en erreur'),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      icon: const Icon(Icons.visibility),
                      label: const Text('Afficher les terminés'),
                      onPressed: () => setState(() => _showDone = true),
                    ),
                  ],
                ),
              );
            }
            return const Center(child: Text('Aucun traitement pour le moment'));
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: jobs.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final job = jobs[index];
              return _JobTile(
                job: job,
                isSelected: _selected.contains(job.id),
                isSelecting: _isSelecting,
                showOwner: isAdmin,
                onTap: () => _handleTap(context, job),
                onLongPress: () => _toggleSelect(job.id),
                onRetry: () =>
                    ref.read(scanUploadProvider.notifier).retryJob(job),
                onCancel: () =>
                    ref.read(scanUploadProvider.notifier).cancelJob(job.id),
                onDelete: () async {
                  final ok = await _showDeleteDialog(1);
                  if (!mounted) return;
                  if (ok) {
                    await ref
                        .read(processingJobRepositoryProvider)
                        .deleteJob(job.id);
                  }
                },
              );
            },
          );
        },
      ),
    );
  }
}

// ── Filtre utilisateur (admin) ─────────────────────────────────────────────────

class _AdminUserFilter extends ConsumerWidget {
  const _AdminUserFilter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allJobsAsync = ref.watch(allProcessingJobsProvider);
    final currentFilter = ref.watch(adminJobUserFilterProvider);

    final uniqueUids =
        allJobsAsync.value?.map((j) => j.createdBy).toSet().toList() ?? [];

    if (uniqueUids.length <= 1) return const SizedBox.shrink();

    return DropdownButtonHideUnderline(
      child: DropdownButton<String?>(
        value: currentFilter,
        hint: const Text('Tous les utilisateurs'),
        isDense: true,
        items: [
          const DropdownMenuItem<String?>(child: Text('Tous les utilisateurs')),
          ...uniqueUids.map(
            (uid) => DropdownMenuItem<String?>(
              value: uid,
              child: _UserDropdownItem(uid: uid),
            ),
          ),
        ],
        onChanged: (uid) =>
            ref.read(adminJobUserFilterProvider.notifier).setFilter(uid),
      ),
    );
  }
}

class _UserDropdownItem extends ConsumerWidget {
  final String uid;
  const _UserDropdownItem({required this.uid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(userByUidProvider(uid));
    final name = userAsync.value?.displayName ?? uid.substring(0, 8);
    return Text(name);
  }
}

// ── Tuile d'un job ────────────────────────────────────────────────────────────

class _JobTile extends ConsumerWidget {
  final ProcessingJob job;
  final bool isSelected;
  final bool isSelecting;
  final bool showOwner;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onRetry;
  final VoidCallback onDelete;
  final VoidCallback? onCancel;

  const _JobTile({
    required this.job,
    required this.isSelected,
    required this.isSelecting,
    this.showOwner = false,
    required this.onTap,
    required this.onLongPress,
    required this.onRetry,
    required this.onDelete,
    this.onCancel,
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
            ),
          if (job.currentStep != null &&
              job.status == ProcessingJobStatus.processing)
            Text(
              job.currentStep!,
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
                _StatusChip(status: job.status),
                const SizedBox(width: 8),
                Text(
                  _formatDate(job.updatedAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                PopupMenuButton<_JobAction>(
                  tooltip: 'Actions',
                  onSelected: (action) async {
                    if (action == _JobAction.retry) onRetry();
                    if (action == _JobAction.delete) onDelete();
                    if (action == _JobAction.cancel) onCancel?.call();
                    if (action == _JobAction.viewSource) {
                      final uri = Uri.parse(job.fileUrl);
                      if (!await launchUrl(uri, mode: LaunchMode.platformDefault) && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Impossible d\'ouvrir le document.')),
                        );
                      }
                    }
                    if (action == _JobAction.downloadSource) {
                      final url = job.fileUrl;
                      if (kIsWeb) {
                        final filename = filenameFromStorageUrl(url, fallback: 'document');
                        final ok = await triggerWebDownload(url, filename);
                        if (ok) return;
                      }
                      final uri = Uri.parse(url);
                      if (!await launchUrl(uri, mode: LaunchMode.externalApplication) && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Impossible de télécharger le document.')),
                        );
                      }
                    }
                  },
                  itemBuilder: (_) => [
                    if (job.fileUrl.isNotEmpty) ...[
                      const PopupMenuItem(
                        value: _JobAction.viewSource,
                        child: ListTile(
                          leading: Icon(Icons.document_scanner_outlined),
                          title: Text('Voir le document'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuItem(
                        value: _JobAction.downloadSource,
                        child: ListTile(
                          leading: Icon(Icons.download_outlined),
                          title: Text('Télécharger'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                    if (job.status == ProcessingJobStatus.processing)
                      const PopupMenuItem(
                        value: _JobAction.cancel,
                        child: ListTile(
                          leading: Icon(Icons.stop_circle_outlined),
                          title: Text('Forcer l\'arrêt'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    const PopupMenuItem(
                      value: _JobAction.retry,
                      child: ListTile(
                        leading: Icon(Icons.refresh),
                        title: Text('Relancer'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    const PopupMenuItem(
                      value: _JobAction.delete,
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

enum _JobAction { retry, delete, cancel, viewSource, downloadSource }

// ── Chip de statut ────────────────────────────────────────────────────────────

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
