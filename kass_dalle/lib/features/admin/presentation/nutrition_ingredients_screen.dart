import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'admin_providers.dart';
import '../data/nutrition_ingredients_repository.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/theme/app_icon_size.dart';

class NutritionIngredientsScreen extends ConsumerStatefulWidget {
  /// Préremplit la recherche — utilisé par le dashboard de qualité des
  /// données pour ouvrir l'écran directement sur l'ingrédient concerné.
  final String? initialSearch;

  const NutritionIngredientsScreen({super.key, this.initialSearch});

  @override
  ConsumerState<NutritionIngredientsScreen> createState() =>
      _NutritionIngredientsScreenState();
}

class _NutritionIngredientsScreenState
    extends ConsumerState<NutritionIngredientsScreen> {
  late final _searchCtrl = TextEditingController(
    text: widget.initialSearch ?? '',
  );
  late String _search = widget.initialSearch?.trim() ?? '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Corrige le produit acheté d'un ingrédient — la seule valeur du
  /// référentiel qui s'édite ici. Vide = le nom est déjà le produit.
  Future<void> _editShoppingProduct(NutritionIngredientDoc doc) async {
    final controller = TextEditingController(text: doc.shoppingProduct ?? '');
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Produit acheté'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Sur la liste de courses, « ${doc.id.replaceAll('_', ' ')} » '
              's\'achète sous ce nom. Laissez vide si le nom est déjà le '
              'produit.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Produit acheté',
                hintText: 'beurre, œuf, ail…',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || !mounted) return;
    try {
      await ref
          .read(nutritionIngredientsRepositoryProvider)
          .setShoppingProduct(doc.id, value);
      if (!mounted) return;
      context.showSuccessSnackBar(
        value.trim().isEmpty
            ? 'Produit acheté effacé : le nom est le produit. Lancez '
                  '« Recalculer les produits d\'achat » pour les recettes.'
            : 'Produit acheté enregistré : ${value.trim()}. Lancez '
                  '« Recalculer les produits d\'achat » pour les recettes.',
      );
    } catch (e) {
      if (!mounted) return;
      context.showErrorSnackBar('Enregistrement impossible : $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ingredientsAsync = ref.watch(allNutritionIngredientsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Ingrédients nutrition')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Rechercher par ID (ex: sucre, huile_olive)',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _search.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _search = '');
                        },
                        tooltip: 'Effacer la recherche',
                        icon: const Icon(Icons.close),
                      ),
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _search = value.trim()),
            ),
          ),
          Expanded(
            child: ingredientsAsync.when(
              loading: () => const AppLoadingState(),
              error: (e, _) => AppErrorState(
                error: e,
                onRetry: () => ref.invalidate(allNutritionIngredientsProvider),
              ),
              data: (items) {
                final query = _search.toLowerCase();
                final filtered = query.isEmpty
                    ? items
                    : items
                          .where((x) => x.id.toLowerCase().contains(query))
                          .toList(growable: false);

                if (filtered.isEmpty) {
                  return const Center(
                    child: Text('Aucun ingrédient nutrition trouvé.'),
                  );
                }

                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  itemCount: filtered.length,
                  itemBuilder: (context, index) {
                    final doc = filtered[index];
                    final keys = doc.per100g.keys.toList()..sort();
                    final subtitle = keys.isEmpty
                        ? 'Aucune valeur per100g'
                        : keys
                              .take(8)
                              .map((k) {
                                final v = doc.per100g[k]!;
                                return '$k=${v.toStringAsFixed(2)}';
                              })
                              .join(' · ');

                    // L'échec d'enrichissement est marqué sur le document : sans
                    // ce statut, un ingrédient resté muet était indiscernable
                    // d'un ingrédient jamais rencontré.
                    final failed = doc.qualityStatus == 'estimation_failed';

                    // Trois états : jamais examiné, déjà le produit, ou un
                    // autre produit. Les trois se lisent, sinon un alias absent
                    // et un alias vide se confondent.
                    final shopping = doc.shoppingProduct;
                    final shoppingText = shopping == null
                        ? 'non examiné'
                        : shopping.trim().isEmpty
                        ? 'le nom lui-même'
                        : shopping.trim();

                    return Card(
                      child: ExpansionTile(
                        title: Row(
                          children: [
                            Expanded(child: Text(doc.id)),
                            if (failed)
                              Tooltip(
                                message:
                                    'Estimation IA sans résultat exploitable : '
                                    'cet ingrédient est exclu du calcul des recettes.',
                                child: Icon(
                                  Icons.error_outline,
                                  size: AppIconSize.small,
                                  color: Theme.of(context).colorScheme.error,
                                ),
                              )
                            else if (doc.isAiEstimated)
                              Tooltip(
                                message: 'Valeurs estimées par l\'IA.',
                                child: Icon(
                                  Icons.auto_awesome_outlined,
                                  size: AppIconSize.small,
                                  color: Theme.of(context).colorScheme.tertiary,
                                ),
                              ),
                          ],
                        ),
                        subtitle: Text(
                          'source: ${doc.source.isEmpty ? 'n/a' : doc.source} · $subtitle',
                        ),
                        childrenPadding: const EdgeInsets.fromLTRB(
                          16,
                          0,
                          16,
                          12,
                        ),
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text('Produit acheté : $shoppingText'),
                              ),
                              IconButton(
                                tooltip: 'Corriger le produit acheté',
                                icon: const Icon(
                                  Icons.edit_outlined,
                                  size: AppIconSize.small,
                                ),
                                onPressed: () => _editShoppingProduct(doc),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (keys.isEmpty)
                            const Align(
                              alignment: Alignment.centerLeft,
                              child: Text(
                                'Aucune donnee nutritionnelle detaillee.',
                              ),
                            )
                          else
                            Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final key in keys)
                                  Chip(
                                    label: Text(
                                      '$key: ${doc.per100g[key]!.toStringAsFixed(2)}',
                                    ),
                                  ),
                              ],
                            ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
