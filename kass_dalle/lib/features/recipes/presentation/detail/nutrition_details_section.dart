import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/ingredient_name.dart';

import '../../../../core/services/nutrition_units_reference.dart';
import '../../../admin/data/nutrition_ingredients_repository.dart';
import '../../domain/recipe.dart';
import '../recipe_providers.dart';

const _nutritionMetricKeys = [
  ('kcal', 'Calories'),
  ('protein_g', 'Protéines'),
  ('carbs_g', 'Glucides'),
  ('sugar_g', 'Sucres'),
  ('fiber_g', 'Fibres'),
  ('fat_g', 'Lipides'),
  ('saturated_fat_g', 'Saturés'),
  ('salt_g', 'Sel'),
];

/// Libellé français de l'état de couverture renvoyé par le backend.
///
/// Le backend parle en `full` / `partial` / `low` ; ces valeurs techniques
/// s'affichaient telles quelles à l'utilisateur.
String _coverageStateLabel(String state) => switch (state) {
  'full' => 'Calcul complet',
  'partial' => 'Calcul partiel',
  'low' => 'Calcul incomplet',
  _ => 'État inconnu',
};

String _coverageStateExplanation(String state) => switch (state) {
  'full' =>
    'Le poids de tous les ingrédients est connu : les valeurs affichées '
        'couvrent la recette entière.',
  'partial' =>
    'Le poids de certains ingrédients est inconnu. Les valeurs affichées ne '
        'portent que sur la part de la recette qui a pu être calculée — la vue '
        'pour 100 g est masquée, car elle serait trompeuse.',
  'low' =>
    'Trop peu d\'ingrédients ont un poids connu pour que le calcul soit '
        'représentatif.',
  _ => 'État de couverture non reconnu.',
};

/// Explique le score de fiabilité, qui n'a de sens que si on en connaît les
/// composantes.
String _qualityExplanation(RecipeNutritionQuality quality) {
  final base =
      'Fiabilité du calcul, sur 100. Elle combine la part des ingrédients '
      'dont le poids et les valeurs nutritionnelles sont connus, et la '
      'cohérence entre les calories annoncées et celles recalculées depuis '
      'les macronutriments.\n\n'
      'A : 80 et plus  ·  B : 60 à 79  ·  C : en dessous de 60.';
  if (quality.warnings.isEmpty) return base;
  return '$base\n\nPoints d\'attention :\n'
      '${quality.warnings.map((w) => '• $w').join('\n')}';
}

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

  /// Les valeurs nutritionnelles de cet ingrédient sont estimées par l'IA.
  final bool valuesEstimated;

  /// Le poids d'une unité de cet ingrédient est estimé par l'IA
  /// (« 1 fine tranche » ne se mesure pas, elle se devine).
  final bool weightEstimated;

  const _NutritionIngredientRow({
    required this.ingredient,
    required this.canonicalId,
    this.perIngredient,
    this.weightGrams,
    this.valuesEstimated = false,
    this.weightEstimated = false,
  });

  /// Rien à afficher : ni poids, ni valeurs. C'est le cas qu'il ne faut pas
  /// laisser passer pour une simple série de tirets.
  bool get isMissing => perIngredient == null;
}

/// Pourquoi cet ingrédient ne contribue à rien : poids inconnu, valeurs
/// inconnues, ou les deux. Le distinguer évite de chercher au mauvais endroit —
/// le poids se corrige dans les unités, les valeurs dans les ingrédients.
String _missingExplanation(_NutritionIngredientRow row) {
  if (row.weightGrams == null) {
    return 'Poids inconnu : la quantité « ${row.ingredient.qty} '
        '${row.ingredient.unit} » ne se convertit pas en grammes. '
        'Renseignez l\'unité depuis Admin → Unités.';
  }
  return 'Aucune valeur nutritionnelle connue pour '
      '« ${row.ingredient.name} » : il est exclu du total. '
      'Relancez l\'enrichissement depuis Admin → Backfills.';
}

/// Ligne de légende sous le tableau des apports.
class _LegendEntry extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;

  const _LegendEntry({
    required this.icon,
    required this.color,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}

/// Marque discrète mais explicite d'une valeur estimée.
///
/// Une estimation vaut mieux qu'une case vide — un ingrédient sans valeur
/// disparaît du total sans que rien ne le dise. Encore faut-il que le lecteur
/// sache ce qu'il regarde : d'où cette pastille et son explication au survol.
class _EstimationBadge extends StatelessWidget {
  final String message;

  const _EstimationBadge({required this.message});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.tertiary;
    return Tooltip(
      message: message,
      child: Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Icon(Icons.auto_awesome, size: 14, color: color),
      ),
    );
  }
}

/// Signale un ingrédient qui ne contribue à rien, et dit pourquoi.
class _MissingBadge extends StatelessWidget {
  final String message;

  const _MissingBadge({required this.message});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return Tooltip(
      message: message,
      child: Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Icon(Icons.help_outline, size: 14, color: color),
      ),
    );
  }
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

  /// Document du référentiel qui porte les valeurs de cet ingrédient.
  NutritionIngredientDoc? _profileFor(
    RecipeIngredient ingredient,
    Map<String, NutritionIngredientDoc> nutritionById,
  ) {
    for (final candidate in buildIngredientLookupIds(ingredient.name)) {
      final doc = nutritionById[candidate];
      if (doc == null || doc.per100g.isEmpty) continue;
      return doc;
    }
    return null;
  }

  Map<String, double> _contributionOf(
    NutritionIngredientDoc profile,
    double weightGrams,
  ) {
    return {
      for (final entry in profile.per100g.entries)
        entry.key: (weightGrams * entry.value) / 100,
    };
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
                child: Text('Aucune donnée nutritionnelle calculée.'),
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
              final unitInfos = ref.watch(nutritionUnitInfosProvider);
              final rows = widget.recipe.ingredients
                  .where((ingredient) => ingredient.name.trim().isNotEmpty)
                  .map((ingredient) {
                    final weight = _ingredientWeight(ingredient);
                    final profile = _profileFor(ingredient, nutritionById);
                    return _NutritionIngredientRow(
                      ingredient: ingredient,
                      canonicalId: normalizeIngredientCanonicalId(
                        ingredient.name,
                      ),
                      perIngredient: weight == null || profile == null
                          ? null
                          : _contributionOf(profile, weight),
                      weightGrams: weight,
                      valuesEstimated: profile?.isAiEstimated ?? false,
                      weightEstimated: isUnitWeightEstimated(
                        infos: unitInfos,
                        unit: ingredient.unit,
                      ),
                    );
                  })
                  .toList(growable: false);
              final estimatedCount = rows
                  .where((r) => !r.isMissing && (r.valuesEstimated || r.weightEstimated))
                  .length;
              final missingCount = rows.where((r) => r.isMissing).length;

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
                        label: 'Protéines',
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
                      Tooltip(
                        message: _qualityExplanation(snapshot.quality),
                        child: Chip(
                          label: Text(
                            'Fiabilité ${snapshot.quality.level} '
                            '(${snapshot.quality.score}/100)',
                          ),
                        ),
                      ),
                      Tooltip(
                        message: _coverageStateExplanation(
                          snapshot.coverageState,
                        ),
                        child: Chip(
                          label: Text(
                            _coverageStateLabel(snapshot.coverageState),
                          ),
                        ),
                      ),
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
                          DataColumn(label: Text('Protéines')),
                          DataColumn(label: Text('Glucides')),
                          DataColumn(label: Text('Sucres')),
                          DataColumn(label: Text('Fibres')),
                          DataColumn(label: Text('Lipides')),
                          DataColumn(label: Text('Saturés')),
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
                                  DataCell(
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(row.ingredient.name),
                                        if (row.isMissing)
                                          _MissingBadge(
                                            message: _missingExplanation(row),
                                          )
                                        else if (row.valuesEstimated)
                                          _EstimationBadge(
                                            message:
                                                'Valeurs nutritionnelles estimées par l\'IA pour '
                                                '« ${row.ingredient.name} ». Sans cette estimation, '
                                                'l\'ingrédient serait absent du total. '
                                                'Corrigeable depuis Admin → Référentiels.',
                                          ),
                                      ],
                                    ),
                                  ),
                                  DataCell(
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          '${row.ingredient.qty}${row.ingredient.unit.isNotEmpty ? ' ${row.ingredient.unit}' : ''}',
                                        ),
                                        if (row.weightEstimated)
                                          _EstimationBadge(
                                            message:
                                                'Poids d\'une unité « ${row.ingredient.unit} » estimé '
                                                'par l\'IA : cette unité ne correspond à aucune mesure '
                                                'standard. Corrigeable depuis Admin → Unités.',
                                          ),
                                      ],
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
                  if (estimatedCount > 0 || missingCount > 0) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        if (estimatedCount > 0)
                          _LegendEntry(
                            icon: Icons.auto_awesome,
                            color: Theme.of(context).colorScheme.tertiary,
                            label:
                                '$estimatedCount ingrédient(s) reposent sur une estimation IA',
                          ),
                        if (missingCount > 0)
                          _LegendEntry(
                            icon: Icons.help_outline,
                            color: Theme.of(context).colorScheme.error,
                            label:
                                '$missingCount ingrédient(s) sans valeur, exclus du total',
                          ),
                      ],
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
