import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../features/auth/presentation/auth_providers.dart';
import '../../../features/recipes/presentation/recipe_providers.dart';
import '../domain/processing_job.dart';
import 'processing_job_tile.dart';
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
                  j.status == ProcessingJobStatus.error ||
                  j.status == ProcessingJobStatus.rejected,
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
              return ProcessingJobTile(
                job: job,
                isSelected: _selected.contains(job.id),
                isSelecting: _isSelecting,
                showOwner: isAdmin,
                isAdmin: isAdmin,
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
