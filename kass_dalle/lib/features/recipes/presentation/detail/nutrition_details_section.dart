import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/utils/ingredient_name.dart';
import '../../../../core/utils/nutrition_quantity_converter.dart';

import '../../../../core/services/nutrition_units_reference.dart';
import '../../../admin/data/nutrition_ingredients_repository.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../domain/recipe.dart';
import '../recipe_providers.dart';
import '../../../../core/widgets/app_states.dart';

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

  /// Le poids d'une unité de cet ingrédient est estimé par l'IA
  /// (« 1 fine tranche » ne se mesure pas, elle se devine).
  final bool weightEstimated;

  /// L'ingrédient appartient à la recette mais pas au repas : bain de friture,
  /// foin de fumage, marinade jetée. Ses valeurs restent affichées — les
  /// masquer reviendrait à cacher un ingrédient — mais sortent du total.
  final bool notConsumed;

  /// La ligne reprend un ingrédient déjà listé : la pièce achetée revient
  /// découpée ou sous un nom générique. Même traitement que [notConsumed] —
  /// visible, atténuée, hors total.
  final bool duplicate;

  const _NutritionIngredientRow({
    required this.ingredient,
    required this.canonicalId,
    this.perIngredient,
    this.weightGrams,
    this.weightEstimated = false,
    this.notConsumed = false,
    this.duplicate = false,
  });

  /// Écartée du total, mais délibérément : rien à corriger ici.
  bool get isExcluded => notConsumed || duplicate;

  /// Rien à afficher : ni poids, ni valeurs. C'est le cas qu'il ne faut pas
  /// laisser passer pour une simple série de tirets.
  ///
  /// Un ingrédient écarté volontairement n'est pas « manquant » : son absence
  /// du total est voulue.
  bool get isMissing => perIngredient == null && !isExcluded;
}

/// Pourquoi cet ingrédient ne contribue à rien : poids inconnu, valeurs
/// inconnues, ou les deux. Le distinguer évite de chercher au mauvais endroit —
/// le poids se corrige dans les unités, les valeurs dans les ingrédients.
///
/// Le chemin de correction n'est donné qu'aux administrateurs : le routeur
/// renvoie tout autre rôle à l'accueil dès qu'il touche `/admin`. Envoyer un
/// lecteur vers « Admin → Unités », c'est lui demander d'ouvrir une porte
/// fermée. Les autres rôles apprennent ce qui manque, pas où le réparer.
String _missingExplanation(
  _NutritionIngredientRow row, {
  required bool isAdmin,
}) {
  if (row.weightGrams == null) {
    final base =
        'Poids inconnu : la quantité « ${row.ingredient.qty} '
        '${row.ingredient.unit} » ne se convertit pas en grammes.';
    return isAdmin ? '$base Renseignez l\'unité depuis Admin → Unités.' : base;
  }
  final base =
      'Aucune valeur nutritionnelle connue pour '
      '« ${row.ingredient.name} » : il est exclu du total.';
  return isAdmin
      ? '$base Relancez l\'enrichissement depuis Admin → Backfills.'
      : base;
}

/// Même règle pour le poids estimé par l'IA.
String _estimatedUnitExplanation(
  _NutritionIngredientRow row, {
  required bool isAdmin,
}) {
  final base =
      'Poids d\'une unité « ${row.ingredient.unit} » estimé par l\'IA : '
      'cette unité ne correspond à aucune mesure standard.';
  return isAdmin ? '$base Corrigeable depuis Admin → Unités.' : base;
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

/// Signale une ligne volontairement écartée du total, et dit laquelle.
class _NotConsumedBadge extends StatelessWidget {
  final String name;
  final bool duplicate;

  const _NotConsumedBadge({required this.name, this.duplicate = false});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.outline;
    return Tooltip(
      message: duplicate
          ? '« $name » reprend un ingrédient déjà listé plus haut — la même '
                'pièce, découpée ou nommée autrement. Comptée une seule fois : '
                'ses valeurs sont affichées mais exclues du total.'
          : '« $name » ne finit pas dans l\'assiette (bain de cuisson, support '
                'de fumage, marinade jetée) : ses valeurs sont affichées mais '
                'exclues du total.',
      child: Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Icon(
          duplicate
              ? Icons.content_copy_outlined
              : Icons.do_not_disturb_on_outlined,
          size: 14,
          color: color,
        ),
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

  /// Poids d'un ingrédient, référentiels `nutrition_units` et
  /// `nutrition_ingredients` appliqués.
  ///
  /// Même arbitrage que le calcul serveur ([recipeNutrition.ts]) : quand
  /// l'ingrédient se compte à la pièce, le poids d'une pièce **du référentiel
  /// d'ingrédients** l'emporte — c'est la donnée la plus spécifique dont on
  /// dispose. L'app l'ignorait, si bien qu'elle continuait d'afficher le poids
  /// générique alors que le serveur calculait, lui, avec le bon.
  double? _ingredientWeight(
    RecipeIngredient ingredient,
    NutritionIngredientDoc? profile,
  ) {
    return resolveIngredientWeightGrams(
      overrides: ref.watch(nutritionUnitOverridesProvider),
      ingredientName: ingredient.name,
      qty: ingredient.qty,
      unit: ingredient.unit,
      ingredientOverride: profile == null
          ? null
          : IngredientWeightOverride(
              gramsPerPiece: profile.gramsPerPiece,
              gramsPerUnit: profile.gramsPerUnit,
            ),
    );
  }

  /// Document du référentiel qui porte les valeurs de cet ingrédient.
  NutritionIngredientDoc? _profileFor(
    RecipeIngredient ingredient,
    Map<String, NutritionIngredientDoc> nutritionById,
  ) {
    for (final candidate in buildIngredientLookupIds(ingredient.name)) {
      final doc = nutritionById[candidate];
      if (doc == null || !doc.hasUsableValues) continue;
      return doc;
    }
    return null;
  }

  /// Document du référentiel, valeurs nutritionnelles ou non.
  ///
  /// Distinct de [_profileFor] : un ingrédient peut connaître le poids de sa
  /// pièce sans avoir encore ses valeurs pour 100 g. Confondre les deux ferait
  /// perdre le poids exact au moment précis où il est le plus utile.
  NutritionIngredientDoc? _docFor(
    RecipeIngredient ingredient,
    Map<String, NutritionIngredientDoc> nutritionById,
  ) {
    for (final candidate in buildIngredientLookupIds(ingredient.name)) {
      final doc = nutritionById[candidate];
      if (doc != null) return doc;
    }
    return null;
  }

  /// Identifiants du référentiel à charger pour cette recette.
  ///
  /// Les mêmes variantes que celles interrogées par le serveur — strict,
  /// canonique, singulier — pour que les deux couches trouvent ou ne trouvent
  /// pas exactement les mêmes profils.
  String _profileIdsKey() => nutritionProfileIdsKey([
    for (final ingredient in widget.recipe.ingredients)
      ...buildIngredientLookupIds(ingredient.name),
  ]);

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
    final nutritionAsync = ref.watch(
      nutritionIngredientsByIdProvider(_profileIdsKey()),
    );
    final snapshot = widget.recipe.nutrition;
    // Conditionne les consignes de correction : elles pointent vers /admin,
    // que le routeur ferme à tous les autres rôles.
    final isAdmin = ref.watch(isAdminProvider);

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
            error: (e, _) => AppErrorState(
              error: e,
              title: 'Détail nutritionnel indisponible',
              compact: true,
            ),
            data: (nutritionById) {
              final unitInfos = ref.watch(nutritionUnitInfosProvider);
              // Le verdict « cette ligne en reprend une autre » vient du
              // serveur : il demande de lire la recette, pas de comparer des
              // noms. L'app se contente de le refléter.
              final duplicateNames = snapshot.duplicateIngredients
                  .map((name) => name.trim().toLowerCase())
                  .toSet();
              final rows = widget.recipe.ingredients
                  .where((ingredient) => ingredient.name.trim().isNotEmpty)
                  .map((ingredient) {
                    final profile = _profileFor(ingredient, nutritionById);
                    final doc = _docFor(ingredient, nutritionById);
                    final weight = _ingredientWeight(ingredient, doc);
                    return _NutritionIngredientRow(
                      notConsumed: doc?.notConsumed ?? false,
                      duplicate: duplicateNames.contains(
                        ingredient.name.trim().toLowerCase(),
                      ),
                      ingredient: ingredient,
                      canonicalId: normalizeIngredientCanonicalId(
                        ingredient.name,
                      ),
                      perIngredient: weight == null || profile == null
                          ? null
                          : _contributionOf(profile, weight),
                      weightGrams: weight,
                      weightEstimated: isUnitWeightEstimated(
                        infos: unitInfos,
                        unit: ingredient.unit,
                      ),
                    );
                  })
                  .toList(growable: false);
              // Seules les unités devinées restent signalées ligne à ligne :
              // le poids d'une « fine tranche » est une convention choisie par
              // l'IA, pas une donnée mesurée, et il change le résultat.
              final estimatedUnitCount = rows
                  .where((r) => !r.isMissing && r.weightEstimated)
                  .length;
              final missingCount = rows.where((r) => r.isMissing).length;
              final notConsumedCount = rows.where((r) => r.notConsumed).length;
              final duplicateCount = rows.where((r) => r.duplicate).length;

              // Le total ignore ce qui n'est pas mangé. Un litre de bain de
              // friture y pesait 8280 kcal et écrasait toute la recette.
              double? totalFor(String key) {
                var hasValue = false;
                var sum = 0.0;
                for (final row in rows) {
                  if (row.isExcluded) continue;
                  final value = row.perIngredient?[key];
                  if (value == null) continue;
                  hasValue = true;
                  sum += value;
                }
                return hasValue ? sum : null;
              }

              final knownWeight = rows
                  .where((row) => !row.isExcluded)
                  .fold<double>(0, (acc, row) => acc + (row.weightGrams ?? 0));

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
                                  // Le nom ne porte plus de marque « estimé ».
                                  // Presque toutes les valeurs du référentiel
                                  // viennent de l'IA : une pastille sur chaque
                                  // ligne ne distinguait rien et faisait passer
                                  // des ingrédients courants — un œuf, une pâte
                                  // feuilletée — pour des valeurs douteuses.
                                  // Seul ce qui prive réellement le calcul est
                                  // signalé ici ; la provenance vit en
                                  // administration, où on peut la corriger.
                                  DataCell(
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          row.ingredient.name,
                                          // Atténué plutôt que masqué : la
                                          // ligne reste lisible à sa place dans
                                          // la recette, mais on voit d'un coup
                                          // d'œil qu'elle ne compte pas.
                                          style: row.isExcluded
                                              ? TextStyle(
                                                  color: Theme.of(context)
                                                      .colorScheme
                                                      .onSurfaceVariant,
                                                  fontStyle: FontStyle.italic,
                                                )
                                              : null,
                                        ),
                                        if (row.isExcluded)
                                          _NotConsumedBadge(
                                            name: row.ingredient.name,
                                            duplicate: row.duplicate,
                                          ),
                                        if (row.isMissing)
                                          _MissingBadge(
                                            message: _missingExplanation(
                                              row,
                                              isAdmin: isAdmin,
                                            ),
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
                                            message: _estimatedUnitExplanation(
                                              row,
                                              isAdmin: isAdmin,
                                            ),
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
                                        style: row.isExcluded
                                            ? TextStyle(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                              )
                                            : null,
                                      ),
                                    ),
                                ],
                              ),
                        ],
                      ),
                    ),
                  ],
                  if (estimatedUnitCount > 0 ||
                      missingCount > 0 ||
                      notConsumedCount > 0 ||
                      duplicateCount > 0) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        if (estimatedUnitCount > 0)
                          _LegendEntry(
                            icon: Icons.auto_awesome,
                            color: Theme.of(context).colorScheme.tertiary,
                            label:
                                '$estimatedUnitCount unité(s) au poids estimé',
                          ),
                        if (notConsumedCount > 0)
                          _LegendEntry(
                            icon: Icons.do_not_disturb_on_outlined,
                            color: Theme.of(context).colorScheme.outline,
                            label:
                                '$notConsumedCount ingrédient(s) non consommé(s), hors total',
                          ),
                        if (duplicateCount > 0)
                          _LegendEntry(
                            icon: Icons.content_copy_outlined,
                            color: Theme.of(context).colorScheme.outline,
                            label:
                                '$duplicateCount ligne(s) déjà comptée(s) plus haut',
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
