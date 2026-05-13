import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../auth/presentation/auth_providers.dart';
import '../../../../core/utils/web_download.dart';
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

// ── Mode de filtre ────────────────────────────────────────────────────────────

enum _FilterMode { me, family, allUsers }

// ── Screen ────────────────────────────────────────────────────────────────────

class WorkQueueScreen extends ConsumerStatefulWidget {
  const WorkQueueScreen({super.key});

  @override
  ConsumerState<WorkQueueScreen> createState() => _WorkQueueScreenState();
}

class _WorkQueueScreenState extends ConsumerState<WorkQueueScreen> {
  _FilterMode _filterMode = _FilterMode.me;
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
      case _FilterMode.me:
        final items = [
          ...myJobs.where(isActive).map(_JobItem.new),
          ...myDrafts.map(_DraftItem.new),
        ];
        items.sort((a, b) => b.sortDate.compareTo(a.sortDate));
        return [_Section(ownerUid: '__me', items: items)];

      case _FilterMode.family:
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

      case _FilterMode.allUsers:
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
    if (_filterMode == _FilterMode.allUsers && !isAdmin) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => setState(() => _filterMode = _FilterMode.me),
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
              _FilterDropdown(
                isAdmin: isAdmin,
                filterMode: _filterMode,
                onChanged: (mode) => setState(() => _filterMode = mode),
              ),
              if (isAdmin && _filterMode == _FilterMode.allUsers)
                _AdminUidFilter(allJobs: allJobs, allDrafts: allDrafts),
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
          _OwnerSectionHeader(
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
                _QueueJobTile(
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
                _QueueDraftTile(
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
                      ScaffoldMessenger.of(context).showSnackBar(
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

// ── Filtre dropdown ────────────────────────────────────────────────────────────

class _FilterDropdown extends StatelessWidget {
  final bool isAdmin;
  final _FilterMode filterMode;
  final ValueChanged<_FilterMode> onChanged;

  const _FilterDropdown({
    required this.isAdmin,
    required this.filterMode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final options = [
      (_FilterMode.me, 'Mes éléments'),
      (_FilterMode.family, 'Groupe familial'),
      if (isAdmin) (_FilterMode.allUsers, 'Tous les utilisateurs'),
    ];
    return DropdownButtonHideUnderline(
      child: DropdownButton<_FilterMode>(
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

class _AdminUidFilter extends ConsumerWidget {
  final List<ProcessingJob> allJobs;
  final List<Recipe> allDrafts;

  const _AdminUidFilter({required this.allJobs, required this.allDrafts});

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

class _OwnerSectionHeader extends ConsumerWidget {
  final String ownerUid;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;

  const _OwnerSectionHeader({
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

class _QueueJobTile extends StatelessWidget {
  final ProcessingJob job;
  final bool isSelected;
  final bool isSelecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onRetry;
  final VoidCallback onDelete;

  const _QueueJobTile({
    required this.job,
    required this.isSelected,
    required this.isSelecting,
    required this.onTap,
    required this.onLongPress,
    required this.onRetry,
    required this.onDelete,
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
      selectedTileColor: theme.colorScheme.primaryContainer.withOpacity(0.3),
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
              job.currentStep!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.secondary,
                fontStyle: FontStyle.italic,
              ),
            ),
          if (hasError) _ErrorBadge(errorMessage: job.errorMessage!),
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
                    if (action == _JobMenuAction.viewSource) {
                      final uri = Uri.parse(job.fileUrl);
                      if (!await launchUrl(uri, mode: LaunchMode.platformDefault) && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Impossible d\'ouvrir le document.')),
                        );
                      }
                    }
                    if (action == _JobMenuAction.downloadSource) {
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

enum _JobMenuAction { retry, delete, viewSource, downloadSource }

// ── Tuile brouillon ───────────────────────────────────────────────────────────

class _QueueDraftTile extends StatelessWidget {
  final Recipe recipe;
  final bool isSelected;
  final bool isSelecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onValidate;
  final VoidCallback onDelete;

  const _QueueDraftTile({
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
      selectedTileColor: theme.colorScheme.primaryContainer.withOpacity(0.3),
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
                        recipe.sourceFileUrl!.isNotEmpty) ...
                      [
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
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Copié dans le presse-papier')),
              );
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
