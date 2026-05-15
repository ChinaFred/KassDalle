import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'work_queue_widgets.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../processing/domain/processing_job.dart';
import '../../../processing/presentation/processing_providers.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';

// ── Modèle unifié ──────────────────────────────────────────────────────────────

sealed class _QueueItem {
  String get key;
  String get ownerId;
  DateTime get sortDate;
}

final class _JobItem extends _QueueItem {
  final ProcessingJob job;
  _JobItem(this.job);
  @override
  String get key => 'j:${job.id}';
  @override
  String get ownerId => job.createdBy;
  @override
  DateTime get sortDate => job.updatedAt;
}

final class _DraftItem extends _QueueItem {
  final Recipe recipe;
  _DraftItem(this.recipe);
  @override
  String get key => 'd:${recipe.id}';
  @override
  String get ownerId => recipe.createdBy;
  @override
  DateTime get sortDate => recipe.updatedAt;
}

// ── Section par propriétaire ──────────────────────────────────────────────────

class _Section {
  final String ownerUid; // '__me' pour l'utilisateur courant
  final List<_QueueItem> items;
  _Section({required this.ownerUid, required this.items});
}

// ── Screen ────────────────────────────────────────────────────────────────────

class WorkQueueScreen extends ConsumerStatefulWidget {
  const WorkQueueScreen({super.key});

  @override
  ConsumerState<WorkQueueScreen> createState() => _WorkQueueScreenState();
}

class _WorkQueueScreenState extends ConsumerState<WorkQueueScreen> {
  WorkQueueFilter _filterMode = WorkQueueFilter.me;
  final Set<String> _selected = {};
  final Set<String> _collapsedOwners = {};

  bool get _isSelecting => _selected.isNotEmpty;
  bool get _hasSelectedDrafts => _selected.any((k) => k.startsWith('d:'));
  bool get _hasSelectedJobs => _selected.any((k) => k.startsWith('j:'));

  void _toggleSelect(String key) => setState(() {
    _selected.contains(key) ? _selected.remove(key) : _selected.add(key);
  });

  void _clearSelection() => setState(() => _selected.clear());

  void _selectAll(List<_QueueItem> items) =>
      setState(() => _selected.addAll(items.map((i) => i.key)));

  // ── Construction des sections ──────────────────────────────────────────────

  List<_Section> _buildSections({
    required String myUid,
    required List<ProcessingJob> myJobs,
    required List<Recipe> myDrafts,
    required List<Recipe> familyDrafts,
    required List<ProcessingJob> allJobs,
    required List<Recipe> allDrafts,
    required String? adminUidFilter,
  }) {
    bool isActive(ProcessingJob j) =>
        j.status == ProcessingJobStatus.queued ||
        j.status == ProcessingJobStatus.processing ||
        j.status == ProcessingJobStatus.error;

    switch (_filterMode) {
      case WorkQueueFilter.me:
        final items = [
          ...myJobs.where(isActive).map(_JobItem.new),
          ...myDrafts.map(_DraftItem.new),
        ];
        items.sort((a, b) => b.sortDate.compareTo(a.sortDate));
        return [_Section(ownerUid: '__me', items: items)];

      case WorkQueueFilter.family:
        final myItems = [
          ...myJobs.where(isActive).map(_JobItem.new),
          ...myDrafts.map(_DraftItem.new),
        ];
        myItems.sort((a, b) => b.sortDate.compareTo(a.sortDate));
        final byOwner = <String, List<_QueueItem>>{};
        for (final r in familyDrafts) {
          (byOwner[r.createdBy] ??= []).add(_DraftItem(r));
        }
        for (final items in byOwner.values) {
          items.sort((a, b) => b.sortDate.compareTo(a.sortDate));
        }
        return [
          _Section(ownerUid: '__me', items: myItems),
          ...byOwner.entries.map(
            (e) => _Section(ownerUid: e.key, items: e.value),
          ),
        ];

      case WorkQueueFilter.allUsers:
        final activeJobs = allJobs
            .where(isActive)
            .where(
              (j) => adminUidFilter == null || j.createdBy == adminUidFilter,
            )
            .toList();
        final filteredDrafts = allDrafts
            .where(
              (d) => adminUidFilter == null || d.createdBy == adminUidFilter,
            )
            .toList();
        final byOwner = <String, List<_QueueItem>>{};
        for (final j in activeJobs) {
          (byOwner[j.createdBy] ??= []).add(_JobItem(j));
        }
        for (final d in filteredDrafts) {
          (byOwner[d.createdBy] ??= []).add(_DraftItem(d));
        }
        for (final items in byOwner.values) {
          items.sort((a, b) => b.sortDate.compareTo(a.sortDate));
        }
        final sections = byOwner.entries
            .map((e) => _Section(ownerUid: e.key, items: e.value))
            .toList();
        sections.sort(
          (a, b) => b.items.first.sortDate.compareTo(a.items.first.sortDate),
        );
        return sections;
    }
  }

  // ── Actions groupées ───────────────────────────────────────────────────────

  Future<void> _batchValidate(List<_QueueItem> allItems) async {
    final drafts = allItems
        .whereType<_DraftItem>()
        .where((i) => _selected.contains(i.key))
        .toList();
    if (drafts.isEmpty) return;
    final confirmed = await _showConfirmDialog(
      title: 'Valider ${drafts.length} brouillon(s) ?',
      content: 'Les recettes sélectionnées seront publiées.',
    );
    if (!confirmed || !mounted) return;
    _clearSelection();
    final repo = ref.read(recipeRepositoryProvider);
    final myUid = ref.read(appUserProvider).value?.uid ?? '';
    for (final item in drafts) {
      final r = item.recipe;
      final content = r.draftCooklang ?? r.rawCooklang;
      await repo.validateDraft(
        recipeId: r.id,
        editedCooklang: content,
        titre: r.titre,
        callerUid: myUid,
        bookId: r.bookId,
        bookTitre: r.bookTitre,
        pageNumberOverride: r.pageNumber,
        tagsOverride: r.tags,
        portionsOverride: r.portions,
        ingredientsOverride: r.ingredients,
      );
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${drafts.length} brouillon(s) validé(s) !')),
      );
    }
  }

  Future<void> _batchRetry(List<_QueueItem> allItems) async {
    final jobs = allItems
        .whereType<_JobItem>()
        .where((i) => _selected.contains(i.key))
        .toList();
    if (jobs.isEmpty) return;
    _clearSelection();
    final notifier = ref.read(scanUploadProvider.notifier);
    for (final item in jobs) {
      await notifier.retryJob(item.job);
    }
  }

  Future<void> _batchDelete(List<_QueueItem> allItems) async {
    final count = _selected.length;
    final confirmed = await _showConfirmDialog(
      title: 'Supprimer $count élément(s) ?',
      content: 'Cette action est irréversible.',
      isDangerous: true,
    );
    if (!confirmed || !mounted) return;
    final keys = Set<String>.from(_selected);
    _clearSelection();
    final jobRepo = ref.read(processingJobRepositoryProvider);
    final recipeRepo = ref.read(recipeRepositoryProvider);
    for (final key in keys) {
      if (key.startsWith('j:')) {
        await jobRepo.deleteJob(key.substring(2));
      } else if (key.startsWith('d:')) {
        await recipeRepo.deleteRecipe(key.substring(2));
      }
    }
  }

  Future<bool> _showConfirmDialog({
    required String title,
    required String content,
    bool isDangerous = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: isDangerous
                ? FilledButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                    foregroundColor: Theme.of(ctx).colorScheme.onError,
                  )
                : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirmer'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(isAdminProvider);
    final adminUidFilter = ref.watch(adminJobUserFilterProvider);

    final myJobsAsync = ref.watch(processingJobsProvider);
    final myDraftsAsync = ref.watch(draftsProvider);
    final familyDraftsAsync = ref.watch(groupMemberDraftsProvider);
    final allJobsAsync = isAdmin ? ref.watch(allProcessingJobsProvider) : null;
    final allDraftsAsync = isAdmin ? ref.watch(allDraftsProvider) : null;

    if (myJobsAsync.isLoading || myDraftsAsync.isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final myJobs = myJobsAsync.value ?? [];
    final myDrafts = myDraftsAsync.value ?? [];
    final familyDrafts = familyDraftsAsync.value ?? [];
    final allJobs = allJobsAsync?.value ?? [];
    final allDrafts = allDraftsAsync?.value ?? [];

    // Forcer le mode "me" si non-admin tente allUsers
    if (_filterMode == WorkQueueFilter.allUsers && !isAdmin) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => setState(() => _filterMode = WorkQueueFilter.me),
      );
    }

    final sections = _buildSections(
      myUid: ref.watch(appUserProvider).value?.uid ?? '',
      myJobs: myJobs,
      myDrafts: myDrafts,
      familyDrafts: familyDrafts,
      allJobs: allJobs,
      allDrafts: allDrafts,
      adminUidFilter: adminUidFilter,
    );

    final allItems = sections.expand((s) => s.items).toList();
    final allKeys = allItems.map((i) => i.key).toSet();
    final allSelected =
        allKeys.isNotEmpty && allKeys.every((k) => _selected.contains(k));

    // AppBar dynamique
    final appBar = _isSelecting
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
                    : () => _selectAll(allItems),
              ),
              // Valider — actif uniquement si sélection = brouillons uniquement
              IconButton(
                icon: const Icon(Icons.check_circle_outline),
                tooltip: 'Valider les brouillons',
                color: (_hasSelectedDrafts && !_hasSelectedJobs)
                    ? null
                    : Theme.of(context).disabledColor,
                onPressed: (_hasSelectedDrafts && !_hasSelectedJobs)
                    ? () => _batchValidate(allItems)
                    : null,
              ),
              // Relancer — actif uniquement si sélection = jobs uniquement
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Relancer les traitements',
                color: (!_hasSelectedDrafts && _hasSelectedJobs)
                    ? null
                    : Theme.of(context).disabledColor,
                onPressed: (!_hasSelectedDrafts && _hasSelectedJobs)
                    ? () => _batchRetry(allItems)
                    : null,
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Supprimer la sélection',
                onPressed: () => _batchDelete(allItems),
              ),
            ],
          )
        : AppBar(
            title: const Text('Brouillons & Traitements'),
            actions: [
              WorkQueueFilterDropdown(
                isAdmin: isAdmin,
                filterMode: _filterMode,
                onChanged: (mode) => setState(() => _filterMode = mode),
              ),
              if (isAdmin && _filterMode == WorkQueueFilter.allUsers)
                WorkQueueAdminUidFilter(allJobs: allJobs, allDrafts: allDrafts),
              IconButton(
                icon: const Icon(Icons.upload_file),
                tooltip: 'Importer un scan',
                onPressed: () => context.go('/scan'),
              ),
              const SizedBox(width: 8),
            ],
          );

    if (allItems.isEmpty) {
      return Scaffold(
        appBar: appBar,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.edit_note,
                size: 64,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                'Aucun élément',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Importez un scan pour commencer',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: () => context.go('/scan'),
                icon: const Icon(Icons.upload_file),
                label: const Text('Importer un fichier'),
              ),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => context.go('/scan'),
          icon: const Icon(Icons.upload_file),
          label: const Text('Importer'),
        ),
      );
    }

    // Construction de la liste
    final showSectionHeaders = sections.length > 1;
    final listItems = <Widget>[];

    for (final section in sections) {
      final isCollapsed = _collapsedOwners.contains(section.ownerUid);
      if (showSectionHeaders) {
        listItems.add(
          WorkQueueSectionHeader(
            ownerUid: section.ownerUid,
            count: section.items.length,
            expanded: !isCollapsed,
            onToggle: () => setState(() {
              isCollapsed
                  ? _collapsedOwners.remove(section.ownerUid)
                  : _collapsedOwners.add(section.ownerUid);
            }),
          ),
        );
      }
      if (!isCollapsed) {
        for (final item in section.items) {
          switch (item) {
            case _JobItem(:final job):
              listItems.add(
                QueueJobTile(
                  job: job,
                  isSelected: _selected.contains(item.key),
                  isSelecting: _isSelecting,
                  onTap: () => _isSelecting
                      ? _toggleSelect(item.key)
                      : _handleJobTap(context, job),
                  onLongPress: () => _toggleSelect(item.key),
                  onRetry: () =>
                      ref.read(scanUploadProvider.notifier).retryJob(job),
                  onDelete: () async {
                    final ok = await _showConfirmDialog(
                      title: 'Supprimer ce traitement ?',
                      content: 'Cette action est irréversible.',
                      isDangerous: true,
                    );
                    if (ok && mounted) {
                      await ref
                          .read(processingJobRepositoryProvider)
                          .deleteJob(job.id);
                    }
                  },
                ),
              );
            case _DraftItem(:final recipe):
              listItems.add(
                QueueDraftTile(
                  recipe: recipe,
                  isSelected: _selected.contains(item.key),
                  isSelecting: _isSelecting,
                  onTap: () => _isSelecting
                      ? _toggleSelect(item.key)
                      : context.go('/drafts/${recipe.id}'),
                  onLongPress: () => _toggleSelect(item.key),
                  onValidate: () async {
                    final content = recipe.draftCooklang ?? recipe.rawCooklang;
                    final myUid = ref.read(appUserProvider).value?.uid ?? '';
                    final messenger = ScaffoldMessenger.of(context);
                    await ref
                        .read(recipeRepositoryProvider)
                        .validateDraft(
                          recipeId: recipe.id,
                          editedCooklang: content,
                          titre: recipe.titre,
                          callerUid: myUid,
                          bookId: recipe.bookId,
                          bookTitre: recipe.bookTitre,
                          pageNumberOverride: recipe.pageNumber,
                          tagsOverride: recipe.tags,
                          portionsOverride: recipe.portions,
                          ingredientsOverride: recipe.ingredients,
                        );
                    if (mounted) {
                      messenger.showSnackBar(
                        const SnackBar(content: Text('Brouillon validé !')),
                      );
                    }
                  },
                  onDelete: () async {
                    final ok = await _showConfirmDialog(
                      title: 'Supprimer ce brouillon ?',
                      content: 'Cette action est irréversible.',
                      isDangerous: true,
                    );
                    if (ok && mounted) {
                      await ref
                          .read(recipeRepositoryProvider)
                          .deleteRecipe(recipe.id);
                    }
                  },
                ),
              );
          }
        }
      }
    }

    return Scaffold(
      appBar: appBar,
      body: ListView.separated(
        padding: const EdgeInsets.only(bottom: 80),
        itemCount: listItems.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (_, i) => listItems[i],
      ),
      floatingActionButton: _isSelecting
          ? null
          : FloatingActionButton.extended(
              onPressed: () => context.go('/scan'),
              icon: const Icon(Icons.upload_file),
              label: const Text('Importer'),
            ),
    );
  }

  void _handleJobTap(BuildContext context, ProcessingJob job) {
    if (job.createdRecipeIds.isNotEmpty) {
      // Reste sur le même écran (les brouillons sont déjà visibles ici)
    } else if ((job.createdBookId ?? '').isNotEmpty) {
      context.push('/books/${job.createdBookId}/edit');
    }
  }
}

