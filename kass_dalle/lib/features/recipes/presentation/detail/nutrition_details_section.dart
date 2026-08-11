import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/nutrition_units_reference.dart';
import '../../../admin/data/nutrition_ingredients_repository.dart';
import '../../domain/recipe.dart';
import '../recipe_providers.dart';

const _nutritionMetricKeys = [
  ('kcal', 'Calories'),
  ('protein_g', 'Proteines'),
  ('carbs_g', 'Glucides'),
  ('sugar_g', 'Sucres'),
  ('fiber_g', 'Fibres'),
  ('fat_g', 'Lipides'),
  ('saturated_fat_g', 'Satures'),
  ('salt_g', 'Sel'),
];

/// Détail nutritionnel d'une recette : contribution de chaque ingrédient,
/// couverture du calcul et recalcul à la demande.
///
/// Extrait de recipe_detail_screen.dart, qui n'a plus à porter que
/// l'orchestration de l'écran et ses onglets.

class _MiniMetric extends StatelessWidget {
  final String label;
  final String value;

  const _MiniMetric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 150,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Text(value, style: Theme.of(context).textTheme.titleSmall),
        ],
      ),
    );
  }
}

class _NutritionIngredientRow {
  final RecipeIngredient ingredient;
  final String canonicalId;
  final Map<String, double>? perIngredient;
  final double? weightGrams;

  const _NutritionIngredientRow({
    required this.ingredient,
    required this.canonicalId,
    this.perIngredient,
    this.weightGrams,
  });
}

class NutritionDetailsSection extends ConsumerStatefulWidget {
  final Recipe recipe;
  final int? selectedPortions;
  final Future<void> Function() onRecompute;

  const NutritionDetailsSection({
    super.key,
    required this.recipe,
    required this.selectedPortions,
    required this.onRecompute,
  });

  @override
  ConsumerState<NutritionDetailsSection> createState() =>
      _NutritionDetailsSectionState();
}

class _NutritionDetailsSectionState
    extends ConsumerState<NutritionDetailsSection> {
  bool _showContributionTable = true;
  bool _showIngredientDetails = true;

  String _fmtNum(double? v, {bool integer = false}) {
    if (v == null) return '-';
    return integer ? v.round().toString() : v.toStringAsFixed(1);
  }

  String _normalizeId(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[\u0300-\u036f]'), '')
        .replaceAll('é', 'e')
        .replaceAll('è', 'e')
        .replaceAll('ê', 'e')
        .replaceAll('ë', 'e')
        .replaceAll('à', 'a')
        .replaceAll('â', 'a')
        .replaceAll('î', 'i')
        .replaceAll('ï', 'i')
        .replaceAll('ô', 'o')
        .replaceAll('ö', 'o')
        .replaceAll('ù', 'u')
        .replaceAll('û', 'u')
        .replaceAll('ü', 'u')
        .replaceAll('ç', 'c')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
  }

  /// Poids d'un ingrédient, référentiel `nutrition_units` appliqué.
  ///
  /// Passe par le même arbitrage que le calcul serveur : sans cela, l'affichage
  /// et la valeur persistée pouvaient diverger dès qu'une unité était corrigée
  /// depuis l'écran d'administration.
  double? _ingredientWeight(RecipeIngredient ingredient) =>
      resolveIngredientWeightGrams(
        overrides: ref.watch(nutritionUnitOverridesProvider),
        ingredientName: ingredient.name,
        qty: ingredient.qty,
        unit: ingredient.unit,
      );

  Map<String, double>? _perIngredientFor(
    RecipeIngredient ingredient,
    Map<String, NutritionIngredientDoc> nutritionById,
    double weightGrams,
  ) {
    final candidates = <String>{
      _normalizeId(ingredient.name),
      _normalizeId(
        ingredient.name.replaceAll(
          RegExp(r'\b(hachee?|emincee?|rapee?|cisee?lee?|coupee?)\b'),
          '',
        ),
      ),
    }.where((value) => value.isNotEmpty);

    for (final candidate in candidates) {
      final doc = nutritionById[candidate];
      if (doc == null || doc.per100g.isEmpty) continue;
      final out = <String, double>{};
      for (final entry in doc.per100g.entries) {
        out[entry.key] = (weightGrams * entry.value) / 100;
      }
      return out;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final nutritionAsync = ref.watch(nutritionIngredientsByIdProvider);
    final snapshot = widget.recipe.nutrition;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (snapshot == null)
          Row(
            children: [
              const Expanded(
                child: Text('Aucune donnee nutritionnelle calculee.'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: () => widget.onRecompute(),
                icon: const Icon(Icons.calculate_outlined),
                label: const Text('Calculer'),
              ),
            ],
          )
        else
          nutritionAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Text('Erreur nutrition : $e'),
            data: (nutritionById) {
              final rows = widget.recipe.ingredients
                  .where((ingredient) => ingredient.name.trim().isNotEmpty)
                  .map((ingredient) {
                    final weight = _ingredientWeight(ingredient);
                    return _NutritionIngredientRow(
                      ingredient: ingredient,
                      canonicalId: _normalizeId(ingredient.name),
                      perIngredient: weight == null
                          ? null
                          : _perIngredientFor(
                              ingredient,
                              nutritionById,
                              weight,
                            ),
                      weightGrams: weight,
                    );
                  })
                  .toList(growable: false);

              double? totalFor(String key) {
                var hasValue = false;
                var sum = 0.0;
                for (final row in rows) {
                  final value = row.perIngredient?[key];
                  if (value == null) continue;
                  hasValue = true;
                  sum += value;
                }
                return hasValue ? sum : null;
              }

              final knownWeight = rows.fold<double>(
                0,
                (acc, row) => acc + (row.weightGrams ?? 0),
              );

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _MiniMetric(
                        label: 'Calories / portion',
                        value:
                            '${_fmtNum(snapshot.perPortion['kcal'], integer: true)} kcal',
                      ),
                      _MiniMetric(
                        label: 'Proteines',
                        value: '${_fmtNum(snapshot.perPortion['protein_g'])} g',
                      ),
                      _MiniMetric(
                        label: 'Glucides',
                        value: '${_fmtNum(snapshot.perPortion['carbs_g'])} g',
                      ),
                      _MiniMetric(
                        label: 'Lipides',
                        value: '${_fmtNum(snapshot.perPortion['fat_g'])} g',
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Chip(
                        label: Text(
                          'Couverture ${(snapshot.coverage * 100).toStringAsFixed(0)} %',
                        ),
                      ),
                      Chip(
                        label: Text(
                          'Qualite ${snapshot.quality.level} (${snapshot.quality.score})',
                        ),
                      ),
                      Chip(label: Text('Etat ${snapshot.coverageState}')),
                    ],
                  ),
                  if (snapshot.quality.warnings.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ...snapshot.quality.warnings.map(
                      (warning) => Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          warning,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  InkWell(
                    onTap: () {
                      setState(() {
                        _showContributionTable = !_showContributionTable;
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Apports par ingredient',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          Icon(
                            _showContributionTable
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_showContributionTable) ...[
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: DataTable(
                        columns: const [
                          DataColumn(label: Text('Ingredient')),
                          DataColumn(label: Text('Quantite')),
                          DataColumn(label: Text('Calories')),
                          DataColumn(label: Text('Proteines')),
                          DataColumn(label: Text('Glucides')),
                          DataColumn(label: Text('Sucres')),
                          DataColumn(label: Text('Fibres')),
                          DataColumn(label: Text('Lipides')),
                          DataColumn(label: Text('Satures')),
                          DataColumn(label: Text('Sel')),
                        ],
                        rows: [
                          DataRow(
                            cells: [
                              const DataCell(
                                Text(
                                  'TOTAL',
                                  style: TextStyle(fontWeight: FontWeight.w700),
                                ),
                              ),
                              DataCell(
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      knownWeight > 0
                                          ? '${knownWeight.toStringAsFixed(0)} g'
                                          : '-',
                                    ),
                                    const SizedBox(width: 4),
                                    GestureDetector(
                                      onTap: () => setState(() {
                                        _showIngredientDetails =
                                            !_showIngredientDetails;
                                      }),
                                      child: Icon(
                                        _showIngredientDetails
                                            ? Icons.unfold_less
                                            : Icons.unfold_more,
                                        size: 16,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              for (final metric in _nutritionMetricKeys)
                                DataCell(
                                  Text(
                                    _fmtNum(
                                      totalFor(metric.$1),
                                      integer: metric.$1 == 'kcal',
                                    ),
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          if (_showIngredientDetails)
                            for (final row in rows)
                              DataRow(
                                cells: [
                                  DataCell(Text(row.ingredient.name)),
                                  DataCell(
                                    Text(
                                      '${row.ingredient.qty}${row.ingredient.unit.isNotEmpty ? ' ${row.ingredient.unit}' : ''}',
                                    ),
                                  ),
                                  for (final metric in _nutritionMetricKeys)
                                    DataCell(
                                      Text(
                                        _fmtNum(
                                          row.perIngredient?[metric.$1],
                                          integer: metric.$1 == 'kcal',
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => widget.onRecompute(),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Recalculer'),
                    ),
                  ),
                ],
              );
            },
          ),
      ],
    );
  }
}
