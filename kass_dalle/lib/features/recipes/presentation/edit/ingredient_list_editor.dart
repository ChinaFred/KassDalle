import 'package:flutter/material.dart';
import '../../domain/recipe.dart';

const _kSuggestedUnits = <String>[
  // Poids
  'g', 'kg', 'mg',
  // Volume
  'ml', 'cl', 'dl', 'L',
  // Cuisine courante
  'c.à.s.', 'c.à.c.', 'tasse',
  // Divers
  'pincée', 'gousse', 'tranche', 'feuille', 'brin', 'bouquet',
  'pièce', 'filet', 'noix',
];

/// Éditeur structuré d'une liste d'ingrédients.
///
/// Supporte les **catégories** (sections nommées) et le **réordonnancement**
/// par drag & drop (poignée ⠿ avant chaque ligne).
///
/// Internalement la liste est plate : chaque item est soit un en-tête de
/// catégorie ([_CatHeader]) soit une ligne d'ingrédient ([_IngRow]).
/// La catégorie d'un ingrédient est déduite de la position : c'est le dernier
/// [_CatHeader] qui le précède dans la liste (null si aucun).
class IngredientListEditor extends StatefulWidget {
  final List<RecipeIngredient> initialIngredients;
  final bool enabled;
  final ValueChanged<List<RecipeIngredient>> onChanged;

  const IngredientListEditor({
    super.key,
    required this.initialIngredients,
    required this.onChanged,
    this.enabled = true,
  });

  @override
  State<IngredientListEditor> createState() => _IngredientListEditorState();
}

// ── Types discriminés ─────────────────────────────────────────────────────────

abstract class _ListItem {
  /// Clé stable pour l'identité dans le [ReorderableListView].
  final Key itemKey = UniqueKey();
}

class _CatHeader extends _ListItem {
  final TextEditingController name;
  _CatHeader({String text = ''}) : name = TextEditingController(text: text);
  void dispose() => name.dispose();
}

class _IngRow extends _ListItem {
  final TextEditingController name;
  final TextEditingController qty;
  String unit;

  _IngRow({required this.name, required this.qty, required this.unit});

  factory _IngRow.fromIngredient(RecipeIngredient i) => _IngRow(
    name: TextEditingController(text: i.name),
    qty: TextEditingController(text: i.qty),
    unit: i.unit,
  );

  factory _IngRow.empty() => _IngRow(
    name: TextEditingController(),
    qty: TextEditingController(),
    unit: '',
  );

  void dispose() {
    name.dispose();
    qty.dispose();
  }
}

// ── State ─────────────────────────────────────────────────────────────────────

class _IngredientListEditorState extends State<IngredientListEditor> {
  final List<_ListItem> _items = [];

  @override
  void initState() {
    super.initState();
    _buildFrom(widget.initialIngredients);
  }

  void _buildFrom(List<RecipeIngredient> ings) {
    _items.clear();
    if (ings.isEmpty) {
      _items.add(_IngRow.empty());
      return;
    }
    // Collecte les catégories dans l'ordre d'apparition (null = sans catégorie)
    final seen = <String?>{};
    final orderedCats = <String?>[];
    for (final ing in ings) {
      if (seen.add(ing.category)) orderedCats.add(ing.category);
    }
    // Construit la liste plate : ingrédients sans catégorie en tête, puis
    // chaque catégorie nommée précédée de son en-tête.
    for (final cat in orderedCats) {
      if (cat != null && cat.isNotEmpty) {
        _items.add(_CatHeader(text: cat));
      }
      for (final ing in ings.where((i) => i.category == cat)) {
        _items.add(_IngRow.fromIngredient(ing));
      }
    }
  }

  @override
  void dispose() {
    for (final item in _items) {
      if (item is _CatHeader) item.dispose();
      if (item is _IngRow) item.dispose();
    }
    super.dispose();
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  /// Reconstruit la liste plate en [RecipeIngredient] et notifie le parent.
  void _notify() {
    String? currentCat;
    final result = <RecipeIngredient>[];
    for (final item in _items) {
      if (item is _CatHeader) {
        final t = item.name.text.trim();
        currentCat = t.isEmpty ? null : t;
      } else if (item is _IngRow) {
        final n = item.name.text.trim();
        if (n.isNotEmpty) {
          result.add(
            RecipeIngredient(
              name: n,
              qty: item.qty.text.trim(),
              unit: item.unit,
              category: currentCat,
            ),
          );
        }
      }
    }
    widget.onChanged(result);
  }

  /// Callback de [ReorderableListView.onReorderItem] : contrairement à l'ancien
  /// `onReorder`, [newIndex] est déjà ajusté pour l'élément retiré — il ne faut
  /// donc plus le décrémenter soi-même.
  void _onReorder(int oldIndex, int newIndex) {
    setState(() {
      final moved = _items.removeAt(oldIndex);
      _items.insert(newIndex, moved);
    });
    _notify();
  }

  void _removeAt(int index) {
    final item = _items[index];
    if (item is _CatHeader) item.dispose();
    if (item is _IngRow) item.dispose();
    setState(() => _items.removeAt(index));
    _notify();
  }

  /// Ajoute un ingrédient vide juste après [index].
  void _addIngredientAfter(int index) {
    setState(() => _items.insert(index + 1, _IngRow.empty()));
  }

  void _addIngredientAtEnd() {
    setState(() => _items.add(_IngRow.empty()));
  }

  void _addCategory() {
    setState(() {
      _items.add(_CatHeader());
      _items.add(_IngRow.empty());
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Ingrédients',
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 6),
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: _items.length,
          onReorderItem: widget.enabled ? _onReorder : (_, _) {},
          itemBuilder: (context, index) {
            final item = _items[index];
            if (item is _CatHeader) {
              return _CatHeaderTile(
                key: item.itemKey,
                header: item,
                index: index,
                enabled: widget.enabled,
                onNameChanged: _notify,
                onDelete: () => _removeAt(index),
                onAddIngredient: () => _addIngredientAfter(index),
              );
            }
            final row = item as _IngRow;
            return _IngTile(
              key: item.itemKey,
              row: row,
              index: index,
              enabled: widget.enabled,
              onChanged: _notify,
              onRemove: () => _removeAt(index),
            );
          },
        ),
        if (widget.enabled) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              TextButton.icon(
                onPressed: _addIngredientAtEnd,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Ingrédient'),
              ),
              TextButton.icon(
                onPressed: _addCategory,
                icon: const Icon(Icons.label_outline, size: 18),
                label: const Text('Catégorie'),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

// ── En-tête de catégorie ──────────────────────────────────────────────────────

class _CatHeaderTile extends StatelessWidget {
  final _CatHeader header;
  final int index;
  final bool enabled;
  final VoidCallback onNameChanged;
  final VoidCallback onDelete;
  final VoidCallback onAddIngredient;

  const _CatHeaderTile({
    super.key,
    required this.header,
    required this.index,
    required this.enabled,
    required this.onNameChanged,
    required this.onDelete,
    required this.onAddIngredient,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Poignée de déplacement
          ReorderableDragStartListener(
            index: index,
            enabled: enabled,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Icon(
                Icons.drag_handle,
                size: 22,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 6),
          // Champ nom de catégorie
          Expanded(
            child: TextField(
              controller: header.name,
              enabled: enabled,
              onChanged: (_) => onNameChanged(),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              decoration: InputDecoration(
                hintText: 'Nom de la catégorie',
                isDense: true,
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest.withValues(
                  alpha: 0.5,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
              ),
            ),
          ),
          if (enabled) ...[
            IconButton(
              icon: const Icon(Icons.playlist_add, size: 20),
              tooltip: 'Ajouter un ingrédient dans cette catégorie',
              onPressed: onAddIngredient,
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              icon: const Icon(Icons.remove_circle_outline, size: 20),
              tooltip: 'Supprimer la catégorie',
              color: theme.colorScheme.error,
              onPressed: onDelete,
              visualDensity: VisualDensity.compact,
            ),
          ],
        ],
      ),
    );
  }
}

// ── Ligne d'ingrédient ────────────────────────────────────────────────────────

class _IngTile extends StatefulWidget {
  final _IngRow row;
  final int index;
  final bool enabled;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  const _IngTile({
    super.key,
    required this.row,
    required this.index,
    required this.enabled,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  State<_IngTile> createState() => _IngTileState();
}

class _IngTileState extends State<_IngTile> {
  // ── Autocomplete unit ────────────────────────────────────────────────────────
  Widget _unitField(ThemeData theme) {
    final row = widget.row;
    return Autocomplete<String>(
      initialValue: TextEditingValue(text: row.unit),
      optionsBuilder: (value) {
        final q = value.text.toLowerCase();
        if (q.isEmpty) return _kSuggestedUnits;
        return _kSuggestedUnits.where((u) => u.toLowerCase().contains(q));
      },
      onSelected: (v) {
        setState(() => row.unit = v);
        widget.onChanged();
      },
      fieldViewBuilder: (ctx, ctrl, focusNode, onSubmitted) {
        return TextField(
          controller: ctrl,
          focusNode: focusNode,
          enabled: widget.enabled,
          onChanged: (v) {
            row.unit = v;
            widget.onChanged();
          },
          decoration: const InputDecoration(
            hintText: 'Unité',
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          ),
        );
      },
      optionsViewBuilder: (ctx, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200, maxWidth: 160),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (ctx, i) {
                  final opt = options.elementAt(i);
                  return InkWell(
                    onTap: () => onSelected(opt),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      child: Text(opt),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = widget.row;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 480;

        // ── Layout empilé (mobile) ──────────────────────────────────────────
        if (isNarrow) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Poignée
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: ReorderableDragStartListener(
                    index: widget.index,
                    enabled: widget.enabled,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.grab,
                      child: Icon(
                        Icons.drag_handle,
                        size: 22,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Ligne 1 : nom + supprimer
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: row.name,
                              enabled: widget.enabled,
                              onChanged: (_) => widget.onChanged(),
                              decoration: const InputDecoration(
                                hintText: 'Ingrédient',
                                isDense: true,
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 8,
                                ),
                              ),
                            ),
                          ),
                          if (widget.enabled)
                            SizedBox(
                              width: 36,
                              child: IconButton(
                                icon: const Icon(
                                  Icons.remove_circle_outline,
                                  size: 18,
                                ),
                                color: theme.colorScheme.error,
                                padding: EdgeInsets.zero,
                                tooltip: 'Supprimer',
                                onPressed: widget.onRemove,
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // Ligne 2 : quantité + unité
                      Row(
                        children: [
                          SizedBox(
                            width: 80,
                            child: TextField(
                              controller: row.qty,
                              enabled: widget.enabled,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              onChanged: (_) => widget.onChanged(),
                              decoration: const InputDecoration(
                                hintText: 'Qté',
                                isDense: true,
                                border: OutlineInputBorder(),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 8,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(child: _unitField(theme)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }

        // ── Layout horizontal (desktop/tablette) ────────────────────────────
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Poignée de déplacement
              ReorderableDragStartListener(
                index: widget.index,
                enabled: widget.enabled,
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: Icon(
                    Icons.drag_handle,
                    size: 22,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // Nom
              Expanded(
                flex: 4,
                child: TextField(
                  controller: row.name,
                  enabled: widget.enabled,
                  onChanged: (_) => widget.onChanged(),
                  decoration: const InputDecoration(
                    hintText: 'Ingrédient',
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Quantité
              SizedBox(
                width: 68,
                child: TextField(
                  controller: row.qty,
                  enabled: widget.enabled,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (_) => widget.onChanged(),
                  decoration: const InputDecoration(
                    hintText: 'Qté',
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Unité
              SizedBox(width: 112, child: _unitField(theme)),
              // Supprimer
              if (widget.enabled)
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                  color: theme.colorScheme.error,
                  tooltip: 'Supprimer',
                  onPressed: widget.onRemove,
                ),
            ],
          ),
        );
      },
    );
  }
}
