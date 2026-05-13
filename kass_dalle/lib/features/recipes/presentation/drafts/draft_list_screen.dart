import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../processing/presentation/processing_providers.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';

class DraftListScreen extends ConsumerStatefulWidget {
  const DraftListScreen({super.key});

  @override
  ConsumerState<DraftListScreen> createState() => _DraftListScreenState();
}

class _DraftListScreenState extends ConsumerState<DraftListScreen> {
  bool _showFamilyDrafts = false;
  final Set<String> _collapsedMembers = {};
  final Set<String> _selected = {};

  bool get _isSelecting => _selected.isNotEmpty;

  void _toggleSelect(String id) => setState(() {
    _selected.contains(id) ? _selected.remove(id) : _selected.add(id);
  });

  void _clearSelection() => setState(() => _selected.clear());

  void _selectAll() {
    final drafts = ref.read(draftsProvider).value ?? [];
    setState(() => _selected.addAll(drafts.map((r) => r.id)));
  }

  Future<void> _batchDelete() async {
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer les brouillons ?'),
        content: Text(
          '$count brouillon(s) vont être supprimés définitivement.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ids = Set<String>.from(_selected);
    _clearSelection();
    final repo = ref.read(recipeRepositoryProvider);
    for (final id in ids) {
      await repo.deleteRecipe(id);
    }
  }

  Future<void> _batchValidate() async {
    final count = _selected.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Valider les brouillons ?'),
        content: Text('$count brouillon(s) vont être publiés.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Valider'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ids = Set<String>.from(_selected);
    _clearSelection();
    final repo = ref.read(recipeRepositoryProvider);
    final myUid = ref.read(appUserProvider).value?.uid ?? '';
    final recipes = (ref.read(draftsProvider).value ?? []).where(
      (r) => ids.contains(r.id),
    );
    int done = 0;
    for (final recipe in recipes) {
      final content = recipe.draftCooklang ?? recipe.rawCooklang;
      await repo.validateDraft(
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
      done++;
    }
    if (mounted && done > 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$done brouillon(s) validé(s) !')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final draftsAsync = ref.watch(draftsProvider);
    final familyDraftsAsync = ref.watch(groupMemberDraftsProvider);
    final activeJobsCount = ref.watch(activeProcessingJobsCountProvider);

    final myDrafts = draftsAsync.value ?? const [];
    final allSelected =
        myDrafts.isNotEmpty && _selected.length == myDrafts.length;

    // Brouillons des membres groupés par propriétaire
    final familyDraftsByOwner = <String, List<Recipe>>{};
    if (_showFamilyDrafts) {
      for (final r in familyDraftsAsync.value ?? []) {
        (familyDraftsByOwner[r.createdBy] ??= []).add(r);
      }
    }

    final hasFamilyDrafts = (familyDraftsAsync.value ?? []).isNotEmpty;

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
                  icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
                  tooltip: allSelected
                      ? 'Tout désélectionner'
                      : 'Tout sélectionner',
                  onPressed: allSelected ? _clearSelection : _selectAll,
                ),
                IconButton(
                  icon: const Icon(Icons.check_circle_outline),
                  tooltip: 'Valider la sélection',
                  onPressed: _batchValidate,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: 'Supprimer la sélection',
                  onPressed: _batchDelete,
                ),
              ],
            )
          : AppBar(
              title: const Text('Brouillons'),
              actions: [
                if (activeJobsCount > 0)
                  IconButton(
                    icon: Badge(
                      label: Text('$activeJobsCount'),
                      child: const Icon(Icons.hourglass_top_outlined),
                    ),
                    tooltip: 'Etat des traitements',
                    onPressed: () => context.go('/processing'),
                  ),
                IconButton(
                  icon: Icon(
                    Icons.group_outlined,
                    color: _showFamilyDrafts
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                  tooltip: _showFamilyDrafts
                      ? 'Masquer les brouillons de la famille'
                      : 'Voir les brouillons de la famille',
                  onPressed: () =>
                      setState(() => _showFamilyDrafts = !_showFamilyDrafts),
                ),
                IconButton(
                  icon: const Icon(Icons.upload_file),
                  tooltip: 'Importer un scan',
                  onPressed: () => context.go('/scan'),
                ),
              ],
            ),
      body: Column(
        children: [
          if (!_isSelecting && activeJobsCount > 0)
            MaterialBanner(
              content: Text(
                '$activeJobsCount traitement(s) IA en cours. Vous pouvez continuer a editer vos brouillons.',
              ),
              leading: const Icon(Icons.hourglass_top_outlined),
              actions: [
                TextButton(
                  onPressed: () => context.go('/processing'),
                  child: const Text('Voir'),
                ),
              ],
            ),
          Expanded(
            child: draftsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('Erreur : $e')),
              data: (myDrafts) {
                final empty = myDrafts.isEmpty && familyDraftsByOwner.isEmpty;

                if (empty && !_showFamilyDrafts) {
                  return Center(
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
                          'Aucun brouillon',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Importez un scan pour commencer',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
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
                  );
                }

                return ListView(
                  padding: const EdgeInsets.only(bottom: 80),
                  children: [
                    // ── Mes brouillons ──────────────────────────────────────
                    if (myDrafts.isNotEmpty) ...[
                      _SectionHeader(
                        title: 'Mes brouillons',
                        count: myDrafts.length,
                        expanded: !_collapsedMembers.contains('__me'),
                        onToggle: () => setState(
                          () => _collapsedMembers.contains('__me')
                              ? _collapsedMembers.remove('__me')
                              : _collapsedMembers.add('__me'),
                        ),
                      ),
                      if (!_collapsedMembers.contains('__me'))
                        ...myDrafts.map(
                          (r) => _DraftTile(
                            recipe: r,
                            isSelected: _selected.contains(r.id),
                            isSelecting: _isSelecting,
                            onTap: () => _isSelecting
                                ? _toggleSelect(r.id)
                                : context.go('/drafts/${r.id}'),
                            onLongPress: () => _toggleSelect(r.id),
                          ),
                        ),
                    ] else if (!_showFamilyDrafts || !hasFamilyDrafts)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text('Aucun brouillon personnel'),
                      ),

                    // ── Brouillons famille ──────────────────────────────────
                    if (_showFamilyDrafts) ...[
                      if (familyDraftsAsync.isLoading)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else if (!hasFamilyDrafts)
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Text(
                            'Aucun brouillon dans votre groupe familial.',
                            style: TextStyle(fontStyle: FontStyle.italic),
                          ),
                        )
                      else
                        for (final entry in familyDraftsByOwner.entries) ...[
                          _MemberSectionHeader(
                            ownerUid: entry.key,
                            count: entry.value.length,
                            expanded: !_collapsedMembers.contains(entry.key),
                            onToggle: () => setState(
                              () => _collapsedMembers.contains(entry.key)
                                  ? _collapsedMembers.remove(entry.key)
                                  : _collapsedMembers.add(entry.key),
                            ),
                          ),
                          if (!_collapsedMembers.contains(entry.key))
                            ...entry.value.map((r) => _DraftTile(recipe: r)),
                        ],
                    ],
                  ],
                );
              },
            ),
          ),
        ],
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
}

// ── Section header ─────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;

  const _SectionHeader({
    required this.title,
    required this.count,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Row(
          children: [
            Text(
              title,
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

class _MemberSectionHeader extends ConsumerWidget {
  final String ownerUid;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;

  const _MemberSectionHeader({
    required this.ownerUid,
    required this.count,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name =
        ref.watch(userByUidProvider(ownerUid)).value?.displayName ?? '…';
    return _SectionHeader(
      title: 'Brouillons de $name',
      count: count,
      expanded: expanded,
      onToggle: onToggle,
    );
  }
}

class _DraftTile extends StatelessWidget {
  final Recipe recipe;
  final bool isSelected;
  final bool isSelecting;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const _DraftTile({
    required this.recipe,
    this.isSelected = false,
    this.isSelecting = false,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasSource = recipe.sourceFileName != null;

    return ListTile(
      selected: isSelected,
      selectedTileColor: theme.colorScheme.primaryContainer.withOpacity(0.3),
      leading: isSelecting
          ? Checkbox(value: isSelected, onChanged: (_) => onLongPress?.call())
          : CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(
                Icons.edit_document,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
      title: Text(recipe.titre),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasSource)
            Text(
              recipe.sourceFileName!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          if (recipe.bookTitre != null)
            Row(
              children: [
                Icon(
                  Icons.menu_book,
                  size: 12,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  recipe.bookTitre!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
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
                _StatusChip(status: recipe.reviewStatus),
                const SizedBox(width: 8),
                Text(
                  _formatDate(recipe.updatedAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
      onTap: onTap ?? () => context.go('/drafts/${recipe.id}'),
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

class _StatusChip extends StatelessWidget {
  final ReviewStatus status;
  const _StatusChip({required this.status});

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
