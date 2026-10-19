import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/utils/recipe_portion_scaler.dart';
import '../../../core/utils/ingredient_display.dart';
import '../../../core/utils/shopping_products.dart';
import '../../recipes/domain/recipe.dart';
import '../domain/meal_choice_source.dart';
import '../domain/meal_component.dart';
import '../domain/meal_storage_rules.dart';
import '../domain/planned_meal.dart';
import '../domain/side_chooser.dart';
import 'batch_planning_widgets.dart' show MealOriginLine;
import '../../../core/theme/app_icon_size.dart';
import '../../../core/theme/app_icons.dart';

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

/// Un produit qui ne vient pas d'une recette — une garniture d'un repas — et
/// d'où il vient, pour l'affichage.
typedef PlanningExtraProduct = ({RecipeShoppingProduct product, String source});

/// Agrège les produits d'achat de plusieurs recettes et retourne :
/// - la liste consolidée par produit et famille d'unité — même produit,
///   unités convertibles entre elles → quantités additionnées ; un comptage et
///   un poids restent deux entrées sous un même nom (`mergeShoppingProducts`) ;
/// - une map `{nom_produit → "Recette A (200 g) · Recette B (300 g)"}` : d'où
///   vient chaque ligne, et pour combien.
///
/// Utilise [shoppingProducts] si disponible, sinon construit des produits
/// depuis les ingrédients bruts (fallback pour les anciennes recettes).
/// [extras] : les garnitures des repas, déjà multipliées par les parts ; elles
/// se fondent dans les mêmes lignes — le riz d'une garniture et le riz d'une
/// recette font une seule ligne de courses.
({List<RecipeShoppingProduct> products, Map<String, String> sources})
planningAggregateProducts(
  List<Recipe> recipes, {
  List<PlanningExtraProduct> extras = const [],
}) {
  final batches = <({List<RecipeShoppingProduct> products, String source})>[
    for (final recipe in recipes)
      (
        // Utilise les produits pré-calculés si disponibles, sinon les
        // ingrédients bruts (anciennes recettes).
        products: recipe.shoppingProducts.isNotEmpty
            ? recipe.shoppingProducts
            : recipe.ingredients
                  .map(
                    (i) => RecipeShoppingProduct(
                      name: i.name,
                      qty: i.qty,
                      unit: i.unit,
                    ),
                  )
                  .toList(growable: false),
        source: recipe.titre,
      ),
    for (final e in extras) (products: [e.product], source: e.source),
  ];

  // Toutes les lignes dans l'ordre, et pour chaque produit ce que chaque
  // source lui apporte — pour dire sous la ligne « Curry (400 ml) ».
  final entries = <RecipeShoppingProduct>[];
  final contributions = <String, Map<String, List<RecipeShoppingProduct>>>{};
  for (final batch in batches) {
    for (final p in batch.products) {
      if (p.name.trim().isEmpty) continue;
      entries.add(p);
      final bySource = contributions.putIfAbsent(
        shoppingProductKey(p.name),
        () => {},
      );
      bySource.putIfAbsent(batch.source, () => []).add(p);
    }
  }

  final products = mergeShoppingProducts(entries);
  final sources = <String, String>{};
  for (final product in products) {
    if (sources.containsKey(product.name)) continue;
    final bySource = contributions[shoppingProductKey(product.name)];
    if (bySource == null) continue;
    sources[product.name] = bySource.entries
        .map((e) => _describeContribution(e.key, e.value))
        .join(' · ');
  }

  return (products: products, sources: sources);
}

/// « Curry de poulet (400 ml) » — la source, et ce qu'elle apporte au produit.
///
/// Les quantités d'une même source s'additionnent comme sur la ligne ; sans
/// quantité lisible, la source seule.
String _describeContribution(String source, List<RecipeShoppingProduct> given) {
  final quantities = mergeShoppingProducts(given)
      .map((p) => formatQuantityOnly(qty: p.qty, unit: p.unit))
      .where((q) => q.isNotEmpty)
      .join(' + ');
  return quantities.isEmpty ? source : '$source ($quantities)';
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

/// Un repas du planning.
///
/// Chaque action est facultative : une action absente n'apparaît pas. Le
/// lecteur ne garde sur ses repas antérieurs que « Supprimer ».
///
/// [readOnly] : le repas d'un autre membre, dans un planning partagé avec
/// l'utilisateur. Ni menu, ni heure modifiable, ni retrait d'accompagnement,
/// ni export, et pas de ligne d'origine du choix. Ces champs restent lisibles
/// dans le document par l'audience du planning : ne pas les afficher n'est
/// pas une protection (décision provisoire, TechnicalRequirements §3.7).
class PlanningMealTile extends StatelessWidget {
  final PlannedMeal meal;
  final bool isPast;
  final bool aiLoading;
  final VoidCallback? onTap;
  final bool isWide;
  final VoidCallback? onDelete;
  final VoidCallback? onChangeRecipe;
  final VoidCallback? onClearRecipe;

  /// « Autre suggestion » : la recette suivante de la liste classée, sans IA.
  final VoidCallback? onOtherSuggestion;
  final VoidCallback? onReschedule;

  /// Ouvre l'éditeur « Composer le repas » : menu ⋮, ou appui sur la ligne
  /// « Il manque » ou « Apports du plat inconnus ».
  final VoidCallback? onCompose;

  /// « Compléter » : ouvre le choix d'un accompagnement filtré sur ce qui
  /// manque.
  final ValueChanged<SideNeed>? onComplete;

  /// Ce que le plat et ses accompagnements apportent, calculé par l'écran
  /// depuis la recette du plat. `null` tant qu'elle n'est pas lue : rien ne
  /// s'affiche. « Plat complet » ne s'affiche pas sur la tuile.
  final DishSideStatus? sideStatus;

  /// Retire un accompagnement déjà posé, auto ou choisi à la main.
  final ValueChanged<MealComponent>? onRemoveComponent;

  /// Produit — ou réaffiche — le conseil de conservation de la recette.
  final VoidCallback? onStorageAdvice;
  final VoidCallback? onTimeChanged;
  final VoidCallback? onExportToCalendar;

  /// « Ajouter aux courses » : les produits du repas vont dans le panier de
  /// celui qui regarde, sur un repas en lecture seule aussi. Null : l'action
  /// n'existe pas (repas passé, recette illisible, repas libre sans
  /// accompagnement) — absente, pas grisée.
  final VoidCallback? onAddToShopping;

  /// Ouvre la fiche d'un composant qui est une recette — un accompagnement,
  /// une entrée, un dessert du corpus. Une garniture n'a pas de fiche.
  final ValueChanged<MealComponent>? onComponentTap;

  /// Repas d'un autre membre : lecture seule (voir la classe).
  final bool readOnly;

  /// Prénom du propriétaire, en première ligne du sous-titre — « Vous » pour
  /// ses propres repas. Null quand seul « Mon planning » est affiché. Pour un
  /// repas de groupe ([ownerIsGroup]) : le nom du groupe.
  final String? ownerName;

  /// [ownerName] est le nom d'un groupe : l'étiquette porte l'icône du
  /// groupe et se lit « Repas du groupe Famille Dupont ».
  final bool ownerIsGroup;

  /// Recettes que l'utilisateur ne peut pas lire — privées, brouillons,
  /// livre non partagé, supprimées. Le plat ou le composant garde son titre,
  /// suivi de « Recette non partagée », et ne s'ouvre pas.
  final Set<String> lockedRecipeIds;

  /// Composants-recettes qui s'ouvrent. Null : tous ceux qui ne sont pas
  /// verrouillés. Sur un repas d'autrui, une recette encore en cours de
  /// résolution n'y figure pas.
  final Set<String>? openableRecipeIds;

  const PlanningMealTile({
    super.key,
    required this.meal,
    required this.isPast,
    required this.aiLoading,
    required this.isWide,
    this.onDelete,
    this.onChangeRecipe,
    this.onClearRecipe,
    this.onOtherSuggestion,
    this.onReschedule,
    this.onCompose,
    this.onComplete,
    this.sideStatus,
    this.onRemoveComponent,
    this.onStorageAdvice,
    this.onTimeChanged,
    this.onExportToCalendar,
    this.onAddToShopping,
    this.onTap,
    this.onComponentTap,
    this.readOnly = false,
    this.ownerName,
    this.ownerIsGroup = false,
    this.lockedRecipeIds = const {},
    this.openableRecipeIds,
  });

  VoidCallback? _action(VoidCallback? callback) => readOnly ? null : callback;

  bool _isLocked(String? recipeId) =>
      recipeId != null && lockedRecipeIds.contains(recipeId);

  /// Sous-titre du repas, augmenté de la consigne de conservation quand le
  /// plat est préparé un autre jour.
  ///
  /// La consigne est calculée, pas générée : elle s'affiche toujours, même si
  /// la recette n'a jamais reçu de conseil de conservation.
  /// L'origine du choix et les faits qui le justifient : « Choisie par
  /// Kass'Dalle · volaille · 35 min ».
  ///
  /// Le robot ne précède que ce qu'une IA a produit. Il précédait toute
  /// justification, « Sélection manuelle » comprise : un choix fait à la main
  /// s'affichait comme une décision de l'IA. Un repas antérieur au champ
  /// d'origine qui porte cette phrase est lu comme un choix manuel.
  Widget? _buildWhy(ThemeData theme) {
    if (readOnly) return null;
    var source = meal.choiceSource;
    var facts = meal.justification?.trim() ?? '';
    if (source == null && facts.startsWith(_legacyManualJustification)) {
      source = MealChoiceSource.manual;
      facts = '';
    }
    final line = MealOriginLine.maybe(
      source: source,
      facts: facts,
      relaxed: meal.relaxedCriteria,
    );
    if (line == null) return null;
    return Padding(padding: const EdgeInsets.only(top: 4), child: line);
  }

  /// Phrase écrite sur les repas choisis à la main avant le champ d'origine.
  static const _legacyManualJustification = 'Sélection manuelle';

  /// Ce qui accompagne le plat : « Accompagnement : Riz · 70 g par part ».
  ///
  /// Une ligne par composant, sous les temps et avant le pourquoi : c'est ce
  /// qu'on lit pour savoir quoi cuisiner, pas pour savoir pourquoi.
  ///
  /// Un composant qui est une recette porte l'icône de livre, un titre
  /// souligné, et s'ouvre d'un appui : la tuile entière ouvre le plat, et
  /// rien d'autre ne menait au kimchi ou aux gaufrettes du corpus. Une
  /// garniture reste un texte, avec sa part par personne.
  Widget? _buildComponents(ThemeData theme) {
    if (meal.components.isEmpty) return null;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final c in meal.components) _buildComponentLine(theme, c),
        ],
      ),
    );
  }

  Widget _buildComponentLine(ThemeData theme, MealComponent c) {
    final locked = c.isRecipe && _isLocked(c.recipeId);
    final opens =
        c.isRecipe &&
        !locked &&
        onComponentTap != null &&
        (openableRecipeIds?.contains(c.recipeId) ?? true);
    Widget label = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          locked
              ? Icons.lock_outline
              : c.isRecipe
              ? Icons.menu_book_outlined
              : Icons.rice_bowl_outlined,
          size: AppIconSize.badge,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            '${c.role.label} : ${c.label}'
            '${c.quantityLabel != null ? ' · ${c.quantityLabel}' : ''}'
            '${locked ? ' · $kRecipeNotSharedLabel' : ''}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              decoration: opens ? TextDecoration.underline : null,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    if (locked) {
      label = Tooltip(message: kRecipeNotSharedTooltip, child: label);
    }
    final content = opens
        ? InkWell(
            onTap: () => onComponentTap!(c),
            borderRadius: BorderRadius.circular(4),
            child: label,
          )
        : label;
    final onRemove = readOnly ? null : onRemoveComponent;
    if (onRemove == null) return content;
    // Le retrait vit hors de la zone qui ouvre la fiche : les deux gestes ne
    // doivent jamais se disputer le même appui.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: content),
        Tooltip(
          message: 'Retirer',
          child: InkWell(
            onTap: () => onRemove(c),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(2),
              child: Icon(
                Icons.close,
                size: AppIconSize.badge,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// « Il manque : légume » avec « Compléter », ou « Apports du plat
  /// inconnus » pour une recette non classée. Rien sur un repas en lecture
  /// seule, ni pour un plat complet : la tuile ne dit que ce qui manque.
  Widget? _buildSideStatus(ThemeData theme) {
    final status = sideStatus;
    if (readOnly || status == null || meal.recipeId == null) return null;
    final String text;
    switch (status.state) {
      case DishSideState.missing:
        text = status.missingLabel;
      case DishSideState.unknown:
        text = 'Apports du plat inconnus';
      case DishSideState.complete:
      case DishSideState.notApplicable:
        return null;
    }
    final color = status.state == DishSideState.missing
        ? theme.colorScheme.tertiary
        : theme.colorScheme.onSurfaceVariant;
    Widget label = Row(
      children: [
        Icon(
          status.state == DishSideState.missing
              ? Icons.info_outline
              : Icons.help_outline,
          size: AppIconSize.badge,
          color: color,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            text,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    final compose = onCompose;
    if (compose != null) {
      label = InkWell(
        onTap: compose,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: label,
        ),
      );
    }
    final complete = onComplete;
    return Row(
      children: [
        Flexible(child: label),
        if (status.state == DishSideState.missing && complete != null)
          TextButton(
            onPressed: () => complete(status.missing.first),
            child: const Text('Compléter'),
          ),
      ],
    );
  }

  /// « Marie », précédé de la silhouette : à qui est ce repas. « Famille
  /// Dupont », précédé de l'icône du groupe, pour un repas de groupe.
  Widget? _buildOwner(ThemeData theme) {
    final name = ownerName;
    if (name == null) return null;
    return Semantics(
      label: ownerIsGroup
          ? 'Repas du groupe $name'
          : name == 'Vous'
          ? 'Votre repas'
          : 'Repas de $name',
      excludeSemantics: true,
      child: Row(
        children: [
          Icon(
            ownerIsGroup ? Icons.groups_outlined : Icons.person_outline,
            size: AppIconSize.badge,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              name,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// « Recette non partagée », sous le titre d'un plat illisible.
  Widget? _buildLocked(ThemeData theme) {
    if (!_isLocked(meal.recipeId)) return null;
    return const PlanningRecipeNotSharedLine();
  }

  Widget? _buildSubtitle(ThemeData theme, String? subtitle) {
    final owner = _buildOwner(theme);
    final locked = _buildLocked(theme);
    final why = _buildWhy(theme);
    final components = _buildComponents(theme);
    final sideStatus = _buildSideStatus(theme);
    final prep = meal.prepDate;
    final daysAhead = prep == null
        ? 0
        : mealStorageDaysAhead(prepDate: prep, mealDate: meal.plannedAt);
    if (prep == null || daysAhead <= 0) {
      if (owner == null &&
          locked == null &&
          subtitle == null &&
          why == null &&
          components == null &&
          sideStatus == null) {
        return null;
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ?owner,
          ?locked,
          if (subtitle != null) Text(subtitle),
          ?components,
          ?sideStatus,
          ?why,
        ],
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
        ?owner,
        ?locked,
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
        ?components,
        ?sideStatus,
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

    final avatar = CircleAvatar(
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
    );
    final onTime = _action(onTimeChanged);
    final onExport = _action(onExportToCalendar);
    final onShop = onAddToShopping;
    final menu = _buildMenu();
    // Le chariot s'affiche en icône sur grand écran, et sur un repas sans
    // menu ⋮ : ailleurs, il vit dans le menu.
    final shopIcon = onShop != null && (isWide || menu == null);

    return Opacity(
      opacity: isPast ? 0.6 : 1.0,
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: ListTile(
          leading: onTime == null
              ? avatar
              : Tooltip(
                  message: 'Modifier l\'heure',
                  child: InkWell(
                    onTap: onTime,
                    borderRadius: BorderRadius.circular(24),
                    child: avatar,
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
              : (isWide && onExport != null) || shopIcon || menu != null
              ? Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (shopIcon)
                      IconButton(
                        tooltip: 'Ajouter aux courses',
                        icon: const Icon(
                          Icons.add_shopping_cart,
                          size: AppIconSize.small,
                        ),
                        onPressed: onShop,
                      ),
                    if (isWide && onExport != null)
                      IconButton(
                        // L'infobulle du bouton remplace le `Tooltip` qui
                        // l'enveloppait : elle dit la même chose et, elle,
                        // s'annonce aussi au lecteur d'écran.
                        tooltip: 'Exporter ce repas vers le calendrier',
                        icon: const Icon(
                          AppIcons.calendarExport,
                          size: AppIconSize.small,
                        ),
                        onPressed: onExport,
                        visualDensity: VisualDensity.compact,
                      ),
                    ?menu,
                  ],
                )
              : null,
          onTap: _isLocked(meal.recipeId) ? null : onTap,
        ),
      ),
    );
  }

  /// Le menu ⋮ : seules les actions fournies y figurent, et aucun menu
  /// quand il n'y en a pas.
  ///
  /// « Ajouter aux courses » rejoint, sur téléphone, un menu qui existe
  /// déjà ; il n'en crée pas un à lui seul : un repas en lecture seule le
  /// porte en icône, et sur grand écran l'icône est sur toutes les tuiles.
  Widget? _buildMenu() {
    final onDeleteAction = _action(onDelete);
    final actions = <PlanningMealAction, VoidCallback>{
      PlanningMealAction.otherSuggestion: ?_action(onOtherSuggestion),
      PlanningMealAction.changeRecipe: ?_action(onChangeRecipe),
      PlanningMealAction.reschedule: ?_action(onReschedule),
      if (meal.recipeId != null)
        PlanningMealAction.composeMeal: ?_action(onCompose),
      PlanningMealAction.clearRecipe: ?_action(onClearRecipe),
      if (meal.recipeId != null)
        PlanningMealAction.storageAdvice: ?_action(onStorageAdvice),
      PlanningMealAction.exportToCalendar: ?_action(onExportToCalendar),
    };
    if (actions.isEmpty && onDeleteAction == null) return null;
    // Sur grand écran, l'icône de la tuile suffit.
    final onShop = onAddToShopping;
    if (onShop != null && !isWide) {
      actions[PlanningMealAction.addToShopping] = onShop;
    }
    if (onDeleteAction != null) {
      actions[PlanningMealAction.delete] = onDeleteAction;
    }
    final hasOthers = actions.keys.any((a) => a != PlanningMealAction.delete);
    return PopupMenuButton<PlanningMealAction>(
      iconSize: AppIconSize.small,
      onSelected: (action) => actions[action]?.call(),
      itemBuilder: (_) => [
        for (final action in actions.keys)
          if (action == PlanningMealAction.delete) ...[
            if (hasOthers) const PopupMenuDivider(),
            PopupMenuItem(value: action, child: _menuTile(action)),
          ] else
            PopupMenuItem(value: action, child: _menuTile(action)),
      ],
    );
  }

  Widget _menuTile(PlanningMealAction action) {
    final (IconData icon, String label) = switch (action) {
      // Sans IA : la recette suivante de la liste classée par le serveur,
      // pour ce jour-là. Un repas libre n'a pas de recette à remplacer.
      PlanningMealAction.otherSuggestion => (
        Icons.autorenew,
        meal.recipeId == null ? 'Proposer une recette' : 'Autre suggestion',
      ),
      PlanningMealAction.changeRecipe => (
        Icons.swap_horiz_outlined,
        'Changer la recette',
      ),
      PlanningMealAction.reschedule => (
        Icons.calendar_month_outlined,
        'Replanifier',
      ),
      PlanningMealAction.composeMeal => (
        Icons.restaurant_menu_outlined,
        'Composer le repas',
      ),
      PlanningMealAction.clearRecipe => (
        Icons.radio_button_unchecked_outlined,
        'Remettre à blanc',
      ),
      PlanningMealAction.storageAdvice => (
        Icons.kitchen_outlined,
        'Conservation et réchauffage',
      ),
      PlanningMealAction.exportToCalendar => (
        AppIcons.calendarExport,
        'Exporter vers Calendar',
      ),
      PlanningMealAction.addToShopping => (
        Icons.add_shopping_cart,
        'Ajouter aux courses',
      ),
      PlanningMealAction.delete => (Icons.delete_outline, 'Supprimer'),
    };
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      contentPadding: EdgeInsets.zero,
    );
  }
}

/// La ligne cadenas « Recette non partagée », avec son infobulle : sous le
/// titre d'un repas, et dans « À préparer ce jour-là ».
class PlanningRecipeNotSharedLine extends StatelessWidget {
  const PlanningRecipeNotSharedLine({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: kRecipeNotSharedTooltip,
      child: Row(
        children: [
          Icon(
            Icons.lock_outline,
            size: AppIconSize.badge,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              kRecipeNotSharedLabel,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// « Recette non partagée » : la recette d'un repas partagé que
/// l'utilisateur ne peut pas lire.
const kRecipeNotSharedLabel = 'Recette non partagée';

/// L'infobulle qui l'explique.
const kRecipeNotSharedTooltip = 'Son auteur ne l\'a pas partagée avec vous';

enum PlanningMealAction {
  otherSuggestion,
  changeRecipe,
  reschedule,
  composeMeal,
  clearRecipe,
  storageAdvice,
  exportToCalendar,
  addToShopping,
  delete,
}

/// Un jour de la semaine lue sans repas : il est dit libre, et un jour à
/// venir propose d'y poser une recette.
class PlanningEmptyDayRow extends StatelessWidget {
  final bool isPast;
  final VoidCallback? onPick;

  /// « Rien de prévu », ou « Rien de prévu pour vous » quand d'autres
  /// plannings sont affichés : la ligne ne porte que sur les repas de
  /// l'utilisateur.
  final String label;

  /// Le geste proposé : « Choisir une recette » dans un planning où l'on
  /// planifie, « Suggérer un plat » dans le planning d'un groupe dont on est
  /// membre.
  final String actionLabel;
  final IconData actionIcon;

  const PlanningEmptyDayRow({
    super.key,
    required this.isPast,
    this.onPick,
    this.label = 'Rien de prévu',
    this.actionLabel = 'Choisir une recette',
    this.actionIcon = Icons.add,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      // Un Wrap, pas un Row : sur un téléphone, avec un texte agrandi, le
      // bouton passe sous le libellé au lieu de déborder.
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(
                alpha: isPast ? 0.5 : 1,
              ),
            ),
          ),
          if (!isPast && onPick != null) ...[
            TextButton.icon(
              onPressed: onPick,
              icon: Icon(actionIcon),
              label: Text(actionLabel),
            ),
          ],
        ],
      ),
    );
  }
}
