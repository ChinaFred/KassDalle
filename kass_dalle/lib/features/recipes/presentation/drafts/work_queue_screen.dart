import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'assign_book_sheet.dart';
import 'work_queue_batch.dart';
import 'work_queue_widgets.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../books/presentation/book_providers.dart';
import '../../../processing/domain/processing_job.dart';
import '../../../processing/presentation/processing_providers.dart';
import '../recipe_providers.dart';
import '../../domain/draft_title_twins.dart';
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

  /// Jobs « Doublon possible » dont la reprise est en cours d'écriture.
  final Set<String> _resuming = {};

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
  /// Seules les lignes sélectionnables comptent : [items] est déjà filtré.
  void _toggleSection(Iterable<_QueueItem> items) => setState(() {
    final keys = items.map((i) => i.key).toList();
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
    // créé un brouillon, sinon la panne disparaît de l'écran avec lui. Un
    // doublon possible aussi : sur une page à plusieurs recettes, les autres
    // sont déjà des brouillons, et la décision sur celles qui restent ne se
    // prend que sur la ligne du job.
    bool hasProducedDraft(ProcessingJob j) => j.createdRecipeIds.isNotEmpty;

    bool isVisible(ProcessingJob j) =>
        ((j.status == ProcessingJobStatus.queued ||
                j.status == ProcessingJobStatus.processing) &&
            !hasProducedDraft(j)) ||
        j.status == ProcessingJobStatus.error ||
        j.status == ProcessingJobStatus.rejected ||
        j.status == ProcessingJobStatus.duplicate;

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
  /// Les brouillons sans contenu restent toujours de côté (voir
  /// [planDraftValidation]) : il n'y a rien à publier. La réserve de fidélité
  /// diffère selon le geste : sur une ligne seule (`confirm: false`), elle
  /// reste de côté — direction l'écran de relecture, où le bandeau la montre.
  /// En lot (`confirm: true`), le dialogue avertit et le brouillon est
  /// validé quand même si l'utilisateur confirme : personne ne va relire
  /// cinquante brouillons un par un pour lever un doute que l'import a déjà
  /// signalé, et laisser la réserve bloquer chaque lot revenait à imposer
  /// cette relecture par défaut.
  ///
  /// Un brouillon marqué « Doublon possible » reste de côté dans les deux
  /// gestes, sauf si sa référence a disparu entre-temps : la marque est
  /// relue juste avant (voir [staleDuplicateMarks]).
  Future<void> _validateDrafts(
    List<Recipe> drafts, {
    required bool confirm,
  }) async {
    if (_busy) return;
    final staleDuplicates = await _staleDuplicates(drafts);
    if (!mounted) return;
    setState(() => _progress = null);
    final plan = planDraftValidation(drafts, staleDuplicates: staleDuplicates);
    final reserveIncluded = confirm && plan.withFidelityReserve.isNotEmpty;
    final toValidate = reserveIncluded
        ? [...plan.toValidate, ...plan.withFidelityReserve]
        : plan.toValidate;
    if (toValidate.isEmpty) {
      _report(
        validationSummary(plan, reserveIncluded: reserveIncluded, failed: 0),
        failed: 0,
        partial: true,
      );
      return;
    }
    if (confirm) {
      final note = notValidatedNote(plan, reserveIncluded: reserveIncluded);
      final reserveCount = plan.withFidelityReserve.length;
      final count = toValidate.length;
      final ok = await _showConfirmDialog(
        title: 'Valider ${countOf(count, 'brouillon', 'brouillons')} ?',
        content:
            '${count >= 2 ? 'Ils seront publiés tels quels' : 'Il sera publié tel quel'}'
            ', sans relecture.'
            '${reserveIncluded ? '\n\nDont $reserveCount avec réserve de fidélité '
                      '(l\'IA a un doute sur la fidélité de la copie) : validé${reserveCount >= 2 ? 's' : ''} '
                      'quand même, sans relecture individuelle.' : ''}'
            '${note == null ? '' : '\n\n$note'}',
        confirmLabel: 'Valider',
      );
      if (!ok || !mounted) return;
    }
    final repo = ref.read(recipeRepositoryProvider);
    final myUid = ref.read(appUserProvider).value?.uid ?? '';
    final failed = await _runBatch<Recipe>(
      label: 'Validation',
      items: toValidate,
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
      validationSummary(
        plan,
        reserveIncluded: reserveIncluded,
        failed: failed.length,
      ),
      failed: failed.length,
      partial: plan.emptyContent.isNotEmpty || plan.duplicates.isNotEmpty,
    );
  }

  /// Range des brouillons dans un livre, sans les valider. Le livre se choisit
  /// dans une feuille ; les brouillons restent des brouillons.
  Future<void> _assignBook(List<Recipe> drafts) async {
    if (_busy || drafts.isEmpty) return;
    final booksAsync = ref.read(targetBooksProvider);
    if (booksAsync.hasError) {
      context.showErrorSnackBar('Les livres n\'ont pas pu être lus.');
      return;
    }
    final books = booksAsync.value;
    if (books == null) {
      _report('Chargement des livres en cours.', failed: 0, partial: true);
      return;
    }
    if (books.isEmpty) {
      _report('Créez d\'abord un livre.', failed: 0, partial: true);
      return;
    }
    final book = await showAssignBookSheet(
      context,
      books: books,
      drafts: drafts,
    );
    if (book == null || !mounted) return;
    final repo = ref.read(recipeRepositoryProvider);
    final failed = await _runBatch<Recipe>(
      label: 'Rangement',
      items: drafts,
      feature: 'workQueueScreen.assignBook',
      errorContext: (r) => {'recipe_id': r.id, 'book_id': book.id},
      action: (r) => repo.assignBookToDraft(
        recipeId: r.id,
        bookId: book.id,
        bookTitre: book.titre,
      ),
    );
    _report(
      bookAssignmentSummary(
        done: drafts.length,
        failed: failed.length,
        bookTitre: book.titre,
      ),
      failed: failed.length,
    );
  }

  /// Les brouillons marqués dont la référence n'existe plus. Ne lit rien
  /// quand aucun brouillon de [drafts] n'est marqué.
  ///
  /// L'écran passe en mode occupé dès l'entrée, barre de progression
  /// « Vérification des doublons n/N » affichée : un second appui sur
  /// « Valider » pendant la relecture lancerait un second lot. L'appelant
  /// retire la barre.
  Future<Set<String>> _staleDuplicates(List<Recipe> drafts) {
    final marked = drafts.where((d) => d.duplicateOf != null).toList();
    if (marked.isEmpty) return Future.value(const <String>{});
    const label = 'Vérification des doublons';
    setState(() => _progress = _BatchProgress(label, 0, marked.length));
    final recipeRepo = ref.read(recipeRepositoryProvider);
    final jobRepo = ref.read(processingJobRepositoryProvider);
    return staleDuplicateMarks(
      marked,
      readRecipe: recipeRepo.getById,
      readJob: jobRepo.getJob,
      onProgress: (done, total) {
        if (mounted) {
          setState(() => _progress = _BatchProgress(label, done, total));
        }
      },
      onReadError: (error, stackTrace, draft) {
        // La recette ou l'import d'un autre membre est refusé par les
        // règles : attendu, la marque reste, rien à signaler.
        if (error is FirebaseException && error.code == 'permission-denied') {
          return;
        }
        reportUnexpectedError(
          feature: 'workQueueScreen.checkDuplicateMark',
          error: error,
          stackTrace: stackTrace,
          context: {
            'recipe_id': draft.id,
            'duplicate_recipe_id': draft.duplicateOf?.recipeId,
            'duplicate_job_id': draft.duplicateOf?.jobId,
          },
        );
      },
    );
  }

  /// « Ce n'est pas un doublon » : le job reprend au balisage, sans nouvelle
  /// détection, pour les seules recettes retenues.
  ///
  /// Un job en cours de reprise ne se reprend pas une seconde fois : le
  /// bouton est désactivé tant que l'écriture n'est pas revenue.
  Future<void> _resumeDuplicate(ProcessingJob job) async {
    if (!_resuming.add(job.id)) return;
    setState(() {});
    try {
      await ref.read(scanUploadProvider.notifier).resumeDuplicateJob(job);
      if (mounted) {
        context.showSuccessSnackBar(
          'Traitement repris : le brouillon arrivera dans la file.',
        );
      }
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'workQueueScreen.resumeDuplicateJob',
        error: error,
        stackTrace: stackTrace,
        jobId: job.id,
      );
      if (mounted) {
        context.showErrorSnackBar('La reprise du traitement a échoué.');
      }
    } finally {
      _resuming.remove(job.id);
      if (mounted) setState(() {});
    }
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
    // L'import lance des appels d'IA facturés : réservé aux éditeurs, et les
    // règles refusent le `processing_job` d'un lecteur.
    final canImport = ref.watch(canEditProvider);
    // Tant que le rôle n'est pas lu, `canImport` vaut faux : un éditeur verrait
    // la file sans bouton d'import. On attend le rôle comme on attend la file.
    final roleLoading = ref.watch(appUserProvider).isLoading;
    final adminUidFilter = ref.watch(adminJobUserFilterProvider);

    final myJobsAsync = ref.watch(processingJobsProvider);
    final myDraftsAsync = ref.watch(draftsProvider);
    final familyDraftsAsync = ref.watch(groupMemberDraftsProvider);
    final allJobsAsync = isAdmin ? ref.watch(allProcessingJobsProvider) : null;
    final allDraftsAsync = isAdmin ? ref.watch(allDraftsProvider) : null;

    if (myJobsAsync.isLoading || myDraftsAsync.isLoading || roleLoading) {
      return const Scaffold(
        body: AppLoadingState(label: 'Chargement des brouillons et imports…'),
      );
    }

    final myJobs = myJobsAsync.value ?? [];
    final myDrafts = myDraftsAsync.value ?? [];
    final familyDrafts = familyDraftsAsync.value ?? [];
    final allJobs = allJobsAsync?.value ?? [];
    final allDrafts = allDraftsAsync?.value ?? [];

    // Un brouillon ne se valide, ne se supprime et ne se sélectionne que par
    // son créateur ou un administrateur (`firestore.rules`). Celui d'un autre
    // membre s'affiche, et sa ligne ouvre la relecture.
    final me = ref.watch(appUserProvider).value;
    bool canAct(_QueueItem item) => switch (item) {
      _DraftItem(:final recipe) =>
        me?.canModifyRecipe(recipe.createdBy) ?? false,
      _JobItem() => true,
    };

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
        if (!isCollapsed(s)) ...s.items.where(canAct),
    ];
    final selectedItems = visibleItems
        .where((i) => _selected.contains(i.key))
        .toList();
    final selectedDrafts = selectedItems.whereType<_DraftItem>().toList();
    final selectedJobs = selectedItems.whereType<_JobItem>().toList();
    final retryableJobs = selectedJobs
        .where(
          (i) =>
              (i.job.status == ProcessingJobStatus.error ||
                  i.job.status == ProcessingJobStatus.rejected) &&
              // Un import par lien ne se relance que si son échec le permet
              // (règles Firestore : délai dépassé ou incident, deux fois).
              (urlImportFailureFor(i.job)?.retryable ?? true) &&
              // Propriétaire qui n'est plus éditeur : le serveur refuserait
              // de nouveau (`owner_not_editor`).
              !i.job.ownerNotEditor,
        )
        .map((i) => i.job)
        .toList();
    final selecting = _selectionMode && allItems.isNotEmpty;

    // Brouillons de même titre dans un même livre : le serveur ne marque que
    // le plus récent, la file rapproche les deux à l'affichage.
    final twins = draftTitleTwins([
      for (final i in allItems)
        if (i case _DraftItem(:final recipe)) recipe,
    ]);

    // Ce qui attend une décision de l'utilisateur : ses traitements arrêtés
    // en doublon possible — seul leur auteur peut les reprendre — et les
    // brouillons marqués qu'il peut valider ou supprimer. Ceux d'un autre
    // membre ne comptent pas, y compris pour un administrateur qui voit tous
    // les traitements.
    final pendingDuplicates = allItems
        .where(canAct)
        .where(
          (i) => switch (i) {
            _JobItem(:final job) => job.isDuplicate && job.createdBy == me?.uid,
            _DraftItem(:final recipe) => recipe.duplicateOf != null,
          },
        )
        .length;
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
              if (allItems.any(canAct))
                IconButton(
                  icon: const Icon(Icons.checklist),
                  tooltip: 'Sélectionner',
                  onPressed: _busy ? null : _startSelection,
                ),
              if (canImport)
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
            // Réserve de fidélité comprise : un lot avertit plutôt que de
            // l'exclure, voir `_validateDrafts`. Le compte affiché doit donc
            // annoncer ce qui sera réellement validé après confirmation.
            validateCount: selectedDrafts.isEmpty
                ? null
                : planDraftValidation(
                    selectedDrafts.map((d) => d.recipe),
                  ).validatableInBatch,
            // Les marques « Doublon possible » ne sont relues qu'à l'appui :
            // avant, le nombre à valider n'est pas connu.
            showValidateCount: !selectedDrafts.any(
              (d) => d.recipe.duplicateOf != null,
            ),
            retryCount: (retryableJobs.isEmpty || !canImport)
                ? null
                : retryableJobs.length,
            deleteCount: selectedItems.length,
            assignBookCount: selectedDrafts.isEmpty
                ? null
                : selectedDrafts.length,
            onAssignBook: () =>
                _assignBook(selectedDrafts.map((d) => d.recipe).toList()),
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
                  // Un lecteur n'importe pas : on lui dit d'où viennent les
                  // brouillons, et où voir ceux de sa famille.
                  message: canImport
                      ? 'Importez un scan pour commencer.'
                      : 'Les brouillons naissent d\'un import, réservé aux '
                            'éditeurs. Ceux de votre famille s\'affichent en '
                            'choisissant « Groupe familial » dans le filtre en '
                            'haut de l\'écran.',
                  action: canImport
                      ? FilledButton.icon(
                          onPressed: () => context.go('/scan'),
                          icon: const Icon(Icons.upload_file),
                          label: const Text('Importer un fichier'),
                        )
                      : null,
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: bottomBar,
        floatingActionButton: canImport
            ? FloatingActionButton.extended(
                onPressed: () => context.go('/scan'),
                icon: const Icon(Icons.upload_file),
                label: const Text('Importer'),
              )
            : null,
      );
    }

    // Construction de la liste
    final listItems = <Widget>[];

    final duplicatesLabel = pendingDuplicatesLabel(pendingDuplicates);
    if (duplicatesLabel != null) {
      listItems.add(WorkQueueDuplicatesCounter(label: duplicatesLabel));
    }

    for (final section in sections) {
      final collapsed = isCollapsed(section);
      if (showSectionHeaders) {
        final actionable = section.items.where(canAct).toList();
        final checked = actionable
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
                : (checked == actionable.length ? true : null),
            onToggleSelection: selecting && !collapsed && actionable.isNotEmpty
                ? () => _toggleSection(actionable)
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
                  onRetry: canImport
                      ? () =>
                            ref.read(scanUploadProvider.notifier).retryJob(job)
                      : null,
                  onCancel: () =>
                      ref.read(scanUploadProvider.notifier).cancelJob(job.id),
                  onDelete: () => _deleteItems([item]),
                  // Réservée au propriétaire éditeur. Les règles l'admettent
                  // aussi pour l'administrateur ; l'écran ne la lui propose
                  // pas sur le job d'un autre.
                  onNotDuplicate: canImport && job.createdBy == me?.uid
                      ? () => _resumeDuplicate(job)
                      : null,
                  notDuplicateBusy: _resuming.contains(job.id),
                ),
              );
            case _DraftItem(:final recipe):
              final mine = canAct(item);
              listItems.add(
                QueueDraftTile(
                  recipe: recipe,
                  twins: twins[recipe.id],
                  isSelected: mine && _selected.contains(item.key),
                  isSelecting: selecting,
                  onTap: () => selecting && mine
                      ? _toggleSelect(item.key)
                      : context.go('/drafts/${recipe.id}'),
                  onLongPress: mine ? () => _toggleSelect(item.key) : null,
                  onValidate: mine
                      ? () => _validateDrafts([recipe], confirm: false)
                      : null,
                  onDelete: mine ? () => _deleteItems([item]) : null,
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
      floatingActionButton: (selecting || _busy || !canImport)
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
