import 'package:flutter/material.dart';

import '../../../core/utils/recipe_tag_sections.dart';
import '../domain/recipe.dart';
import 'cooklang_preview_helpers.dart';
import 'detail/portions_input_dialog.dart';

/// Blocs de l'aperçu CookLang.
///
/// Ils vivaient tous dans la méthode `_buildPreview`, qui faisait 430 lignes :
/// on ne pouvait ni lire un bloc sans traverser les autres, ni en éprouver un
/// seul. Chacun est ici un widget nommé, avec ses entrées explicites — ce qu'il
/// lui faut pour se dessiner, et rien d'autre.

// ── En-tête de section repliable ─────────────────────────────────────────────

class CooklangSectionHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool expanded;
  final VoidCallback onTap;
  final Widget? action;

  const CooklangSectionHeader({
    super.key,
    required this.icon,
    required this.title,
    required this.expanded,
    required this.onTap,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: theme.colorScheme.primary),
            const SizedBox(width: 8),
            Text(title, style: theme.textTheme.titleMedium),
            const Spacer(),
            ?action,
            Icon(
              expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Contrôle des portions ────────────────────────────────────────────────────

/// Nombre de portions : simple puce en lecture, ou moins/valeur/plus quand on
/// peut le changer.
class CooklangPortionsControl extends StatelessWidget {
  final int? selectedPortions;

  /// Valeur brute des métadonnées (« 4 personnes »), employée à défaut.
  final String? fallback;
  final ValueChanged<int>? onChanged;
  final int minPortions;
  final int maxPortions;

  const CooklangPortionsControl({
    super.key,
    required this.selectedPortions,
    required this.fallback,
    required this.onChanged,
    required this.minPortions,
    required this.maxPortions,
  });

  static int? _firstInt(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final match = RegExp(r'\d+').firstMatch(raw);
    if (match == null) return null;
    return int.tryParse(match.group(0)!);
  }

  @override
  Widget build(BuildContext context) {
    final displayed = selectedPortions ?? _firstInt(fallback);
    final onChangedLocal = onChanged;

    if (displayed == null) {
      return Chip(
        label: Text('${fallback ?? ''} portions'),
        avatar: const Icon(Icons.people_outline, size: 16),
      );
    }
    if (onChangedLocal == null) {
      return Chip(
        label: Text('$displayed portions'),
        avatar: const Icon(Icons.people_outline, size: 16),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StepButton(
          icon: Icons.remove,
          enabled: displayed > minPortions,
          onTap: () => onChangedLocal(displayed - 1),
        ),
        const SizedBox(width: 6),
        _EditableChip(
          displayed: displayed,
          minPortions: minPortions,
          maxPortions: maxPortions,
          onChanged: onChangedLocal,
        ),
        const SizedBox(width: 6),
        _StepButton(
          icon: Icons.add,
          enabled: displayed < maxPortions,
          onTap: () => onChangedLocal(displayed + 1),
        ),
      ],
    );
  }
}

class _EditableChip extends StatelessWidget {
  final int displayed;
  final int minPortions;
  final int maxPortions;
  final ValueChanged<int> onChanged;

  const _EditableChip({
    required this.displayed,
    required this.minPortions,
    required this.maxPortions,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: const Icon(Icons.people_outline, size: 16),
      label: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () async {
          final input = await showPortionsInputDialog(
            context,
            current: displayed,
            minPortions: minPortions,
            maxPortions: maxPortions,
          );
          if (input == null || input == displayed) return;
          onChanged(input);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(
            '$displayed portions',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _StepButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outline),
        borderRadius: BorderRadius.circular(7),
      ),
      child: IconButton(
        padding: EdgeInsets.zero,
        splashRadius: 14,
        constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
        onPressed: enabled ? onTap : null,
        icon: Icon(icon, size: 14),
      ),
    );
  }
}

// ── Bandeau : portions, temps, illustrations ─────────────────────────────────

class CooklangMetaRow extends StatelessWidget {
  final Map<String, String> meta;
  final int? selectedPortions;
  final ValueChanged<int>? onSelectedPortionsChanged;
  final int minPortions;
  final int maxPortions;
  final List<String> illustrationUrls;
  final VoidCallback? onAddIllustration;
  final void Function(int index)? onTapIllustration;
  final void Function(String url)? onDeleteIllustration;

  const CooklangMetaRow({
    super.key,
    required this.meta,
    required this.selectedPortions,
    required this.onSelectedPortionsChanged,
    required this.minPortions,
    required this.maxPortions,
    required this.illustrationUrls,
    this.onAddIllustration,
    this.onTapIllustration,
    this.onDeleteIllustration,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasPortions =
        selectedPortions != null ||
        meta.containsKey('portions') ||
        meta.containsKey('servings');
    final hasPrepTime = meta.containsKey('prep_time');
    final hasCookTime = meta.containsKey('cook_time');
    final hasIllus = illustrationUrls.isNotEmpty;
    final hasAdd = onAddIllustration != null;

    if (!hasPortions && !hasPrepTime && !hasCookTime && !hasIllus && !hasAdd) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (hasPortions)
            CooklangPortionsControl(
              selectedPortions: selectedPortions,
              fallback: meta['portions'] ?? meta['servings'],
              onChanged: onSelectedPortionsChanged,
              minPortions: minPortions,
              maxPortions: maxPortions,
            ),
          if (hasPrepTime)
            Chip(
              label: Text('Prép. ${meta['prep_time']} min'),
              avatar: const Icon(Icons.timer_outlined, size: 16),
            ),
          if (hasCookTime)
            Chip(
              label: Text('Cuisson ${meta['cook_time']} min'),
              avatar: const Icon(
                Icons.local_fire_department_outlined,
                size: 16,
              ),
            ),
          for (int i = 0; i < illustrationUrls.length; i++)
            CooklangIllustrationThumb(
              url: illustrationUrls[i],
              onTap: () => onTapIllustration?.call(i),
              onDelete: onDeleteIllustration != null
                  ? () => onDeleteIllustration!(illustrationUrls[i])
                  : null,
            ),
          if (hasAdd)
            InkWell(
              onTap: onAddIllustration,
              borderRadius: BorderRadius.circular(8),
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  border: Border.all(
                    color: theme.colorScheme.outline.withAlpha(80),
                    width: 1.5,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  Icons.add_a_photo_outlined,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Catégorisation ───────────────────────────────────────────────────────────

class CooklangTagSections extends StatelessWidget {
  final List<RecipeTagSection> sections;

  const CooklangTagSections({super.key, required this.sections});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: sections.map((section) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  section.label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: section.values
                      .map(
                        (value) => Chip(
                          label: Text(value),
                          backgroundColor: theme.colorScheme.tertiaryContainer,
                          labelStyle: TextStyle(
                            fontSize: 11,
                            color: theme.colorScheme.onTertiaryContainer,
                          ),
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      )
                      .toList(),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ── Liste des ingrédients ────────────────────────────────────────────────────

/// Puces d'ingrédients, groupées par section quand la recette en porte.
///
/// Le regroupement suit l'ordre d'apparition des catégories, pas l'ordre
/// alphabétique : une recette se lit dans l'ordre où elle est écrite.
class CooklangIngredientsList extends StatelessWidget {
  final List<RecipeIngredient> ingredients;

  const CooklangIngredientsList({super.key, required this.ingredients});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasCategoryData = ingredients.any(
      (i) => i.category != null && i.category!.isNotEmpty,
    );

    Widget chipsFor(List<RecipeIngredient> list) => Wrap(
      spacing: 8,
      runSpacing: 4,
      children: list
          .map(
            (ing) => Chip(
              label: Text(
                cooklangFormatIngredient(ing.qty, ing.unit, ing.name),
              ),
              backgroundColor: theme.colorScheme.secondaryContainer,
            ),
          )
          .toList(),
    );

    if (!hasCategoryData) return chipsFor(ingredients);

    final categoryOrder = <String?>[];
    for (final ing in ingredients) {
      final cat = (ing.category?.isEmpty ?? true) ? null : ing.category;
      if (!categoryOrder.contains(cat)) categoryOrder.add(cat);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: categoryOrder.map((cat) {
        final group = ingredients
            .where(
              (i) => cat == null
                  ? (i.category == null || i.category!.isEmpty)
                  : i.category == cat,
            )
            .toList();
        if (group.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (cat != null) ...[
              const SizedBox(height: 10),
              Text(
                cat,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
            ],
            chipsFor(group),
          ],
        );
      }).toList(),
    );
  }
}
