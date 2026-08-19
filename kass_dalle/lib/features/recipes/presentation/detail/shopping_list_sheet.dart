import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../domain/recipe.dart';
import '../../../../core/utils/ingredient_categorizer.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/utils/ingredient_display.dart';
import '../../../../core/services/error_reporting.dart';
import '../../services/google_tasks_service.dart';
import '../../../../core/theme/app_icon_size.dart';

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

  factory _Item.fromProduct(RecipeShoppingProduct p, String source) => _Item(
    name: p.name,
    qty: p.qty,
    unit: p.unit,
    category: IngredientCategorizer.categorize(p.name),
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

/// Une ligne de liste de courses, accordée comme le reste de l'application.
///
/// Même règle que la fiche et que le PDF : « 3 cuillères à soupe de sauce
/// soja », « 2 carottes ». Une liste qu'on lit dans un magasin mérite autant
/// de soin qu'une recette qu'on imprime.
String _formatItem(String qty, String unit, String name) =>
    formatIngredientDisplay(qty: qty, unit: unit, name: name);

String _mergeQty(
  String existingQty,
  String newQty,
  String existingUnit,
  String newUnit,
) {
  final sameUnit =
      existingUnit.toLowerCase() == newUnit.toLowerCase() ||
      existingUnit.isEmpty ||
      newUnit.isEmpty;
  if (sameUnit) {
    final existingValue = double.tryParse(
      existingQty.replaceAll(',', '.').trim(),
    );
    final newValue = double.tryParse(newQty.replaceAll(',', '.').trim());
    if (existingValue != null && newValue != null) {
      final total = existingValue + newValue;
      return total == total.truncateToDouble()
          ? total.toInt().toString()
          : total.toStringAsFixed(1);
    }
  }
  if (existingQty.isEmpty) return newQty;
  if (newQty.isEmpty) return existingQty;
  return '$existingQty + $newQty';
}

String _normItemKey(String name, String unit) {
  String normalize(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[àâ]'), 'a')
        .replaceAll(RegExp(r'[éèêë]'), 'e')
        .replaceAll(RegExp(r'[îï]'), 'i')
        .replaceAll(RegExp(r'[ôö]'), 'o')
        .replaceAll(RegExp(r'[ùûü]'), 'u')
        .replaceAll('ç', 'c')
        .replaceAll('æ', 'ae')
        .replaceAll('œ', 'oe')
        .replaceAll('\u2019', "'")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  final normalizedName = normalize(name)
      .split(' ')
      .map(
        (word) => word.endsWith('s') && word.length > 2
            ? word.substring(0, word.length - 1)
            : word,
      )
      .join(' ');
  return '${normalize(unit)}|$normalizedName';
}

String? _mergeSources(String? left, String? right) {
  final values = <String>{};
  for (final source in [left, right]) {
    if (source == null || source.trim().isEmpty) continue;
    for (final part in source.split(' · ')) {
      final trimmed = part.trim();
      if (trimmed.isNotEmpty) values.add(trimmed);
    }
  }
  if (values.isEmpty) return null;
  return values.join(' · ');
}

List<_Item> _buildItems(
  List<RecipeShoppingProduct> products,
  List<RecipeIngredient> fallbackIngredients,
  String recipeTitre, {
  Map<String, String>? ingredientSources,
}) {
  if (products.isNotEmpty) {
    return products
        .map((p) => _Item.fromProduct(p, recipeTitre))
        .toList(growable: false);
  }
  return fallbackIngredients
      .map(
        (ing) => _Item.from(ing, ingredientSources?[ing.name] ?? recipeTitre),
      )
      .toList(growable: false);
}

List<_Item> _mergeShoppingItems(List<_Item> existing, List<_Item> incoming) {
  final merged = <_Item>[];
  final indexByKey = <String, int>{};

  for (final item in [...existing, ...incoming]) {
    final key = _normItemKey(item.name, item.unit);
    final existingIndex = indexByKey[key];
    if (existingIndex == null) {
      indexByKey[key] = merged.length;
      merged.add(
        _Item(
          name: item.name,
          qty: item.qty,
          unit: item.unit,
          category: item.category,
          source: item.source,
          checked: item.checked,
        ),
      );
      continue;
    }

    final current = merged[existingIndex];
    merged[existingIndex] = _Item(
      name: current.name,
      qty: _mergeQty(current.qty, item.qty, current.unit, item.unit),
      unit: current.unit.isNotEmpty ? current.unit : item.unit,
      category: current.category,
      source: _mergeSources(current.source, item.source),
      checked: current.checked && item.checked,
    );
  }

  return merged;
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Affiche la feuille de liste de courses.
///
/// [products] : produits pré-calculés par Gemini et scalés en mémoire.
///   Si vide, [fallbackIngredients] est utilisé à la place.
/// [fallbackIngredients] : ingrédients bruts de la recette (utilisés si
///   les produits ne sont pas encore disponibles).
/// [ingredientSources] : map optionnelle `{nom_ingrédient → "Recette A · B"}`
///   pour l'affichage de provenance (planning).
Future<void> showShoppingListSheet(
  BuildContext context,
  List<RecipeShoppingProduct> products,
  List<RecipeIngredient> fallbackIngredients,
  String recipeTitre,
  String uid, {
  Map<String, String>? ingredientSources,
}) async {
  if (products.isEmpty && fallbackIngredients.isEmpty) {
    context.showSnackBar('Aucun ingrédient à ajouter');
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final dateKey = 'sl_date_$uid';
  final itemsKey = 'sl_items_$uid';
  final today = _todayIso();
  final storedDate = prefs.getString(dateKey);

  final newItems = _buildItems(
    products,
    fallbackIngredients,
    recipeTitre,
    ingredientSources: ingredientSources,
  );

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
            'Enrichir ajoute les nouveaux produits à la liste existante.',
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
      itemsToShow = choice == 'merge'
          ? _mergeShoppingItems(existing, newItems)
          : newItems;
    } else {
      itemsToShow = newItems;
    }
  } else {
    itemsToShow = newItems;
  }

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
  bool _sendingTasks = false;

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

  /// L'adresse des tâches Google.
  ///
  /// Sur mobile, l'application Tasks capte ce lien si elle est installée ;
  /// sinon le navigateur ouvre la version web. Il n'existe pas d'URL stable
  /// vers une liste précise — l'identifiant rendu par l'API n'est pas celui de
  /// l'interface —, donc on ouvre les tâches, où la liste du jour se trouve en
  /// tête du sélecteur.
  static final _tasksUrl = Uri.parse('https://tasks.google.com/');

  Future<void> _openTasks() async {
    try {
      await launchUrl(_tasksUrl, mode: LaunchMode.externalApplication);
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'shoppingList.openTasks',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Envoie la liste vers Google Tasks : rayons en tâches, articles en
  /// sous-tâches, tout cochable.
  ///
  /// Seuls les articles **non cochés** partent : ce qui est déjà dans le
  /// panier n'a rien à faire sur une liste de courses.
  Future<void> _sendToTasks() async {
    final groups = <({String category, List<String> items})>[];
    final grouped = <String, List<_Item>>{};
    for (final item in _items) {
      if (item.checked) continue;
      (grouped[item.category] ??= []).add(item);
    }
    if (grouped.isEmpty) {
      context.showSnackBar('Tout est déjà coché : rien à envoyer.');
      return;
    }

    final orderedKeys = [
      ...IngredientCategorizer.categoryOrder.where(grouped.containsKey),
      ...grouped.keys.where(
        (k) => !IngredientCategorizer.categoryOrder.contains(k),
      ),
    ];
    for (final key in orderedKeys) {
      groups.add((
        category: key,
        items: grouped[key]!
            .map((i) => _formatItem(i.qty, i.unit, i.name))
            .toList(growable: false),
      ));
    }

    setState(() => _sendingTasks = true);
    try {
      final count = await GoogleTasksService.createShoppingList(
        title: "Courses Kass'Dalle – ${_todayFr()}",
        groups: groups,
      );
      if (!mounted) return;
      // L'onglet s'ouvre tout seul — c'est là qu'on va ensuite. Le bouton du
      // bandeau reste néanmoins : un navigateur peut bloquer une ouverture qui
      // ne suit pas immédiatement un geste, et après une trentaine d'appels
      // réseau, le lien n'est plus considéré comme déclenché par vous.
      await _openTasks();
      if (!mounted) return;
      context.showSuccessSnackBar(
        '$count article${count > 1 ? 's' : ''} envoyé'
        '${count > 1 ? 's' : ''} dans Google Tasks.',
        action: SnackBarAction(label: 'Ouvrir', onPressed: _openTasks),
      );
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'shoppingList.sendToTasks',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      context.showErrorSnackBar('Envoi impossible : $error');
    } finally {
      if (mounted) setState(() => _sendingTasks = false);
    }
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
        context.showSnackBar(
          'Liste copiée ! Dans Keep : créez une nouvelle note et collez (appui long).',
        );
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
                      size: AppIconSize.small,
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
                                  color: theme.colorScheme.onSurface.withValues(
                                    alpha: 0.4,
                                  ),
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
                      onPressed: _sendingTasks ? null : _sendToTasks,
                      icon: _sendingTasks
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(
                              Icons.checklist_outlined,
                              size: AppIconSize.small,
                            ),
                      label: const Text('Envoyer vers Google Tasks'),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(double.infinity, 48),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Une liste cochable, un rayon par tâche et un article '
                      'par sous-tâche. Rien à convertir à la main.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 10),
                    OutlinedButton.icon(
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
                          : const Icon(
                              Icons.open_in_new,
                              size: AppIconSize.small,
                            ),
                      label: const Text('Copier pour Google Keep'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 44),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Keep n\'a pas d\'API : la liste est copiée, à vous de '
                      'créer la note, de la convertir en cases à cocher et de refaire '
                      'les rayons.',
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
