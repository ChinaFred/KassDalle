import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../domain/recipe.dart';
import '../../../../core/utils/ingredient_categorizer.dart';
import '../../../../core/utils/context_extensions.dart';

// ── Data model ────────────────────────────────────────────────────────────────

class _Item {
  final String name;
  final String qty;
  final String unit;
  final String category;
  final String? source;
  bool checked;

  _Item({
    required this.name,
    required this.qty,
    required this.unit,
    required this.category,
    this.source,
    this.checked = false,
  });

  Map<String, dynamic> toJson() => {
    'n': name,
    'q': qty,
    'u': unit,
    'c': category,
    's': source,
    'x': checked,
  };

  factory _Item.fromJson(Map<String, dynamic> j) => _Item(
    name: j['n'] as String? ?? '',
    qty: j['q'] as String? ?? '',
    unit: j['u'] as String? ?? '',
    category: j['c'] as String? ?? 'Autres',
    source: j['s'] as String?,
    checked: j['x'] as bool? ?? false,
  );

  factory _Item.from(RecipeIngredient ing, String source) => _Item(
    name: ing.name,
    qty: ing.qty,
    unit: ing.unit,
    category: IngredientCategorizer.categorize(ing.name),
    source: source,
  );
}

// ── Helpers ───────────────────────────────────────────────────────────────────

String _todayIso() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')}';
}

String _todayFr() {
  const months = [
    'janvier',
    'février',
    'mars',
    'avril',
    'mai',
    'juin',
    'juillet',
    'août',
    'septembre',
    'octobre',
    'novembre',
    'décembre',
  ];
  final n = DateTime.now();
  return '${n.day} ${months[n.month - 1]} ${n.year}';
}

String _formatItem(String qty, String unit, String name) {
  final showUnit =
      unit.isNotEmpty && !name.toLowerCase().startsWith(unit.toLowerCase());
  return [if (qty.isNotEmpty) qty, if (showUnit) unit, name].join(' ');
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Affiche la feuille de liste de courses pour les ingrédients d'une recette.
///
/// Vérifie si une liste existe déjà aujourd'hui (via SharedPreferences) et
/// propose de la remplacer ou de l'enrichir.
///
/// [ingredientSources] : map optionnelle `{nom_ingrédient → "Recette A · B"}`.
/// Si fournie, chaque item affiche sa provenance en sous-titre (non inclus
/// dans le copier-coller vers Keep).
Future<void> showShoppingListSheet(
  BuildContext context,
  List<RecipeIngredient> ingredients,
  String recipeTitre,
  String uid, {
  Map<String, String>? ingredientSources,
}) async {
  if (ingredients.isEmpty) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Aucun ingrédient à ajouter')));
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final dateKey = 'sl_date_$uid';
  final itemsKey = 'sl_items_$uid';
  final today = _todayIso();
  final storedDate = prefs.getString(dateKey);

  final newItems = ingredients
      .map((i) => _Item.from(i, ingredientSources?[i.name] ?? recipeTitre))
      .toList();
  List<_Item> itemsToShow;

  if (storedDate == today) {
    final stored = prefs.getString(itemsKey);
    final existing = stored != null
        ? (json.decode(stored) as List)
              .map((e) => _Item.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList()
        : <_Item>[];

    if (existing.isNotEmpty && context.mounted) {
      final choice = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.shopping_cart_outlined),
          title: const Text('Liste du jour existante'),
          content: Text(
            'Vous avez déjà une liste de courses pour aujourd\'hui '
            '(${existing.length} article${existing.length > 1 ? 's' : ''}).\n\n'
            'Remplacer supprime la liste actuelle. '
            'Enrichir ajoute les nouveaux ingrédients à la liste existante.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annuler'),
            ),
            OutlinedButton(
              onPressed: () => Navigator.pop(ctx, 'replace'),
              child: const Text('Remplacer'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, 'merge'),
              child: const Text('Enrichir'),
            ),
          ],
        ),
      );
      if (choice == null || !context.mounted) return;
      if (choice == 'replace') {
        itemsToShow = newItems;
      } else {
        final existingNames = existing.map((i) => i.name.toLowerCase()).toSet();
        itemsToShow = [
          ...existing,
          ...newItems.where(
            (i) => !existingNames.contains(i.name.toLowerCase()),
          ),
        ];
      }
    } else {
      itemsToShow = newItems;
    }
  } else {
    itemsToShow = newItems;
  }

  // Persist the current list
  await prefs.setString(dateKey, today);
  await prefs.setString(
    itemsKey,
    json.encode(itemsToShow.map((i) => i.toJson()).toList()),
  );

  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _ShoppingListSheet(
      items: itemsToShow,
      prefs: prefs,
      itemsKey: itemsKey,
    ),
  );
}

// ── Sheet widget ──────────────────────────────────────────────────────────────

class _ShoppingListSheet extends StatefulWidget {
  final List<_Item> items;
  final SharedPreferences prefs;
  final String itemsKey;

  const _ShoppingListSheet({
    required this.items,
    required this.prefs,
    required this.itemsKey,
  });

  @override
  State<_ShoppingListSheet> createState() => _ShoppingListSheetState();
}

class _ShoppingListSheetState extends State<_ShoppingListSheet> {
  late final List<_Item> _items;
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    _items = List.of(widget.items);
  }

  void _toggle(int index) {
    setState(() => _items[index].checked = !_items[index].checked);
    widget.prefs.setString(
      widget.itemsKey,
      json.encode(_items.map((i) => i.toJson()).toList()),
    );
  }

  String _buildKeepText() {
    final title = "Liste de courses Kass'Dalle – ${_todayFr()}";
    final buffer = StringBuffer();
    buffer.writeln(title);

    // Group by category order
    final grouped = <String, List<_Item>>{};
    for (final item in _items) {
      (grouped[item.category] ??= []).add(item);
    }
    final orderedKeys = [
      ...IngredientCategorizer.categoryOrder.where(grouped.containsKey),
      ...grouped.keys.where(
        (k) => !IngredientCategorizer.categoryOrder.contains(k),
      ),
    ];

    for (final cat in orderedKeys) {
      buffer.writeln(cat.toUpperCase());
      for (final item in grouped[cat]!) {
        buffer.writeln('\t${_formatItem(item.qty, item.unit, item.name)}');
      }
    }
    return buffer.toString().trim();
  }

  Future<void> _openKeep() async {
    setState(() => _opening = true);
    try {
      await Clipboard.setData(ClipboardData(text: _buildKeepText()));
      final uri = Uri.parse('https://keep.google.com/');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      if (mounted) {
        context.showSnackBar('Liste copiée ! Dans Keep : créez une nouvelle note et collez (appui long).');
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = _items.where((i) => !i.checked).length;

    // Group for display
    final grouped = <String, List<(int, _Item)>>{};
    for (int i = 0; i < _items.length; i++) {
      (grouped[_items[i].category] ??= []).add((i, _items[i]));
    }
    final orderedKeys = [
      ...IngredientCategorizer.categoryOrder.where(grouped.containsKey),
      ...grouped.keys.where(
        (k) => !IngredientCategorizer.categoryOrder.contains(k),
      ),
    ];

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollCtrl) {
        return Column(
          children: [
            // ── Handle bar ─────────────────────────────────────────────────
            const SizedBox(height: 12),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 12),

            // ── Header ─────────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.shopping_cart_outlined,
                      size: 20,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Liste de courses Kass'Dalle",
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          _todayFr(),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: remaining == 0
                          ? theme.colorScheme.tertiaryContainer
                          : theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '$remaining / ${_items.length}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: remaining == 0
                            ? theme.colorScheme.onTertiaryContainer
                            : theme.colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),
            const Divider(),

            // ── Checklist ──────────────────────────────────────────────────
            Expanded(
              child: ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 100),
                children: [
                  for (final cat in orderedKeys) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                      child: Text(
                        cat.toUpperCase(),
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.1,
                        ),
                      ),
                    ),
                    for (final (idx, item) in grouped[cat]!)
                      CheckboxListTile(
                        value: item.checked,
                        onChanged: (_) => _toggle(idx),
                        title: Text(
                          _formatItem(item.qty, item.unit, item.name),
                          style: item.checked
                              ? TextStyle(
                                  decoration: TextDecoration.lineThrough,
                                  color: theme.colorScheme.onSurface
                                      .withValues(alpha: 0.4),
                                )
                              : null,
                        ),
                        subtitle: item.source != null
                            ? Text(
                                item.source!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              )
                            : null,
                        controlAffinity: ListTileControlAffinity.leading,
                        dense: true,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                  ],
                ],
              ),
            ),

            // ── Action bar ─────────────────────────────────────────────────
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FilledButton.icon(
                      onPressed: _opening ? null : _openKeep,
                      icon: _opening
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.open_in_new, size: 18),
                      label: const Text('Envoyer vers Google Keep'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(double.infinity, 48),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'La liste sera copiée dans votre presse-papier. '
                      'Dans Keep : nouvelle note → coller (appui long).',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
