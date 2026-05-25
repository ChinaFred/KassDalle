import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/recipe.dart';
import '../../../books/presentation/book_providers.dart';
import '../../../auth/presentation/auth_providers.dart';

/// Shared metadata form panel used by draft review, recipe edit, and recipe
/// create screens.
///
/// Pass [cuisines]/[onCuisinesChanged] and [dishTypes]/[onDishTypesChanged]
/// to enable the tag editing section (Cuisine + Type de plat).
class RecipeMetaPanel extends ConsumerStatefulWidget {
  final TextEditingController titleCtrl;
  final TextEditingController portionsCtrl;
  final TextEditingController difficultyCtrl;
  final TextEditingController prepTimeCtrl;
  final TextEditingController cookTimeCtrl;
  final TextEditingController pageNumberCtrl;
  final bool saving;
  final String? selectedBookId;
  final void Function(String? id, String? titre) onBookChanged;
  final Recipe? recipe;
  final bool showBookSelector;
  final String? infoBookLabel;
  final List<String>? cuisines;
  final void Function(List<String>)? onCuisinesChanged;
  final List<String>? dishTypes;
  final void Function(List<String>)? onDishTypesChanged;
  final bool suggestingTags;
  final VoidCallback? onSuggestTags;

  /// Si non-null, affiche un sélecteur de type et appelle ce callback à chaque changement.
  final PageType? pageType;
  final void Function(PageType)? onPageTypeChanged;

  const RecipeMetaPanel({
    super.key,
    required this.titleCtrl,
    required this.portionsCtrl,
    required this.difficultyCtrl,
    required this.prepTimeCtrl,
    required this.cookTimeCtrl,
    required this.pageNumberCtrl,
    required this.saving,
    required this.selectedBookId,
    required this.onBookChanged,
    this.recipe,
    this.showBookSelector = true,
    this.infoBookLabel,
    this.cuisines,
    this.onCuisinesChanged,
    this.dishTypes,
    this.onDishTypesChanged,
    this.suggestingTags = false,
    this.onSuggestTags,
    this.pageType,
    this.onPageTypeChanged,
  });

  @override
  ConsumerState<RecipeMetaPanel> createState() => _RecipeMetaPanelState();
}

class _RecipeMetaPanelState extends ConsumerState<RecipeMetaPanel> {
  final _cuisineCtrl = TextEditingController();

  @override
  void dispose() {
    _cuisineCtrl.dispose();
    super.dispose();
  }

  void _addCuisine(String value) {
    final v = value.trim();
    if (v.isEmpty) return;
    final current = List<String>.from(widget.cuisines ?? []);
    if (!current.contains(v)) {
      current.add(v);
      widget.onCuisinesChanged?.call(current);
    }
    _cuisineCtrl.clear();
  }

  void _removeCuisine(String v) {
    final current = List<String>.from(widget.cuisines ?? [])..remove(v);
    widget.onCuisinesChanged?.call(current);
  }

  void _toggleDishType(String v) {
    final current = List<String>.from(widget.dishTypes ?? []);
    if (current.contains(v)) {
      current.remove(v);
    } else {
      current.add(v);
    }
    widget.onDishTypesChanged?.call(current);
  }

  @override
  Widget build(BuildContext context) {
    final booksAsync = ref.watch(myBooksProvider);
    final theme = Theme.of(context);
    final isRecipe = (widget.pageType ?? PageType.recipe) == PageType.recipe;
    final showTags =
        isRecipe &&
        (widget.onCuisinesChanged != null || widget.onDishTypesChanged != null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        if (widget.onPageTypeChanged != null) ..._buildTypeSelector(context),
        TextField(
          controller: widget.titleCtrl,
          enabled: !widget.saving,
          decoration: InputDecoration(
            labelText: (widget.pageType ?? PageType.recipe) != PageType.recipe
                ? 'Titre de la page'
                : 'Titre de la recette',
            prefixIcon: const Icon(Icons.title),
          ),
        ),
        const SizedBox(height: 16),
        if (widget.showBookSelector)
          booksAsync.when(
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
            data: (books) => DropdownButtonFormField<String>(
              decoration: const InputDecoration(
                labelText: 'Livre',
                prefixIcon: Icon(Icons.menu_book_outlined),
              ),
              // ignore: deprecated_member_use
              value: widget.selectedBookId,
              items: [
                const DropdownMenuItem<String>(
                  value: null,
                  child: Text('Aucun livre'),
                ),
                ...books.map(
                  (b) => DropdownMenuItem(value: b.id, child: Text(b.titre)),
                ),
              ],
              onChanged: widget.saving
                  ? null
                  : (val) {
                      final titre = val == null
                          ? null
                          : books.firstWhere((b) => b.id == val).titre;
                      widget.onBookChanged(val, titre);
                    },
            ),
          )
        else if (widget.infoBookLabel != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.auto_awesome,
                  size: 16,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Sera ajoutée dans : ${widget.infoBookLabel}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (widget.showBookSelector) ...[
          const SizedBox(height: 12),
          TextField(
            controller: widget.pageNumberCtrl,
            enabled: !widget.saving,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Page dans le livre',
              prefixIcon: Icon(Icons.bookmark_outline),
            ),
          ),
        ],
        if (isRecipe) ...[
          const SizedBox(height: 16),
          TextField(
            controller: widget.portionsCtrl,
            enabled: !widget.saving,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Portions',
              prefixIcon: Icon(Icons.groups_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: widget.difficultyCtrl,
            enabled: !widget.saving,
            decoration: const InputDecoration(
              labelText: 'Difficulté',
              prefixIcon: Icon(Icons.bolt_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: widget.prepTimeCtrl,
            enabled: !widget.saving,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Temps préparation (min)',
              prefixIcon: Icon(Icons.timer_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: widget.cookTimeCtrl,
            enabled: !widget.saving,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Temps cuisson (min)',
              prefixIcon: Icon(Icons.local_fire_department_outlined),
            ),
          ),
        ],

        if (showTags) ...[
          const SizedBox(height: 20),
          Text('Catégorisation', style: theme.textTheme.labelMedium),
          const SizedBox(height: 8),

          Text(
            'Cuisine',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          if ((widget.cuisines ?? []).isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final c in widget.cuisines!)
                  Chip(
                    label: Text(c, style: const TextStyle(fontSize: 12)),
                    onDeleted: widget.saving ? null : () => _removeCuisine(c),
                    deleteIcon: const Icon(Icons.close, size: 14),
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
              ],
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _cuisineCtrl,
                  enabled: !widget.saving,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Ajouter une cuisine…',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onSubmitted: _addCuisine,
                  textInputAction: TextInputAction.done,
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: const Icon(Icons.add, size: 20),
                visualDensity: VisualDensity.compact,
                onPressed: widget.saving
                    ? null
                    : () => _addCuisine(_cuisineCtrl.text),
                tooltip: 'Ajouter',
              ),
            ],
          ),
          const SizedBox(height: 12),

          Text(
            'Type de plat',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final dt in kDishTypes)
                FilterChip(
                  label: Text(dt, style: const TextStyle(fontSize: 12)),
                  selected: (widget.dishTypes ?? []).contains(dt),
                  onSelected: widget.saving ? null : (_) => _toggleDishType(dt),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  showCheckmark: false,
                ),
            ],
          ),
        ],

        if (widget.recipe != null) ...[
          const SizedBox(height: 24),
          if (widget.recipe!.sourceFileName != null) ...[
            Text('Source', style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.attach_file, size: 16),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.recipe!.sourceFileName!,
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          if (widget.recipe!.aiProcessedAt != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.smart_toy_outlined, size: 16),
                const SizedBox(width: 6),
                Text(
                  'Analysé le ${_fmt(widget.recipe!.aiProcessedAt!)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (ref.watch(isAdminProvider) &&
                widget.recipe!.importVersion != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.build_outlined, size: 16),
                  const SizedBox(width: 6),
                  Text(
                    'Importé avec v${widget.recipe!.importVersion}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ],
      ],
    );
  }

  String _fmt(DateTime dt) =>
      '${dt.day.toString().padLeft(2, "0")}/'
      '${dt.month.toString().padLeft(2, "0")}/'
      '${dt.year}';

  static String _pageTypeLabel(PageType t) => switch (t) {
    PageType.recipe => 'Recette',
    PageType.technique => 'Technique',
    PageType.equipment => 'Matériel',
    PageType.ingredientNote => 'Fiche ingrédients',
    PageType.other => 'Autre document',
  };

  List<Widget> _buildTypeSelector(BuildContext context) {
    return [
      DropdownButtonFormField<PageType>(
        value: widget.pageType ?? PageType.recipe,
        decoration: const InputDecoration(
          labelText: 'Type de page',
          prefixIcon: Icon(Icons.category_outlined),
        ),
        items: PageType.values
            .map(
              (t) => DropdownMenuItem(value: t, child: Text(_pageTypeLabel(t))),
            )
            .toList(),
        onChanged: widget.saving
            ? null
            : (t) {
                if (t != null) widget.onPageTypeChanged?.call(t);
              },
      ),
      const SizedBox(height: 12),
    ];
  }
}
