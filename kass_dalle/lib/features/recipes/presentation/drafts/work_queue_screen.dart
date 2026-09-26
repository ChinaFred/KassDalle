import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'work_queue_batch.dart';
import 'work_queue_widgets.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../processing/domain/processing_job.dart';
import '../../../processing/presentation/processing_providers.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';
import '../../../../core/services/error_reporting.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/widgets/app_states.dart';

// ── Modèle unifié ──────────────────────────────────────────────────────────────

sealed class _QueueItem {
  String get key;
  String get ownerId;

  /// Date du scan. La file se lit dans l'ordre où les pages ont été scannées :
  /// la plus ancienne en haut. `updatedAt` ne convient pas, elle avance à
  /// chaque enrichissement du pipeline et à chaque retouche.
  DateTime get scannedAt;
}

final class _JobItem extends _QueueItem {
  final ProcessingJob job;
  _JobItem(this.job);
  @override
  String get key => 'j:${job.id}';
  @override
  String get ownerId => job.createdBy;
  @override
  DateTime get scannedAt => job.createdAt;
}

final class _DraftItem extends _QueueItem {
  final Recipe recipe;
  _DraftItem(this.recipe);
  @override
  String get key => 'd:${recipe.id}';
  @override
  String get ownerId => recipe.createdBy;
  @override
  DateTime get scannedAt => recipe.createdAt;
}

// ── Section par propriétaire ──────────────────────────────────────────────────

class _Section {
  final String ownerUid; // '__me' pour l'utilisateur courant
  final List<_QueueItem> items;
  _Section({required this.ownerUid, required this.items});
}

/// Avancement d'une action en lot, affiché en bas de l'écran.
class _BatchProgress {
  final String label;
  final int done;
  final int total;
  const _BatchProgress(this.label, this.done, this.total);
}

// ── Screen ────────────────────────────────────────────────────────────────────

class WorkQueueScreen extends ConsumerStatefulWidget {
  const WorkQueueScreen({super.key});

  @override
  ConsumerState<WorkQueueScreen> createState() => _WorkQueueScreenState();
}

class _WorkQueueScreenState extends ConsumerState<WorkQueueScreen> {
  WorkQueueFilter _filterMode = WorkQueueFilter.me;

  /// Le mode sélection s'ouvre par le bouton « Sélectionner » de la barre du
  /// haut ou par un appui long sur une ligne. Il se ferme par la croix, après
  /// une action, ou quand on décoche le dernier élément.
  bool _selectionMode = false;
  final Set<String> _selected = {};
  final Set<String> _collapsedOwners = {};
  _BatchProgress? _progress;

  bool get _busy => _progress != null;

  void _resetSelection() {
    _selectionMode = false;
    _selected.clear();
  }

  void _startSelection() => setState(() => _selectionMode = true);

  void _clearSelection() => setState(_resetSelection);

  void _toggleSelect(String key) {
    if (_busy) return;
    setState(() {
      _selectionMode = true;
      if (!_selected.remove(key)) _selected.add(key);
      if (_selected.isEmpty) _selectionMode = false;
    });
  }

  void _selectAll(Iterable<_QueueItem> items) =>
      setState(() => _selected.addAll(items.map((i) => i.key)));

  /// Coche toute la section, ou la décoche si elle l'est déjà entièrement.
  void _toggleSection(_Section section) => setState(() {
    final keys = section.items.map((i) => i.key).toList();
    if (keys.every(_selected.contains)) {
      _selected.removeAll(keys);
    } else {
      _selected.addAll(keys);
    }
    if (_selected.isEmpty) _selectionMode = false;
  });

  /// Une section repliée cache ses lignes : elles sortent de la sélection, pour
  /// qu'une action ne touche jamais ce qui n'est pas à l'écran.
  void _toggleCollapse(_Section section) => setState(() {
    if (!_collapsedOwners.remove(section.ownerUid)) {
      _collapsedOwners.add(section.ownerUid);
      _selected.removeAll(section.items.map((i) => i.key));
      if (_selected.isEmpty) _selectionMode = false;
    }
  });

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
    // Un job qui a déjà produit un brouillon n'a plus à occuper la file : le
    // brouillon le représente, et c'est lui qu'on ouvre. La pipeline continue
    // ensuite d'enrichir en arrière-plan pendant plusieurs minutes — afficher
    // les deux lignes donnait à un seul import l'apparence de deux travaux.
    //
    // Les échecs font exception : un job en erreur reste visible même s'il a
    // créé un brouillon, sinon la panne disparaît de l'écran avec lui.
    bool hasProducedDraft(ProcessingJob j) => j.createdRecipeIds.isNotEmpty;

    bool isVisible(ProcessingJob j) =>
        ((j.status == ProcessingJobStatus.queued ||
                j.status == ProcessingJobStatus.processing) &&
            !hasProducedDraft(j)) ||
        j.status == ProcessingJobStatus.error ||
        j.status == ProcessingJobStatus.rejected;

    switch (_filterMode) {
      case WorkQueueFilter.me:
        final items = [
          ...myJobs.where(isVisible).map(_JobItem.new),
          ...myDrafts.map(_DraftItem.new),
        ];
        items.sort((a, b) => a.scannedAt.compareTo(b.scannedAt));
        return [_Section(ownerUid: '__me', items: items)];

      case WorkQueueFilter.family:
        final myItems = [
          ...myJobs.where(isVisible).map(_JobItem.new),
          ...myDrafts.map(_DraftItem.new),
        ];
        myItems.sort((a, b) => a.scannedAt.compareTo(b.scannedAt));
        final byOwner = <String, List<_QueueItem>>{};
        for (final r in familyDrafts) {
          (byOwner[r.createdBy] ??= []).add(_DraftItem(r));
        }
        for (final items in byOwner.values) {
          items.sort((a, b) => a.scannedAt.compareTo(b.scannedAt));
        }
        return [
          _Section(ownerUid: '__me', items: myItems),
          ...byOwner.entries.map(
            (e) => _Section(ownerUid: e.key, items: e.value),
          ),
        ];

      case WorkQueueFilter.allUsers:
        final activeJobs = allJobs
            .where(isVisible)
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
          items.sort((a, b) => a.scannedAt.compareTo(b.scannedAt));
        }
        final sections = byOwner.entries
            .map((e) => _Section(ownerUid: e.key, items: e.value))
            .toList();
        sections.sort(
          (a, b) => a.items.first.scannedAt.compareTo(b.items.first.scannedAt),
        );
        return sections;
    }
  }

  // ── Actions groupées ───────────────────────────────────────────────────────

  /// Exécute [action] sur chaque élément, l'un après l'autre, en affichant
  /// l'avancement. Un élément qui échoue est signalé (`reportUnexpectedError`)
  /// et n'arrête pas les suivants : une écriture refusée au milieu d'un lot de
  /// trente ne doit pas laisser vingt-neuf éléments dans l'état d'avant.
  ///
  /// Les dépôts sont lus par l'appelant avant l'appel : `ref` ne sert plus une
  /// fois l'écran quitté, et le lot doit aller à son terme même si
  /// l'utilisateur change d'onglet.
  ///
  /// Retourne les éléments en échec.
  Future<List<T>> _runBatch<T>({
    required String label,
    required List<T> items,
    required Future<void> Function(T item) action,
    required String feature,
    required Map<String, dynamic> Function(T item) errorContext,
  }) async {
    final failed = <T>[];
    setState(() {
      _resetSelection();
      _progress = _BatchProgress(label, 0, items.length);
    });
    for (var i = 0; i < items.length; i++) {
      try {
        await action(items[i]);
      } catch (error, stackTrace) {
        failed.add(items[i]);
        reportUnexpectedError(
          feature: feature,
          error: error,
          stackTrace: stackTrace,
          context: errorContext(items[i]),
        );
      }
      if (mounted) {
        setState(() => _progress = _BatchProgress(label, i + 1, items.length));
      }
    }
    if (mounted) setState(() => _progress = null);
    return failed;
  }

  /// Le compte rendu d'un lot : succès s'il n'y a rien à redire, erreur s'il y
  /// a des échecs, message neutre et plus long quand des éléments sont restés
  /// de côté.
  void _report(String message, {required int failed, bool partial = false}) {
    if (!mounted) return;
    if (failed > 0) {
      context.showErrorSnackBar(message);
    } else if (partial) {
      context.showSnackBar(message, duration: const Duration(seconds: 6));
    } else {
      context.showSuccessSnackBar(message);
    }
  }

  /// Valide des brouillons sans les ouvrir. Sert à la fois la sélection
  /// multiple et l'action « Valider » d'une ligne.
  ///
  /// Les brouillons à réserve de fidélité et les brouillons vides restent de
  /// côté (voir [planDraftValidation]).
  Future<void> _validateDrafts(
    List<Recipe> drafts, {
    required bool confirm,
  }) async {
    if (_busy) return;
    final plan = planDraftValidation(drafts);
    if (plan.toValidate.isEmpty) {
      _report(validationSummary(plan, failed: 0), failed: 0, partial: true);
      return;
    }
    if (confirm) {
      final note = notValidatedNote(plan);
      final count = plan.toValidate.length;
      final ok = await _showConfirmDialog(
        title: 'Valider ${countOf(count, 'brouillon', 'brouillons')} ?',
        content:
            '${count >= 2 ? 'Ils seront publiés tels quels' : 'Il sera publié tel quel'}'
            ', sans relecture.'
            '${note == null ? '' : '\n\n$note'}',
        confirmLabel: 'Valider',
      );
      if (!ok || !mounted) return;
    }
    final repo = ref.read(recipeRepositoryProvider);
    final myUid = ref.read(appUserProvider).value?.uid ?? '';
    final failed = await _runBatch<Recipe>(
      label: 'Validation',
      items: plan.toValidate,
      feature: 'workQueueScreen.validateDraft',
      errorContext: (r) => {'recipe_id': r.id},
      action: (r) => repo.validateDraft(
        recipeId: r.id,
        editedCooklang: draftContent(r),
        titre: r.titre,
        callerUid: myUid,
        bookId: r.bookId,
        bookTitre: r.bookTitre,
        pageNumberOverride: r.pageNumber,
        tagsOverride: r.tags,
        portionsOverride: r.portions,
        ingredientsOverride: r.ingredients,
      ),
    );
    _report(
      validationSummary(plan, failed: failed.length),
      failed: failed.length,
      partial: plan.skipped > 0,
    );
  }

  /// Relance des traitements en erreur ou rejetés. Chaque import relancé est
  /// facturé à nouveau : la sélection multiple demande donc confirmation.
  Future<void> _retryJobs(List<ProcessingJob> jobs) async {
    if (_busy || jobs.isEmpty) return;
    final ok = await _showConfirmDialog(
      title: 'Relancer ${countOf(jobs.length, 'traitement', 'traitements')} ?',
      content: 'Chaque import relancé est facturé à nouveau.',
      confirmLabel: 'Relancer',
    );
    if (!ok || !mounted) return;
    final notifier = ref.read(scanUploadProvider.notifier);
    final failed = await _runBatch<ProcessingJob>(
      label: 'Relance',
      items: jobs,
      feature: 'workQueueScreen.retryJob',
      errorContext: (j) => {'job_id': j.id},
      action: notifier.retryJob,
    );
    _report(
      actionSummary(
        verb: 'Relancé',
        drafts: 0,
        jobs: jobs.length - failed.length,
        failed: failed.length,
      ),
      failed: failed.length,
    );
  }

  Future<void> _deleteItems(List<_QueueItem> items) async {
    if (_busy || items.isEmpty) return;
    final label = selectionLabel(
      drafts: items.whereType<_DraftItem>().length,
      jobs: items.whereType<_JobItem>().length,
    );
    final ok = await _showConfirmDialog(
      title: 'Supprimer $label ?',
      content: 'Cette action est irréversible.',
      isDangerous: true,
      confirmLabel: 'Supprimer',
    );
    if (!ok || !mounted) return;
    final jobRepo = ref.read(processingJobRepositoryProvider);
    final recipeRepo = ref.read(recipeRepositoryProvider);
    final failed = await _runBatch<_QueueItem>(
      label: 'Suppression',
      items: items,
      feature: 'workQueueScreen.deleteItem',
      errorContext: (i) => {'item': i.key},
      action: (i) => switch (i) {
        _JobItem(:final job) => jobRepo.deleteJob(job.id),
        _DraftItem(:final recipe) => recipeRepo.deleteRecipe(recipe.id),
      },
    );
    final failedDrafts = failed.whereType<_DraftItem>().length;
    final failedJobs = failed.whereType<_JobItem>().length;
    _report(
      actionSummary(
        verb: 'Supprimé',
        drafts: items.whereType<_DraftItem>().length - failedDrafts,
        jobs: items.whereType<_JobItem>().length - failedJobs,
        failed: failed.length,
      ),
      failed: failed.length,
    );
  }

  Future<bool> _showConfirmDialog({
    required String title,
    required String content,
    bool isDangerous = false,
    String confirmLabel = 'Confirmer',
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
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  /// Recharge la file — brouillons personnels, familiaux et jobs en cours.
  /// Un seul chemin, partagé par la liste garnie et par l'état vide.
  Future<void> _refreshQueue() async {
    ref.invalidate(processingJobsProvider);
    ref.invalidate(draftsProvider);
    ref.invalidate(groupMemberDraftsProvider);
    await ref.read(draftsProvider.future);
  }

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

    // Les en-têtes n'existent qu'à partir de deux sections. Sans en-tête, rien
    // ne permet de rouvrir une section : un repli gardé d'un autre filtre ne
    // doit donc pas cacher la seule liste.
    final showSectionHeaders = sections.length > 1;
    bool isCollapsed(_Section s) =>
        showSectionHeaders && _collapsedOwners.contains(s.ownerUid);

    // Ce qui est à l'écran, et seulement cela, est sélectionnable. Une clé
    // cochée dont la ligne a disparu (validée ou supprimée ailleurs, section
    // repliée) ne compte pas et n'est jamais traitée.
    final visibleItems = [
      for (final s in sections)
        if (!isCollapsed(s)) ...s.items,
    ];
    final selectedItems = visibleItems
        .where((i) => _selected.contains(i.key))
        .toList();
    final selectedDrafts = selectedItems.whereType<_DraftItem>().toList();
    final selectedJobs = selectedItems.whereType<_JobItem>().toList();
    final retryableJobs = selectedJobs
        .where(
          (i) =>
              i.job.status == ProcessingJobStatus.error ||
              i.job.status == ProcessingJobStatus.rejected,
        )
        .map((i) => i.job)
        .toList();
    final selecting = _selectionMode && allItems.isNotEmpty;
    final allSelected =
        visibleItems.isNotEmpty &&
        visibleItems.every((i) => _selected.contains(i.key));

    // La file s'est vidée pendant la sélection : le mode ne doit pas rester
    // armé et resurgir à l'arrivée du prochain import.
    if (_selectionMode && allItems.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _clearSelection();
      });
    }

    // AppBar dynamique
    final appBar = selecting
        ? AppBar(
            leading: IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Annuler la sélection',
              onPressed: _clearSelection,
            ),
            title: Text(
              selectedItems.isEmpty
                  ? 'Sélectionnez des éléments'
                  : '${selectedItems.length} sélectionné(s)',
            ),
            actions: [
              IconButton(
                icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
                tooltip: allSelected
                    ? 'Tout désélectionner'
                    : 'Tout sélectionner',
                onPressed: allSelected
                    ? _clearSelection
                    : () => _selectAll(visibleItems),
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
              if (allItems.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.checklist),
                  tooltip: 'Sélectionner',
                  onPressed: _busy ? null : _startSelection,
                ),
              IconButton(
                icon: const Icon(Icons.upload_file),
                tooltip: 'Importer un scan',
                onPressed: () => context.go('/scan'),
              ),
              const SizedBox(width: 8),
            ],
          );

    // Pendant un lot, la barre du bas montre l'avancement ; sinon, les actions
    // de la sélection quand elle n'est pas vide.
    final progress = _progress;
    final Widget? bottomBar = progress != null
        ? WorkQueueProgressBar(
            label: progress.label,
            done: progress.done,
            total: progress.total,
          )
        : (selecting && selectedItems.isNotEmpty)
        ? WorkQueueSelectionBar(
            validateCount: selectedDrafts.isEmpty
                ? null
                : planDraftValidation(
                    selectedDrafts.map((d) => d.recipe),
                  ).toValidate.length,
            retryCount: retryableJobs.isEmpty ? null : retryableJobs.length,
            deleteCount: selectedItems.length,
            onValidate: () => _validateDrafts(
              selectedDrafts.map((d) => d.recipe).toList(),
              confirm: true,
            ),
            onRetry: () => _retryJobs(retryableJobs),
            onDelete: () => _deleteItems(selectedItems),
          )
        : null;

    if (allItems.isEmpty) {
      return Scaffold(
        appBar: appBar,
        // La file vide est justement le moment où l'on veut tirer pour
        // rafraîchir : on attend qu'un import arrive. Un `Center` n'est pas
        // défilable, donc pas tirable — d'où la liste d'un seul élément.
        body: RefreshIndicator(
          onRefresh: _refreshQueue,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              SizedBox(
                height: MediaQuery.sizeOf(context).height * 0.7,
                child: AppEmptyState(
                  icon: Icons.edit_note_outlined,
                  title: 'Aucun élément',
                  message: 'Importez un scan pour commencer.',
                  action: FilledButton.icon(
                    onPressed: () => context.go('/scan'),
                    icon: const Icon(Icons.upload_file),
                    label: const Text('Importer un fichier'),
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: bottomBar,
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => context.go('/scan'),
          icon: const Icon(Icons.upload_file),
          label: const Text('Importer'),
        ),
      );
    }

    // Construction de la liste
    final listItems = <Widget>[];

    for (final section in sections) {
      final collapsed = isCollapsed(section);
      if (showSectionHeaders) {
        final checked = section.items
            .where((i) => _selected.contains(i.key))
            .length;
        listItems.add(
          WorkQueueSectionHeader(
            ownerUid: section.ownerUid,
            count: section.items.length,
            expanded: !collapsed,
            onToggle: () => _toggleCollapse(section),
            selection: checked == 0
                ? false
                : (checked == section.items.length ? true : null),
            onToggleSelection:
                selecting && !collapsed && section.items.isNotEmpty
                ? () => _toggleSection(section)
                : null,
          ),
        );
      }
      if (!collapsed) {
        for (final item in section.items) {
          switch (item) {
            case _JobItem(:final job):
              listItems.add(
                QueueJobTile(
                  job: job,
                  isAdmin: isAdmin,
                  isSelected: _selected.contains(item.key),
                  isSelecting: selecting,
                  onTap: () => selecting
                      ? _toggleSelect(item.key)
                      : _handleJobTap(context, job),
                  onLongPress: () => _toggleSelect(item.key),
                  onRetry: () =>
                      ref.read(scanUploadProvider.notifier).retryJob(job),
                  onCancel: () =>
                      ref.read(scanUploadProvider.notifier).cancelJob(job.id),
                  onDelete: () => _deleteItems([item]),
                ),
              );
            case _DraftItem(:final recipe):
              listItems.add(
                QueueDraftTile(
                  recipe: recipe,
                  isSelected: _selected.contains(item.key),
                  isSelecting: selecting,
                  onTap: () => selecting
                      ? _toggleSelect(item.key)
                      : context.go('/drafts/${recipe.id}'),
                  onLongPress: () => _toggleSelect(item.key),
                  onValidate: () => _validateDrafts([recipe], confirm: false),
                  onDelete: () => _deleteItems([item]),
                ),
              );
          }
        }
      }
    }

    return Scaffold(
      appBar: appBar,
      body: RefreshIndicator(
        onRefresh: _refreshQueue,
        child: ListView.separated(
          padding: const EdgeInsets.only(bottom: 80),
          // Une liste courte doit rester tirable : sans ça, le geste de
          // rafraîchissement ne se déclenche pas quand il n'y a rien à faire
          // défiler — le cas où l'on a justement envie de vérifier.
          physics: const AlwaysScrollableScrollPhysics(),
          itemCount: listItems.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (_, i) => listItems[i],
        ),
      ),
      bottomNavigationBar: bottomBar,
      floatingActionButton: (selecting || _busy)
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
