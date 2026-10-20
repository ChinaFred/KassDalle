import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'admin_providers.dart';
import '../data/nutrition_ingredients_repository.dart';
import '../../recipes/domain/allergens.dart';
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
      // Signalée au rapport d'erreurs par
      // NutritionIngredientsRepository.setShoppingProduct.
      if (!mounted) return;
      context.showFailureSnackBar('Produit acheté non enregistré', e);
    }
  }

  /// Corrige les allergènes d'un ingrédient. Enregistrer sans rien cocher
  /// signifie « aucun allergène » ; enregistrer sans changement confirme la
  /// liste estimée par l'IA.
  Future<void> _editAllergens(NutritionIngredientDoc doc) async {
    final selected = <String>{...?doc.allergens};
    final name = doc.id.replaceAll('_', ' ');
    final value = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          scrollable: true,
          title: const Text('Allergènes'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Cochez les allergènes que contient « $name ». Enregistrer '
                'sans rien cocher signifie : aucun allergène.',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final key in kAllergenKeys)
                    FilterChip(
                      label: Text(allergenLabel(key)),
                      selected: selected.contains(key),
                      onSelected: (on) => setDialogState(() {
                        if (on) {
                          selected.add(key);
                        } else {
                          selected.remove(key);
                        }
                      }),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(ctx).pop(sortAllergenKeys(selected)),
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (value == null || !mounted) return;
    try {
      await ref
          .read(nutritionIngredientsRepositoryProvider)
          .setAllergens(doc.id, value);
      if (!mounted) return;
      final list = value.isEmpty
          ? 'aucun'
          : value.map(allergenLabel).join(', ');
      context.showSuccessSnackBar(
        'Allergènes enregistrés : $list. Lancez « Allergènes des '
        'ingrédients et des recettes » pour les recettes.',
      );
    } catch (e) {
      // Signalée au rapport d'erreurs par
      // NutritionIngredientsRepository.setAllergens.
      if (!mounted) return;
      context.showFailureSnackBar('Allergènes non enregistrés', e);
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
                  return items.isEmpty
                      ? const AppEmptyState(
                          icon: Icons.eco_outlined,
                          title: 'Aucun ingrédient nutrition',
                          message:
                              'La liste se remplit quand la nutrition d\'une '
                              'recette est calculée. Lancez « Reprendre '
                              'la nutrition » dans Admin › Backfills pour les '
                              'recettes existantes.',
                        )
                      : const AppEmptyState(
                          icon: Icons.search_off,
                          title: 'Aucun ingrédient ne correspond',
                          message: 'Modifiez ou effacez la recherche.',
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

                    // Même distinction pour les allergènes : jamais examiné,
                    // aucun, ou la liste — et qui l'a posée.
                    final allergens = doc.allergens;
                    final allergensOrigin = doc.allergensVerified
                        ? '(vérifié par l\'admin)'
                        : '(estimé par l\'IA)';
                    final allergensText = allergens == null
                        ? 'non examiné'
                        : allergens.isEmpty
                        ? 'aucun $allergensOrigin'
                        : '${allergens.map(allergenLabel).join(', ')} '
                              '$allergensOrigin';

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
                            if (allergens == null) ...[
                              const SizedBox(width: 4),
                              Tooltip(
                                message: 'Allergènes non examinés',
                                child: Icon(
                                  Icons.help_outline,
                                  size: AppIconSize.small,
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ],
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
                          Row(
                            children: [
                              Expanded(
                                child: Text('Allergènes : $allergensText'),
                              ),
                              IconButton(
                                tooltip: 'Corriger les allergènes',
                                icon: const Icon(
                                  Icons.edit_outlined,
                                  size: AppIconSize.small,
                                ),
                                onPressed: () => _editAllergens(doc),
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
