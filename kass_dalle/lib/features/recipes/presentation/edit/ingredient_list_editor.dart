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
/// Chaque ligne = nom | quantité (numérique) | unité (autocomplete).
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

class _IngredientListEditorState extends State<IngredientListEditor> {
  late List<_IngRow> _rows;

  @override
  void initState() {
    super.initState();
    _rows = widget.initialIngredients.map(_IngRow.fromIngredient).toList();
    if (_rows.isEmpty) _rows.add(_IngRow.empty());
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _addRow() {
    setState(() => _rows.add(_IngRow.empty()));
  }

  void _removeRow(int index) {
    _rows[index].dispose();
    setState(() => _rows.removeAt(index));
    _notify();
  }

  void _notify() {
    widget.onChanged(
      _rows
          .where((r) => r.name.text.trim().isNotEmpty)
          .map(
            (r) => RecipeIngredient(
              name: r.name.text.trim(),
              qty: r.qty.text.trim(),
              unit: r.unit,
            ),
          )
          .toList(),
    );
  }

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
        // En-têtes des colonnes
        Padding(
          padding: const EdgeInsets.only(left: 4, right: 40),
          child: Row(
            children: [
              Expanded(
                flex: 4,
                child: Text('Nom', style: theme.textTheme.labelSmall),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 68,
                child: Text('Qté', style: theme.textTheme.labelSmall),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 112,
                child: Text('Unité', style: theme.textTheme.labelSmall),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        ..._rows.asMap().entries.map(
          (e) => _IngredientRow(
            key: ValueKey(e.key),
            row: e.value,
            enabled: widget.enabled,
            onChanged: _notify,
            onRemove: () => _removeRow(e.key),
          ),
        ),
        const SizedBox(height: 4),
        if (widget.enabled)
          TextButton.icon(
            onPressed: _addRow,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Ajouter un ingrédient'),
          ),
      ],
    );
  }
}

// ── Donnée d'une ligne ────────────────────────────────────────────────────────

class _IngRow {
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

// ── Widget d'une ligne ────────────────────────────────────────────────────────

class _IngredientRow extends StatefulWidget {
  final _IngRow row;
  final bool enabled;
  final VoidCallback onChanged;
  final VoidCallback onRemove;

  const _IngredientRow({
    super.key,
    required this.row,
    required this.enabled,
    required this.onChanged,
    required this.onRemove,
  });

  @override
  State<_IngredientRow> createState() => _IngredientRowState();
}

class _IngredientRowState extends State<_IngredientRow> {
  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
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
          // Unité (autocomplete)
          SizedBox(
            width: 112,
            child: Autocomplete<String>(
              initialValue: TextEditingValue(text: row.unit),
              optionsBuilder: (value) {
                final q = value.text.toLowerCase();
                if (q.isEmpty) return _kSuggestedUnits;
                return _kSuggestedUnits.where(
                  (u) => u.toLowerCase().contains(q),
                );
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
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
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
                      constraints: const BoxConstraints(
                        maxHeight: 200,
                        maxWidth: 160,
                      ),
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
            ),
          ),
          // Supprimer
          IconButton(
            icon: const Icon(Icons.remove_circle_outline, size: 20),
            color: Theme.of(context).colorScheme.error,
            tooltip: 'Supprimer',
            onPressed: widget.enabled ? widget.onRemove : null,
          ),
        ],
      ),
    );
  }
}
