import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../features/auth/presentation/auth_providers.dart';
import '../../../features/recipes/presentation/recipe_providers.dart';
import '../../../features/recipes/presentation/source_viewer.dart';
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
      builder: (_) => AlertDialog(
        title: Text(
          count == 1
              ? 'Supprimer ce traitement ?'
              : 'Supprimer $count traitements ?',
        ),
        content: const Text('Cette action est irréversible.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
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

    return jobsAsync.when(
      skipLoadingOnReload: true,
      loading: () => Scaffold(
        appBar: AppBar(title: const Text('Traitements')),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Traitements')),
        body: Center(child: Text('Erreur : $e')),
      ),
      data: (jobs) {
        final allSelected = jobs.isNotEmpty && _selected.length == jobs.length;

        return Scaffold(
          appBar: _isSelecting
              ? AppBar(
                  leading: IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Annuler la sélection',
                    onPressed: _clearSelection,
                  ),
                  title: Text('${_selected.length} sélectionné(s)'),
                  actions: [
                    IconButton(
                      icon: Icon(
                        allSelected ? Icons.deselect : Icons.select_all,
                      ),
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
                    if (isAdmin) _AdminUserFilter(),
                    const SizedBox(width: 8),
                  ],
                ),
          body: jobs.isEmpty
              ? const Center(child: Text('Aucun traitement pour le moment'))
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: jobs.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
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
                      onDelete: () async {
                        final ok = await _showDeleteDialog(1);
                        if (ok) {
                          await ref
                              .read(processingJobRepositoryProvider)
                              .deleteJob(job.id);
                        }
                      },
                    );
                  },
                ),
        );
      },
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
        allJobsAsync.valueOrNull?.map((j) => j.createdBy).toSet().toList() ??
        [];

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
            ref.read(adminJobUserFilterProvider.notifier).state = uid,
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
    final name = userAsync.valueOrNull?.displayName ?? uid.substring(0, 8);
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

  const _JobTile({
    required this.job,
    required this.isSelected,
    required this.isSelecting,
    this.showOwner = false,
    required this.onTap,
    required this.onLongPress,
    required this.onRetry,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    final ownerName = showOwner
        ? ref.watch(userByUidProvider(job.createdBy)).valueOrNull?.displayName
        : null;

    final subtitleParts = <String>[
      if (ownerName != null) ownerName,
      _labelType(job.type),
      if ((job.bookTitre ?? '').isNotEmpty) 'Livre: ${job.bookTitre}',
      _formatDate(job.updatedAt),
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
        ],
      ),
      trailing: isSelecting
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _StatusChip(status: job.status),
                if (job.fileUrl.isNotEmpty)
                  SourceViewerButton(
                    sourceFileUrl: job.fileUrl,
                    sourceFileName: job.fileName,
                  ),
                PopupMenuButton<_JobAction>(
                  tooltip: 'Actions',
                  onSelected: (action) {
                    if (action == _JobAction.retry) onRetry();
                    if (action == _JobAction.delete) onDelete();
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: _JobAction.retry,
                      child: ListTile(
                        leading: Icon(Icons.refresh),
                        title: Text('Relancer'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    PopupMenuItem(
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

enum _JobAction { retry, delete }

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
