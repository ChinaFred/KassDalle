import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/utils/recipe_portion_scaler.dart';
import '../../recipes/domain/recipe.dart';
import '../domain/meal_storage_rules.dart';
import '../domain/planned_meal.dart';
import '../../../core/theme/app_icon_size.dart';

// ── Helpers d'agrégation d'ingrédients ──────────────────────────────────────────

String _normIngKey(String name) {
  var s = name
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
      .trim();
  return s
      .split(' ')
      .map(
        (w) =>
            w.endsWith('s') && w.length > 2 ? w.substring(0, w.length - 1) : w,
      )
      .join(' ');
}

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
    final e = double.tryParse(existingQty.replaceAll(',', '.').trim());
    final n = double.tryParse(newQty.replaceAll(',', '.').trim());
    if (e != null && n != null) {
      final total = e + n;
      return total == total.truncateToDouble()
          ? total.toInt().toString()
          : total.toStringAsFixed(1);
    }
  }
  if (existingQty.isEmpty) return newQty;
  if (newQty.isEmpty) return existingQty;
  return '$existingQty + $newQty';
}

/// Agrège les ingrédients de plusieurs recettes et retourne :
/// - la liste dédoublonnée avec quantités fusionnées,
/// - une map `{nom_canonique → "Recette A · Recette B"}` pour l'affichage.
({List<RecipeIngredient> ingredients, Map<String, String> sources})
planningAggregateIngredients(List<Recipe> recipes) {
  final result = <RecipeIngredient>[];
  final keyToIdx = <String, int>{};
  final Map<String, List<String>> sourceLists = {};
  for (final recipe in recipes) {
    for (final ing in recipe.ingredients) {
      if (ing.name.trim().isEmpty) continue;
      final key = _normIngKey(ing.name);
      (sourceLists[key] ??= []).add(recipe.titre);
      if (keyToIdx.containsKey(key)) {
        final idx = keyToIdx[key]!;
        final ex = result[idx];
        result[idx] = RecipeIngredient(
          name: ex.name,
          qty: _mergeQty(ex.qty, ing.qty, ex.unit, ing.unit),
          unit: ex.unit.isNotEmpty ? ex.unit : ing.unit,
          category: ex.category,
        );
      } else {
        keyToIdx[key] = result.length;
        result.add(
          RecipeIngredient(
            name: ing.name,
            qty: ing.qty,
            unit: ing.unit,
            category: ing.category,
          ),
        );
      }
    }
  }
  final sources = <String, String>{};
  for (final e in sourceLists.entries) {
    final idx = keyToIdx[e.key];
    if (idx == null) continue;
    final canonicalName = result[idx].name;
    final uniqueTitles = e.value.toSet().toList();
    sources[canonicalName] = uniqueTitles.join(' \u00b7 ');
  }
  return (ingredients: result, sources: sources);
}

/// Agrège les produits d'achat de plusieurs recettes et retourne :
/// - la liste consolidée par produit (même nom+unité → quantités additionnées),
/// - une map `{nom_produit → "Recette A · Recette B"}` pour l'affichage.
///
/// Utilise [shoppingProducts] si disponible, sinon construit des produits
/// depuis les ingrédients bruts (fallback pour les anciennes recettes).
({List<RecipeShoppingProduct> products, Map<String, String> sources})
planningAggregateProducts(List<Recipe> recipes) {
  String normKey(String name, String unit) {
    String norm(String s) => s
        .toLowerCase()
        .replaceAll(RegExp(r'[àâ]'), 'a')
        .replaceAll(RegExp(r'[éèêë]'), 'e')
        .replaceAll(RegExp(r'[îï]'), 'i')
        .replaceAll(RegExp(r'[ôö]'), 'o')
        .replaceAll(RegExp(r'[ùûü]'), 'u')
        .replaceAll('ç', 'c')
        .trim();
    return '${norm(unit)}|${norm(name)}';
  }

  String mergeQty(String a, String b, String unit1, String unit2) {
    final sameUnit =
        unit1.toLowerCase() == unit2.toLowerCase() ||
        unit1.isEmpty ||
        unit2.isEmpty;
    if (sameUnit) {
      final va = double.tryParse(a.replaceAll(',', '.').trim());
      final vb = double.tryParse(b.replaceAll(',', '.').trim());
      if (va != null && vb != null) {
        final total = va + vb;
        return total == total.truncateToDouble()
            ? total.toInt().toString()
            : total.toStringAsFixed(1);
      }
    }
    if (a.isEmpty) return b;
    if (b.isEmpty) return a;
    return '$a + $b';
  }

  final result = <RecipeShoppingProduct>[];
  final keyToIdx = <String, int>{};
  final Map<String, List<String>> sourceLists = {};

  for (final recipe in recipes) {
    // Utilise les produits pre-calculés si disponibles, sinon fallback ingrédients
    final products = recipe.shoppingProducts.isNotEmpty
        ? recipe.shoppingProducts
        : recipe.ingredients
              .map(
                (i) => RecipeShoppingProduct(
                  name: i.name,
                  qty: i.qty,
                  unit: i.unit,
                ),
              )
              .toList(growable: false);

    for (final p in products) {
      if (p.name.trim().isEmpty) continue;
      final key = normKey(p.name, p.unit);
      (sourceLists[key] ??= []).add(recipe.titre);
      if (keyToIdx.containsKey(key)) {
        final idx = keyToIdx[key]!;
        final ex = result[idx];
        result[idx] = RecipeShoppingProduct(
          name: ex.name,
          qty: mergeQty(ex.qty, p.qty, ex.unit, p.unit),
          unit: ex.unit.isNotEmpty ? ex.unit : p.unit,
        );
      } else {
        keyToIdx[key] = result.length;
        result.add(p);
      }
    }
  }

  final sources = <String, String>{};
  for (final e in sourceLists.entries) {
    final idx = keyToIdx[e.key];
    if (idx == null) continue;
    sources[result[idx].name] = e.value.toSet().join(' \u00b7 ');
  }

  return (products: result, sources: sources);
}

Recipe planningScaleRecipeForMeal({
  required Recipe recipe,
  int? basePortions,
  int? targetPortions,
}) {
  final effectiveBase = basePortions ?? recipe.portions;
  final effectiveTarget = targetPortions ?? effectiveBase;
  if (effectiveBase == null ||
      effectiveTarget == null ||
      effectiveBase <= 0 ||
      effectiveTarget <= 0 ||
      effectiveBase == effectiveTarget) {
    return recipe;
  }

  final factor = portionScaleFactor(
    basePortions: effectiveBase,
    targetPortions: effectiveTarget,
  );

  return recipe.copyWith(
    portions: effectiveTarget,
    ingredients: scaleRecipeIngredients(recipe.ingredients, factor),
    shoppingProducts: scaleShoppingProducts(recipe.shoppingProducts, factor),
  );
}

// ── Widgets ────────────────────────────────────────────────────────────────────

class PlanningDayHeader extends StatelessWidget {
  final DateTime day;
  final bool isToday;
  final bool isPast;

  const PlanningDayHeader({
    super.key,
    required this.day,
    required this.isToday,
    required this.isPast,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = isToday
        ? "Aujourd'hui"
        : DateFormat('EEEE d MMMM', 'fr').format(day);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: isToday
              ? theme.colorScheme.primary
              : isPast
              ? theme.colorScheme.onSurfaceVariant
              : theme.colorScheme.onSurface,
          fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    );
  }
}

class PlanningMealTile extends StatelessWidget {
  final PlannedMeal meal;
  final bool isPast;
  final bool aiLoading;
  final VoidCallback? onTap;
  final bool isWide;
  final VoidCallback onDelete;
  final VoidCallback onChangeRecipe;
  final VoidCallback onClearRecipe;
  final VoidCallback onSuggestWithAI;

  /// Produit — ou réaffiche — le conseil de conservation de la recette.
  final VoidCallback onStorageAdvice;
  final VoidCallback onTimeChanged;
  final VoidCallback onExportToCalendar;

  const PlanningMealTile({
    super.key,
    required this.meal,
    required this.isPast,
    required this.aiLoading,
    required this.isWide,
    required this.onDelete,
    required this.onChangeRecipe,
    required this.onClearRecipe,
    required this.onSuggestWithAI,
    required this.onStorageAdvice,
    required this.onTimeChanged,
    required this.onExportToCalendar,
    this.onTap,
  });

  /// Sous-titre du repas, augmenté de la consigne de conservation quand le
  /// plat est préparé un autre jour.
  ///
  /// La consigne est calculée, pas générée : elle s'affiche toujours, même si
  /// la recette n'a jamais reçu de conseil de conservation.
  /// Le « pourquoi ce plat, ce jour-là », quand l'IA l'a écrit.
  ///
  /// Il porte l'icône de ce qui vient d'une machine — la même partout dans
  /// l'application —, et non celle qui sert à en demander.
  Widget? _buildWhy(ThemeData theme) {
    final why = meal.justification?.trim();
    if (why == null || why.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.smart_toy_outlined,
            size: AppIconSize.badge,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              why,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget? _buildSubtitle(ThemeData theme, String? subtitle) {
    final why = _buildWhy(theme);
    final prep = meal.prepDate;
    if (prep == null) {
      if (subtitle == null && why == null) return null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [if (subtitle != null) Text(subtitle), ?why],
      );
    }

    final daysAhead = mealStorageDaysAhead(
      prepDate: prep,
      mealDate: meal.plannedAt,
    );
    if (daysAhead <= 0) {
      if (subtitle == null && why == null) return null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [if (subtitle != null) Text(subtitle), ?why],
      );
    }

    final mode = mealStorageMode(daysAhead);
    final color = mode == MealStorageMode.freezer
        ? theme.colorScheme.tertiary
        : theme.colorScheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (subtitle != null) Text(subtitle),
        const SizedBox(height: 2),
        Row(
          children: [
            Icon(
              mode == MealStorageMode.freezer
                  ? Icons.ac_unit_outlined
                  : Icons.kitchen_outlined,
              size: AppIconSize.badge,
              color: color,
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                'Préparé le ${DateFormat('EEEE d', 'fr').format(prep)} · '
                '${mealStorageLabel(mode).toLowerCase()}',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        ?why,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final timeStr = DateFormat('HH:mm').format(meal.plannedAt);

    String? subtitle;
    if ((meal.prepMinutes ?? 0) > 0 || (meal.cookMinutes ?? 0) > 0) {
      final parts = <String>[];
      if ((meal.prepMinutes ?? 0) > 0) parts.add('${meal.prepMinutes}min prép');
      if ((meal.cookMinutes ?? 0) > 0) {
        parts.add('${meal.cookMinutes}min cuisson');
      }
      if ((meal.targetPortions ?? 0) > 0) {
        parts.add('${meal.targetPortions} parts');
      }
      subtitle = parts.join(' \u00b7 ');
    } else if (meal.durationMinutes > 0) {
      subtitle = (meal.targetPortions ?? 0) > 0
          ? '${meal.durationMinutes} min · ${meal.targetPortions} parts'
          : '${meal.durationMinutes} min';
    } else if ((meal.targetPortions ?? 0) > 0) {
      subtitle = '${meal.targetPortions} parts';
    }

    return Opacity(
      opacity: isPast ? 0.6 : 1.0,
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: ListTile(
          leading: Tooltip(
            message: 'Modifier l\'heure',
            child: InkWell(
              onTap: onTimeChanged,
              borderRadius: BorderRadius.circular(24),
              child: CircleAvatar(
                backgroundColor: isPast
                    ? theme.colorScheme.surfaceContainerHighest
                    : theme.colorScheme.primaryContainer,
                child: Text(
                  timeStr,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: isPast
                        ? theme.colorScheme.onSurfaceVariant
                        : theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
          ),
          title: Text(
            meal.recipeTitre,
            style: isPast
                ? TextStyle(color: theme.colorScheme.onSurfaceVariant)
                : null,
          ),
          subtitle: _buildSubtitle(theme, subtitle),
          trailing: aiLoading
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isWide)
                      IconButton(
                        // L'infobulle du bouton remplace le `Tooltip` qui
                        // l'enveloppait : elle dit la même chose et, elle,
                        // s'annonce aussi au lecteur d'écran.
                        tooltip: 'Exporter ce repas vers le calendrier',
                        icon: const Icon(
                          Icons.upload_outlined,
                          size: AppIconSize.small,
                        ),
                        onPressed: onExportToCalendar,
                        visualDensity: VisualDensity.compact,
                      ),
                    PopupMenuButton<PlanningMealAction>(
                      iconSize: AppIconSize.small,
                      onSelected: (action) {
                        switch (action) {
                          case PlanningMealAction.suggestWithAI:
                            onSuggestWithAI();
                          case PlanningMealAction.changeRecipe:
                            onChangeRecipe();
                          case PlanningMealAction.clearRecipe:
                            onClearRecipe();
                          case PlanningMealAction.storageAdvice:
                            onStorageAdvice();
                          case PlanningMealAction.exportToCalendar:
                            onExportToCalendar();
                          case PlanningMealAction.delete:
                            onDelete();
                        }
                      },
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: PlanningMealAction.suggestWithAI,
                          child: ListTile(
                            leading: Icon(Icons.auto_awesome_outlined),
                            title: Text('Suggestion IA'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuItem(
                          value: PlanningMealAction.changeRecipe,
                          child: ListTile(
                            leading: Icon(Icons.swap_horiz_outlined),
                            title: Text('Changer la recette'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuItem(
                          value: PlanningMealAction.clearRecipe,
                          child: ListTile(
                            leading: Icon(
                              Icons.radio_button_unchecked_outlined,
                            ),
                            title: Text('Remettre à blanc'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        if (meal.recipeId != null)
                          const PopupMenuItem(
                            value: PlanningMealAction.storageAdvice,
                            child: ListTile(
                              leading: Icon(Icons.kitchen_outlined),
                              title: Text('Conservation et réchauffage'),
                              contentPadding: EdgeInsets.zero,
                            ),
                          ),
                        const PopupMenuItem(
                          value: PlanningMealAction.exportToCalendar,
                          child: ListTile(
                            leading: Icon(Icons.calendar_month_outlined),
                            title: Text('Exporter vers Calendar'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuDivider(),
                        const PopupMenuItem(
                          value: PlanningMealAction.delete,
                          child: ListTile(
                            leading: Icon(Icons.delete_outline),
                            title: Text('Supprimer'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
          onTap: onTap,
        ),
      ),
    );
  }
}

enum PlanningMealAction {
  suggestWithAI,
  changeRecipe,
  clearRecipe,
  storageAdvice,
  exportToCalendar,
  delete,
}

// ── Recipe picker ─────────────────────────────────────────────────────────────

class PlanningRecipePickerSheet extends StatefulWidget {
  final List<Recipe> recipes;

  /// Recettes déjà écartées du repas : masquées, sauf demande expresse.
  final Set<String> dismissedRecipeIds;

  const PlanningRecipePickerSheet({
    super.key,
    required this.recipes,
    this.dismissedRecipeIds = const {},
  });

  @override
  State<PlanningRecipePickerSheet> createState() =>
      _PlanningRecipePickerSheetState();
}

class _PlanningRecipePickerSheetState extends State<PlanningRecipePickerSheet> {
  String _query = '';
  bool _showDismissed = false;

  bool _isDismissed(Recipe r) => widget.dismissedRecipeIds.contains(r.id);

  int get _dismissedCount => widget.recipes.where(_isDismissed).length;

  List<Recipe> get _filtered {
    final q = _query.toLowerCase();
    return widget.recipes.where((r) {
      if (!_showDismissed && _isDismissed(r)) return false;
      return q.isEmpty || r.titre.toLowerCase().contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: TextField(
                autofocus: true,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Rechercher ou saisir un nom libre\u2026',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            if (_dismissedCount > 0)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FilterChip(
                    label: Text('Écartées pour ce repas ($_dismissedCount)'),
                    selected: _showDismissed,
                    onSelected: (v) => setState(() => _showDismissed = v),
                  ),
                ),
              ),
            Expanded(
              child: ListView.builder(
                controller: scrollController,
                itemCount: _filtered.length + 1,
                itemBuilder: (_, i) {
                  if (i == 0) {
                    final name = _query.trim();
                    if (name.isEmpty) {
                      return ListTile(
                        leading: const CircleAvatar(
                          child: Icon(
                            Icons.edit_outlined,
                            size: AppIconSize.small,
                          ),
                        ),
                        title: const Text('Saisir un nom libre\u2026'),
                        subtitle: const Text('Repas sans recette liée'),
                        onTap: () async {
                          final ctrl = TextEditingController();
                          final result = await showDialog<String>(
                            context: context,
                            builder: (dCtx) => AlertDialog(
                              title: const Text('Nom du repas'),
                              content: TextField(
                                controller: ctrl,
                                autofocus: true,
                                decoration: const InputDecoration(
                                  hintText: 'ex: Tartines, Restes\u2026',
                                ),
                                onSubmitted: (v) =>
                                    Navigator.pop(dCtx, v.trim()),
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(dCtx),
                                  child: const Text('Annuler'),
                                ),
                                FilledButton(
                                  onPressed: () =>
                                      Navigator.pop(dCtx, ctrl.text.trim()),
                                  child: const Text('Valider'),
                                ),
                              ],
                            ),
                          );
                          ctrl.dispose();
                          if (result == null || result.isEmpty) return;
                          final freeRecipe = Recipe(
                            id: '',
                            titre: result,
                            langue: 'fr',
                            rawCooklang: '',
                            imageUrls: const [],
                            reviewStatus: ReviewStatus.validated,
                            tags: const RecipeTags(),
                            ingredientsIndex: const [],
                            createdBy: '',
                            createdAt: DateTime.now(),
                            updatedAt: DateTime.now(),
                          );
                          if (ctx.mounted) Navigator.pop(ctx, freeRecipe);
                        },
                      );
                    }
                    return ListTile(
                      leading: const CircleAvatar(
                        child: Icon(
                          Icons.edit_outlined,
                          size: AppIconSize.small,
                        ),
                      ),
                      title: Text('\u00ab $name \u00bb'),
                      subtitle: const Text('Repas libre (sans recette liée)'),
                      onTap: () {
                        final freeRecipe = Recipe(
                          id: '',
                          titre: name,
                          langue: 'fr',
                          rawCooklang: '',
                          imageUrls: const [],
                          reviewStatus: ReviewStatus.validated,
                          tags: const RecipeTags(),
                          ingredientsIndex: const [],
                          createdBy: '',
                          createdAt: DateTime.now(),
                          updatedAt: DateTime.now(),
                        );
                        Navigator.pop(ctx, freeRecipe);
                      },
                    );
                  }
                  final ri = i - 1;
                  if (ri >= _filtered.length) return const SizedBox.shrink();
                  final r = _filtered[ri];
                  final prep = r.tags.prepTime;
                  final cook = r.tags.cookTime;
                  final times = [
                    if (prep != null) '${prep}min prép',
                    if (cook != null) '${cook}min cuisson',
                  ].join(' + ');
                  final subtitle = [
                    if (times.isNotEmpty) times,
                    if (_isDismissed(r)) 'écartée pour ce repas',
                  ].join(' · ');
                  return ListTile(
                    title: Text(r.titre),
                    subtitle: subtitle.isNotEmpty ? Text(subtitle) : null,
                    onTap: () => Navigator.pop(ctx, r),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
