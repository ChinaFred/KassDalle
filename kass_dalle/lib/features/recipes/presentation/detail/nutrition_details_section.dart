import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/nutrition_units_reference.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../domain/nutrition_contributions.dart';
import '../../domain/recipe.dart';
import '../recipe_providers.dart';
import '../../../../core/widgets/app_states.dart';
import '../../../../core/theme/app_icon_size.dart';

/// Libellé français de l'état de couverture renvoyé par le backend.
///
/// Le backend parle en `full` / `partial` / `low` ; ces valeurs techniques
/// s'affichaient telles quelles à l'utilisateur.
String _coverageStateLabel(String state) => switch (state) {
  'full' => 'Calcul complet',
  'partial' => 'Calcul partiel',
  'low' => 'Calcul incomplet',
  'failed' => 'Calcul en échec',
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
  'failed' =>
    'Le calcul n\'a pas abouti. Il repartira à la prochaine modification des '
        'ingrédients, ou depuis l\'écran d\'administration.',
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

/// Pourquoi cet ingrédient ne contribue à rien : poids inconnu, valeurs
/// inconnues, ou les deux. Le distinguer évite de chercher au mauvais endroit —
/// le poids se corrige dans les unités, les valeurs dans les ingrédients.
///
/// Le chemin de correction n'est donné qu'aux administrateurs : le routeur
/// renvoie tout autre rôle à l'accueil dès qu'il touche `/admin`. Envoyer un
/// lecteur vers « Admin → Unités », c'est lui demander d'ouvrir une porte
/// fermée. Les autres rôles apprennent ce qui manque, pas où le réparer.
String _missingExplanation(
  NutritionContributionRow row, {
  required bool isAdmin,
}) {
  if (row.weightGrams == null) {
    // Ligne nue : la recette n'écrit ni nombre ni unité, et la fiche de
    // l'ingrédient ne porte pas encore de portion usuelle. Dire « la quantité
    // «  » ne se convertit pas » renverrait à un texte vide.
    final bare =
        row.ingredient.qty.trim().isEmpty && row.ingredient.unit.trim().isEmpty;
    if (bare) {
      final base =
          'La recette ne donne aucune quantité pour « ${row.ingredient.name} » '
          'et sa portion usuelle n\'est pas encore estimée : il est exclu du '
          'total.';
      return isAdmin
          ? '$base Relancez la reprise de la nutrition depuis Admin → Backfills.'
          : base;
    }
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

/// Dit d'où sort une ligne que personne n'a écrite dans la recette.
///
/// Sans cette explication, un lecteur voit apparaître 55 g de lipides sortis de
/// nulle part — et un chiffre inexpliqué se lit comme une erreur.
String _absorbedOilExplanation(RecipeAbsorbedOil oil) {
  final pct = (oil.absorptionRatio * 100).toStringAsFixed(0);
  final base =
      'Huile absorbée pendant la friture, estimée à $pct % du poids des '
      'ingrédients frits (${oil.friedWeightG.toStringAsFixed(0)} g). '
      'Le bain lui-même reste hors du total : on ne mange pas l\'huile de '
      'friture, mais ce qu\'on y plonge en ressort plus gras.';
  if (!oil.capped) return base;
  return '$base\n\nPlafonnée à la quantité d\'huile déclarée par la recette : '
      'l\'absorption ne peut pas dépasser le bain.';
}

/// Ligne dérivée : l'huile que la friture a fait passer du bain à l'assiette.
///
/// [nested] la place sous le bain qui l'a produite — elle se contente alors
/// d'annoncer ce qu'elle en retient. Isolée, elle doit se nommer entièrement.
DataRow _absorbedOilDataRow(
  BuildContext context,
  RecipeAbsorbedOil absorbedOil, {
  required bool nested,
}) {
  final style = TextStyle(
    fontStyle: FontStyle.italic,
    color: Theme.of(context).colorScheme.tertiary,
  );
  return DataRow(
    cells: [
      DataCell(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              nested
                  ? '   ↳ dont absorbée'
                  : '${absorbedOil.sourceName} absorbée',
              style: style,
            ),
            _EstimationBadge(message: _absorbedOilExplanation(absorbedOil)),
          ],
        ),
      ),
      DataCell(Text('${absorbedOil.grams.toStringAsFixed(0)} g', style: style)),
      for (final metric in kNutritionMetricKeys)
        DataCell(
          Text(
            formatNutritionValue(
              absorbedOil.contribution[metric.$1],
              integer: metric.$1 == 'kcal',
            ),
            style: style,
          ),
        ),
    ],
  );
}

/// Ce que vaut la ligne, faute de quantité écrite dans la recette.
String _assumedQuantityLabel(NutritionContributionRow row) =>
    nutritionAssumedUnitPhrase(row);

/// Même règle pour le poids estimé par l'IA.
String _estimatedUnitExplanation(
  NutritionContributionRow row, {
  required bool isAdmin,
}) {
  final base =
      'Poids d\'une unité « ${row.ingredient.unit} » estimé par l\'IA : '
      'cette unité ne correspond à aucune mesure standard.';
  return isAdmin ? '$base Corrigeable depuis Admin → Unités.' : base;
}

IconData _legendIcon(NutritionLegendKind kind) => switch (kind) {
  NutritionLegendKind.absorbedOil => Icons.water_drop_outlined,
  NutritionLegendKind.assumedQuantity => Icons.grain,
  NutritionLegendKind.estimatedUnit => Icons.auto_awesome_outlined,
  NutritionLegendKind.notConsumed => Icons.do_not_disturb_on_outlined,
  NutritionLegendKind.duplicate => Icons.content_copy_outlined,
  NutritionLegendKind.missing => Icons.help_outline,
};

Color _legendColor(BuildContext context, NutritionLegendKind kind) {
  final scheme = Theme.of(context).colorScheme;
  return switch (kind) {
    NutritionLegendKind.absorbedOil ||
    NutritionLegendKind.assumedQuantity ||
    NutritionLegendKind.estimatedUnit => scheme.tertiary,
    NutritionLegendKind.notConsumed ||
    NutritionLegendKind.duplicate => scheme.outline,
    NutritionLegendKind.missing => scheme.error,
  };
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
        Icon(icon, size: AppIconSize.inline, color: color),
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
        child: Icon(
          Icons.smart_toy_outlined,
          size: AppIconSize.inline,
          color: color,
        ),
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
          size: AppIconSize.inline,
          color: color,
        ),
      ),
    );
  }
}

/// Signale une quantité que la recette ne donnait pas.
///
/// Distinct de la pastille d'estimation : ce n'est pas l'IA qui a deviné un
/// poids, c'est le programme qui a appliqué une convention d'écriture. Sans
/// cette marque, 0,5 g apparaîtrait comme un chiffre de la recette.
class _AssumedQuantityBadge extends StatelessWidget {
  final String unitLabel;

  const _AssumedQuantityBadge({required this.unitLabel});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.tertiary;
    return Tooltip(
      message:
          'La recette ne donne pas de quantité : comptée pour $unitLabel. '
          'Sans cela, cet ingrédient sortirait entièrement du calcul.',
      child: Padding(
        padding: const EdgeInsets.only(left: 4),
        child: Icon(Icons.grain, size: AppIconSize.inline, color: color),
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
        child: Icon(Icons.help_outline, size: AppIconSize.inline, color: color),
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

  @override
  Widget build(BuildContext context) {
    final nutritionAsync = ref.watch(
      nutritionIngredientsByIdProvider(
        nutritionProfileIdsKey(recipeNutritionProfileIds(widget.recipe)),
      ),
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
              // Le tableau se construit dans le domaine : le PDF exporté
              // dessine le même, et deux calculs séparés finiraient par donner
              // deux totaux à la même recette.
              final table = buildNutritionContributions(
                recipe: widget.recipe,
                nutritionById: nutritionById,
                unitOverrides: ref.watch(nutritionUnitOverridesProvider),
                unitInfos: ref.watch(nutritionUnitInfosProvider),
              );
              final rows = table.rows;

              // L'huile absorbée n'est pas un ingrédient : elle n'a pas de
              // ligne dans la recette, mais elle finit dans l'assiette. Le
              // serveur la calcule ; le tableau, qui refait ses totaux depuis
              // les lignes, doit la compter comme elle — sinon le TOTAL affiché
              // ici contredirait les calories par portion affichées au-dessus.
              final absorbedOil = table.absorbedOil;
              final knownWeight = table.knownWeight;

              // Division faite ici, pour les parts affichées : le bloc stocké
              // est calculé aux portions de la recette et ne bouge pas.
              final perPortion = snapshot.perPortionFor(
                widget.selectedPortions,
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
                            '${formatNutritionValue(perPortion['kcal'], integer: true)} kcal',
                      ),
                      _MiniMetric(
                        label: 'Protéines',
                        value:
                            '${formatNutritionValue(perPortion['protein_g'])} g',
                      ),
                      _MiniMetric(
                        label: 'Glucides',
                        value:
                            '${formatNutritionValue(perPortion['carbs_g'])} g',
                      ),
                      _MiniMetric(
                        label: 'Lipides',
                        value: '${formatNutritionValue(perPortion['fat_g'])} g',
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
                              'Apports par ingrédient',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                          ),
                          Icon(
                            _showContributionTable
                                ? Icons.expand_less
                                : Icons.expand_more,
                            size: AppIconSize.small,
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
                          DataColumn(label: Text('Ingrédient')),
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
                                        size: AppIconSize.inline,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              for (final metric in kNutritionMetricKeys)
                                DataCell(
                                  Text(
                                    formatNutritionValue(
                                      table.totalFor(metric.$1),
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
                            for (final row in rows) ...[
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
                                        Text(nutritionQuantityCellText(row)),
                                        if (row.quantityAssumed)
                                          _AssumedQuantityBadge(
                                            unitLabel: _assumedQuantityLabel(
                                              row,
                                            ),
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
                                  for (final metric in kNutritionMetricKeys)
                                    DataCell(
                                      Text(
                                        formatNutritionValue(
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
                              // L'huile absorbée se range sous le bain dont
                              // elle sort. Les deux lignes se lisent alors
                              // comme une seule idée : on jette le litre, on
                              // mange les 55 g. Reléguée en fin de tableau,
                              // elle ressemblait à un ingrédient oublié.
                              if (absorbedOil != null &&
                                  table.isAbsorbedOilSource(row))
                                _absorbedOilDataRow(
                                  context,
                                  absorbedOil,
                                  nested: true,
                                ),
                            ],
                          // Le bain n'est pas listé, ou sous un nom que le
                          // serveur n'a pas retenu : la ligne dérivée ferme le
                          // tableau plutôt que de disparaître.
                          if (_showIngredientDetails &&
                              absorbedOil != null &&
                              table.hasOrphanAbsorbedOil)
                            _absorbedOilDataRow(
                              context,
                              absorbedOil,
                              nested: false,
                            ),
                        ],
                      ),
                    ),
                  ],
                  if (table.needsLegend) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        // Les textes viennent du domaine : le PDF exporté
                        // imprime la même légende, et deux formulations
                        // décriraient différemment le même tableau.
                        for (final entry in nutritionLegendEntries(table))
                          _LegendEntry(
                            icon: _legendIcon(entry.kind),
                            color: _legendColor(context, entry.kind),
                            label: entry.label,
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
