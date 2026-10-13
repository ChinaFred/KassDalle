import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/services/error_reporting.dart';
import '../../../../core/theme/app_icon_size.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/utils/ingredient_categorizer.dart';
import '../../../../core/utils/platform_utils.dart';
import '../../../../core/widgets/app_states.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../data/shopping_cart_repository.dart';
import '../../domain/recipe.dart';
import '../../domain/shopping_cart.dart';
import '../../services/google_tasks_service.dart';
import '../recipe_providers.dart';

// ── Ajouter aux courses ───────────────────────────────────────────────────────

/// La phrase de la boîte « Ajouter / Remplacer » qui dit les deux choix.
const _kChoiceSentence =
    'Ajouter les fusionne avec votre liste. '
    'Remplacer efface la liste actuelle.';

/// « Ajouter aux courses » depuis la fiche d'une recette, pour les parts
/// affichées.
///
/// [products] : produits d'achat calculés par le serveur à l'écriture de la
/// recette, déjà mis à l'échelle en mémoire ; vides, [fallbackIngredients]
/// les remplacent. Rien n'est écrit dans la recette.
Future<void> addRecipeToShoppingList(
  BuildContext context,
  WidgetRef ref, {
  required List<RecipeShoppingProduct> products,
  required List<RecipeIngredient> fallbackIngredients,
  required String recipeTitre,
}) {
  final items = shoppingItemsForRecipe(
    products: products,
    fallbackIngredients: fallbackIngredients,
    recipeTitre: recipeTitre,
  );
  return addToShoppingList(
    context,
    ref,
    incoming: items,
    summary: '« $recipeTitre » apporte ${shoppingArticles(items.length)}.',
  );
}

/// Ajoute [incoming] au panier de courses du compte connecté.
///
/// Panier vide : ajout direct. Sinon, la boîte « Ajouter / Remplacer »
/// s'ouvre à chaque fois, avec [summary] (« « Poulet basquaise » apporte
/// 9 articles. ») et, pour une période, [breakdown] (« 5 de Mon planning,
/// 7 du planning de Marie »).
///
/// Les articles vont toujours dans le panier de celui qui ajoute, quel que
/// soit le planning dont vient le repas.
Future<void> addToShoppingList(
  BuildContext context,
  WidgetRef ref, {
  required List<ShoppingItem> incoming,
  required String summary,
  String? breakdown,
}) async {
  final uid = ref.read(appUserProvider).value?.uid;
  if (uid == null) return;
  if (incoming.isEmpty) {
    context.showSnackBar('Aucun ingrédient à ajouter');
    return;
  }
  final repo = ref.read(shoppingCartRepositoryProvider);

  final ShoppingCart current;
  try {
    current = await repo.load(uid);
  } catch (e) {
    // Déjà remontée par le repository (`shopping.load`) ; l'écran la dit.
    if (context.mounted) {
      context.showErrorSnackBar('Votre liste de courses n\'a pas pu être lue.');
    }
    return;
  }
  if (!context.mounted) return;

  var mode = ShoppingAddMode.add;
  if (!current.isEmpty) {
    final choice = await showDialog<ShoppingAddMode>(
      context: context,
      builder: (ctx) => _AddOrReplaceDialog(
        currentCount: current.length,
        summary: summary,
        breakdown: breakdown,
      ),
    );
    if (choice == null || !context.mounted) return;
    mode = choice;
  }

  final ShoppingAddResult result;
  try {
    result = await repo.addItems(uid, incoming, mode: mode);
  } on ShoppingCartFullException {
    if (context.mounted) {
      context.showErrorSnackBar(
        'Votre liste dépasserait $kShoppingCartMaxItems articles. Retirez '
        'les articles cochés ou remplacez la liste.',
      );
    }
    return;
  } catch (e) {
    // Déjà remontée par le repository (`shopping.addItems`).
    if (context.mounted) {
      context.showErrorSnackBar(
        'Les articles n\'ont pas pu être ajoutés aux courses.',
      );
    }
    return;
  }
  if (!context.mounted) return;

  if (mode == ShoppingAddMode.replace) {
    context.showSuccessSnackBar(
      'Liste remplacée : ${shoppingArticles(result.written.length)}.',
      action: SnackBarAction(
        label: 'Annuler',
        onPressed: () => _undoReplace(context, repo, uid, result.previous),
      ),
    );
  } else {
    final n = incoming.length;
    context.showSuccessSnackBar(
      '${shoppingArticles(n)} ajouté${n > 1 ? 's' : ''} aux courses.',
      action: SnackBarAction(
        label: 'Voir',
        onPressed: () {
          if (context.mounted) showShoppingCart(context);
        },
      ),
    );
  }
}

/// « Annuler » après un remplacement : la liste d'avant revient telle quelle.
Future<void> _undoReplace(
  BuildContext context,
  ShoppingCartRepository repo,
  String uid,
  List<ShoppingItem> previous,
) async {
  try {
    await repo.restore(uid, previous);
  } catch (e) {
    // Déjà remontée par le repository (`shopping.restore`).
    if (context.mounted) {
      context.showErrorSnackBar('La liste précédente n\'a pas pu être rendue.');
    }
  }
}

class _AddOrReplaceDialog extends StatelessWidget {
  final int currentCount;
  final String summary;
  final String? breakdown;

  const _AddOrReplaceDialog({
    required this.currentCount,
    required this.summary,
    this.breakdown,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      icon: const Icon(Icons.shopping_cart_outlined),
      title: Text(
        'Votre liste contient déjà ${shoppingArticles(currentCount)}',
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(breakdown == null ? summary : '$summary\n$breakdown.'),
          const SizedBox(height: 12),
          const Text(_kChoiceSentence),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        OutlinedButton(
          onPressed: () => Navigator.pop(context, ShoppingAddMode.replace),
          child: const Text('Remplacer'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, ShoppingAddMode.add),
          child: const Text('Ajouter'),
        ),
      ],
    );
  }
}

// ── Mes courses ───────────────────────────────────────────────────────────────

/// « Mes courses » dans une barre d'application : le chariot, et le nombre
/// d'articles qui restent à acheter.
class ShoppingCartButton extends ConsumerWidget {
  const ShoppingCartButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remaining = ref.watch(myShoppingCartProvider).value?.uncheckedCount;
    return IconButton(
      tooltip: 'Mes courses',
      onPressed: () => showShoppingCart(context),
      icon: Badge.count(
        count: remaining ?? 0,
        isLabelVisible: (remaining ?? 0) > 0,
        child: const Icon(Icons.shopping_cart_outlined),
      ),
    );
  }
}

/// Ouvre le panier : une feuille sur téléphone, une fenêtre de 560 px au plus
/// sur grand écran.
Future<void> showShoppingCart(BuildContext context) {
  final isWide =
      MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;
  if (isWide) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.85,
          ),
          child: const _ShoppingCartPanel(inDialog: true),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollCtrl) =>
          _ShoppingCartPanel(inDialog: false, scrollController: scrollCtrl),
    ),
  );
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

/// Les rayons dans l'ordre du magasin, puis les autres.
List<String> _orderedCategories(Iterable<String> present) {
  final set = present.toSet();
  return [
    ...IngredientCategorizer.categoryOrder.where(set.contains),
    ...set.where((k) => !IngredientCategorizer.categoryOrder.contains(k)),
  ];
}

enum _CartMenu { removeChecked, clear }

class _ShoppingCartPanel extends ConsumerStatefulWidget {
  final bool inDialog;
  final ScrollController? scrollController;

  const _ShoppingCartPanel({required this.inDialog, this.scrollController});

  @override
  ConsumerState<_ShoppingCartPanel> createState() => _ShoppingCartPanelState();
}

class _ShoppingCartPanelState extends ConsumerState<_ShoppingCartPanel> {
  /// Cases touchées dont l'écriture n'est pas encore confirmée : elles
  /// s'affichent dans leur nouvel état, et reprennent l'ancien si l'écriture
  /// échoue.
  final Map<String, bool> _pending = {};
  bool _opening = false;
  bool _sendingTasks = false;

  String? get _uid => ref.read(appUserProvider).value?.uid;

  List<ShoppingItem> _shown(ShoppingCart cart) => [
    for (final i in cart.items)
      _pending.containsKey(i.key) ? i.copyWith(checked: _pending[i.key]) : i,
  ];

  Future<void> _toggle(ShoppingItem item) async {
    final uid = _uid;
    if (uid == null) return;
    final next = !item.checked;
    setState(() => _pending[item.key] = next);
    try {
      await ref
          .read(shoppingCartRepositoryProvider)
          .setChecked(uid, item.key, next);
    } catch (e) {
      // Déjà remontée par le repository (`shopping.setChecked`) : la case
      // reprend son état, l'écran le dit.
      if (mounted) {
        context.showErrorSnackBar('La case n\'a pas pu être enregistrée.');
      }
    } finally {
      if (mounted) setState(() => _pending.remove(item.key));
    }
  }

  Future<void> _onMenu(_CartMenu action, List<ShoppingItem> items) async {
    final uid = _uid;
    if (uid == null) return;
    final repo = ref.read(shoppingCartRepositoryProvider);
    switch (action) {
      case _CartMenu.removeChecked:
        try {
          await repo.removeItems(uid, [
            for (final i in items)
              if (i.checked) i.key,
          ]);
        } catch (e) {
          // Déjà remontée par le repository (`shopping.removeItems`).
          if (mounted) {
            context.showErrorSnackBar(
              'Les articles cochés n\'ont pas pu être retirés.',
            );
          }
        }
      case _CartMenu.clear:
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Vider la liste de courses ?'),
            content: Text(
              'Les ${shoppingArticles(items.length)} seront retirés, sur tous '
              'vos appareils.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Annuler'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Vider'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        try {
          await repo.clear(uid);
        } catch (e) {
          // Déjà remontée par le repository (`shopping.clear`).
          if (mounted) {
            context.showErrorSnackBar('La liste n\'a pas pu être vidée.');
          }
        }
    }
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
  Future<void> _sendToTasks(List<ShoppingItem> items) async {
    final grouped = <String, List<ShoppingItem>>{};
    for (final item in items) {
      if (item.checked) continue;
      (grouped[item.category] ??= []).add(item);
    }
    if (grouped.isEmpty) {
      context.showSnackBar('Tout est déjà coché : rien à envoyer.');
      return;
    }
    final groups = <({String category, List<String> items})>[
      for (final key in _orderedCategories(grouped.keys))
        (
          category: key,
          items: grouped[key]!.map((i) => i.label).toList(growable: false),
        ),
    ];

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

  String _buildKeepText(List<ShoppingItem> items) {
    final buffer = StringBuffer()
      ..writeln("Liste de courses Kass'Dalle – ${_todayFr()}");
    final grouped = <String, List<ShoppingItem>>{};
    for (final item in items) {
      (grouped[item.category] ??= []).add(item);
    }
    for (final cat in _orderedCategories(grouped.keys)) {
      buffer.writeln(cat.toUpperCase());
      for (final item in grouped[cat]!) {
        buffer.writeln('\t${item.label}');
      }
    }
    return buffer.toString().trim();
  }

  Future<void> _openKeep(List<ShoppingItem> items) async {
    setState(() => _opening = true);
    try {
      await Clipboard.setData(ClipboardData(text: _buildKeepText(items)));
      final uri = Uri.parse('https://keep.google.com/');
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
      if (mounted) {
        context.showSuccessSnackBar(
          'Liste copiée ! Dans Keep : créez une nouvelle note et collez (appui long).',
        );
      }
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'shoppingList.openKeep',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) context.showErrorSnackBar('Copie impossible : $error');
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final async = ref.watch(myShoppingCartProvider);
    final cart = async.value;
    final items = cart == null ? const <ShoppingItem>[] : _shown(cart);
    final checked = items.where((i) => i.checked).length;

    final Widget body;
    if (cart == null && async.hasError) {
      body = AppErrorState(
        error: async.error,
        title: 'Votre liste de courses n\'a pas pu être lue.',
        onRetry: () => ref.invalidate(myShoppingCartProvider),
      );
    } else if (cart == null) {
      body = const AppLoadingState();
    } else if (items.isEmpty) {
      body = const AppEmptyState(
        icon: Icons.shopping_cart_outlined,
        title: 'Votre liste de courses est vide.',
        message:
            'Ajoutez un repas depuis le planning, ou une recette depuis sa '
            'fiche.',
      );
    } else {
      body = _buildList(theme, items);
    }

    return Column(
      mainAxisSize: widget.inDialog ? MainAxisSize.min : MainAxisSize.max,
      children: [
        if (!widget.inDialog) ...[
          const SizedBox(height: 12),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: theme.colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
        const SizedBox(height: 12),
        _buildHeader(theme, items, checked),
        const SizedBox(height: 8),
        const Divider(),
        if (widget.inDialog) Flexible(child: body) else Expanded(child: body),
        if (items.isNotEmpty) _buildActions(theme, items),
      ],
    );
  }

  Widget _buildHeader(ThemeData theme, List<ShoppingItem> items, int checked) {
    final subtitle = [
      shoppingArticles(items.length),
      if (checked > 0) '$checked coché${checked > 1 ? 's' : ''}',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(left: 20, right: 8),
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
                  'Mes courses',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (items.isNotEmpty)
                  Text(
                    subtitle,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (items.isNotEmpty)
            PopupMenuButton<_CartMenu>(
              tooltip: 'Actions de la liste',
              onSelected: (action) => _onMenu(action, items),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: _CartMenu.removeChecked,
                  enabled: checked > 0,
                  child: const ListTile(
                    leading: Icon(Icons.remove_done),
                    title: Text('Retirer les articles cochés'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: _CartMenu.clear,
                  child: ListTile(
                    leading: Icon(Icons.delete_sweep_outlined),
                    title: Text('Vider la liste'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          if (widget.inDialog)
            IconButton(
              tooltip: 'Fermer',
              icon: const Icon(Icons.close),
              onPressed: () => Navigator.pop(context),
            ),
        ],
      ),
    );
  }

  Widget _buildList(ThemeData theme, List<ShoppingItem> items) {
    final grouped = <String, List<ShoppingItem>>{};
    for (final item in items) {
      (grouped[item.category] ??= []).add(item);
    }
    return ListView(
      controller: widget.scrollController,
      shrinkWrap: widget.inDialog,
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
      children: [
        for (final cat in _orderedCategories(grouped.keys)) ...[
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
          for (final item in grouped[cat]!)
            CheckboxListTile(
              value: item.checked,
              onChanged: (_) => _toggle(item),
              title: Text(
                item.label,
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
    );
  }

  Widget _buildActions(ThemeData theme, List<ShoppingItem> items) {
    final scheme = theme.colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              onPressed: _sendingTasks ? null : () => _sendToTasks(items),
              icon: _sendingTasks
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        // Bouton désactivé pendant l'envoi : l'indicateur
                        // prend la couleur de son libellé grisé.
                        color: scheme.onSurface.withValues(alpha: 0.38),
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
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _opening ? null : () => _openKeep(items),
              icon: _opening
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: scheme.primary,
                      ),
                    )
                  : const Icon(Icons.open_in_new, size: AppIconSize.small),
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
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
