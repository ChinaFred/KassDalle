import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../domain/recipe.dart';
import '../../../../core/utils/ingredient_categorizer.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/utils/ingredient_display.dart';
import '../../../../core/utils/shopping_products.dart';
import '../../../../core/services/error_reporting.dart';
import '../../services/google_tasks_service.dart';
import '../../../../core/theme/app_icon_size.dart';

// ── Data model ────────────────────────────────────────────────────────────────

/// Une quantité d'une ligne de courses : une famille d'unité, un total.
typedef _Qty = ({String qty, String unit});

class _Item {
  final String name;

  /// Une entrée par famille d'unité : « 400 ml » et « 250 g » sur la même
  /// ligne quand les deux ne se convertissent pas l'une dans l'autre. On
  /// achète le lait de coco une fois, même si une recette le compte en
  /// grammes et l'autre en millilitres.
  final List<_Qty> quantities;
  final String category;
  final String? source;
  bool checked;

  _Item({
    required this.name,
    required this.quantities,
    required this.category,
    this.source,
    this.checked = false,
  });

  Map<String, dynamic> toJson() => {
    'n': name,
    'qs': [
      for (final q in quantities) {'q': q.qty, 'u': q.unit},
    ],
    'c': category,
    's': source,
    'x': checked,
  };

  /// Lit une ligne enregistrée. Une liste d'avant ce format porte `q` et `u`
  /// à plat : une quantité unique.
  factory _Item.fromJson(Map<String, dynamic> j) {
    final raw = j['qs'];
    final quantities = raw is List
        ? <_Qty>[
            for (final e in raw)
              if (e is Map)
                (qty: e['q'] as String? ?? '', unit: e['u'] as String? ?? ''),
          ]
        : <_Qty>[(qty: j['q'] as String? ?? '', unit: j['u'] as String? ?? '')];
    return _Item(
      name: j['n'] as String? ?? '',
      quantities: quantities,
      category: j['c'] as String? ?? 'Autres',
      source: j['s'] as String?,
      checked: j['x'] as bool? ?? false,
    );
  }
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
/// soja », « 2 carottes » — et « 400 ml + 250 g de lait de coco » quand deux
/// familles d'unités se partagent la ligne. Une liste qu'on lit dans un
/// magasin mérite autant de soin qu'une recette qu'on imprime.
String _formatItem(_Item item) =>
    formatShoppingLine(quantities: item.quantities, name: item.name);

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

/// Une ligne par produit.
///
/// `mergeShoppingProducts` rend une entrée par produit et famille d'unité,
/// toutes sous le même nom ; elles se rangent ici sur une seule ligne, avec
/// une quantité par famille. La provenance d'une ligne est celle que
/// [sourceOf] donne à son produit — les titres de recettes dans le planning,
/// le titre de la recette ouverte sinon.
List<_Item> _itemsFromProducts(
  Iterable<RecipeShoppingProduct> products,
  String Function(RecipeShoppingProduct product) sourceOf,
) {
  final order = <String>[];
  final byKey =
      <String, ({String name, List<_Qty> quantities, Set<String> sources})>{};
  for (final p in mergeShoppingProducts(products)) {
    final key = shoppingProductKey(p.name);
    final slot = byKey.putIfAbsent(key, () {
      order.add(key);
      return (name: p.name, quantities: <_Qty>[], sources: <String>{});
    });
    slot.quantities.add((qty: p.qty, unit: p.unit));
    final source = sourceOf(p).trim();
    if (source.isNotEmpty) slot.sources.add(source);
  }
  return [
    for (final key in order)
      _Item(
        name: byKey[key]!.name,
        quantities: byKey[key]!.quantities,
        category: IngredientCategorizer.categorize(byKey[key]!.name),
        source: byKey[key]!.sources.isEmpty
            ? null
            : byKey[key]!.sources.join(' · '),
      ),
  ];
}

List<_Item> _buildItems(
  List<RecipeShoppingProduct> products,
  List<RecipeIngredient> fallbackIngredients,
  String recipeTitre, {
  Map<String, String>? ingredientSources,
}) {
  final source = products.isNotEmpty
      ? products
      : [
          for (final ing in fallbackIngredients)
            RecipeShoppingProduct(name: ing.name, qty: ing.qty, unit: ing.unit),
        ];
  return _itemsFromProducts(
    source,
    (p) => ingredientSources?[p.name] ?? recipeTitre,
  );
}

/// Fusionne la liste du jour avec une nouvelle : même produit → même ligne,
/// quantités additionnées famille par famille, provenances réunies.
List<_Item> _mergeShoppingItems(List<_Item> existing, List<_Item> incoming) {
  final merged = <_Item>[];
  final indexByKey = <String, int>{};

  for (final item in [...existing, ...incoming]) {
    final key = shoppingProductKey(item.name);
    final existingIndex = indexByKey[key];
    if (existingIndex == null) {
      indexByKey[key] = merged.length;
      merged.add(
        _Item(
          name: item.name,
          quantities: List.of(item.quantities),
          category: item.category,
          source: item.source,
          checked: item.checked,
        ),
      );
      continue;
    }

    final current = merged[existingIndex];
    final quantities = mergeShoppingProducts([
      for (final q in current.quantities)
        RecipeShoppingProduct(name: current.name, qty: q.qty, unit: q.unit),
      for (final q in item.quantities)
        RecipeShoppingProduct(name: item.name, qty: q.qty, unit: q.unit),
    ]).map((p) => (qty: p.qty, unit: p.unit)).toList();
    merged[existingIndex] = _Item(
      name: current.name,
      quantities: quantities,
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
/// [products] : produits d'achat calculés par le serveur à l'écriture de la
///   recette, mis à l'échelle en mémoire. Si vide, [fallbackIngredients] est
///   utilisé à la place.
/// [fallbackIngredients] : ingrédients bruts de la recette (utilisés si
///   les produits ne sont pas encore disponibles).
/// [ingredientSources] : map optionnelle `{nom_produit → "Recette A (200 g) ·
///   Recette B (300 g)"}` — la provenance affichée sous chaque ligne. Sans
///   elle, chaque ligne porte [recipeTitre].
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
        items: grouped[key]!.map((i) => _formatItem(i)).toList(growable: false),
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
        buffer.writeln('\t${_formatItem(item)}');
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
                          _formatItem(item),
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
