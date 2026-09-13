import 'package:flutter/material.dart';

import '../../recipes/domain/recipe.dart';
import '../domain/meal_component.dart';
import '../domain/meal_staple.dart';
import '../domain/side_chooser.dart';

/// Ce que la feuille rend : un candidat, ou « aucun accompagnement ».
class SidePickerResult {
  final SideCandidate? candidate;

  const SidePickerResult.pick(SideCandidate this.candidate);
  const SidePickerResult.none() : candidate = null;

  bool get isNone => candidate == null;
}

/// Choisir l'accompagnement d'un plat, à la main.
///
/// D'abord ce que le plat suggère, puis les garnitures par famille, puis les
/// recettes d'accompagnement. Ce que le programme a choisi est coché ; on
/// peut aussi ne rien mettre.
class SidePickerSheet extends StatelessWidget {
  final Recipe main;
  final List<SideCandidate> candidates;
  final MealComponent? current;

  const SidePickerSheet({
    super.key,
    required this.main,
    required this.candidates,
    this.current,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final suggested = suggestedCandidatesFor(main, candidates);
    final suggestedIds = suggested.map((c) => c.id).toSet();
    final staples =
        candidates
            .where((c) => !c.isRecipe && !suggestedIds.contains(c.id))
            .toList()
          ..sort((a, b) {
            final byCategory = a.staple!.category.index.compareTo(
              b.staple!.category.index,
            );
            if (byCategory != 0) return byCategory;
            final byOrder = a.sortOrder.compareTo(b.sortOrder);
            return byOrder != 0
                ? byOrder
                : a.name.toLowerCase().compareTo(b.name.toLowerCase());
          });
    final recipes =
        candidates
            .where((c) => c.isRecipe && !suggestedIds.contains(c.id))
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );

    final children = <Widget>[
      ListTile(
        leading: Icon(
          Icons.block_outlined,
          color: current == null ? theme.colorScheme.primary : null,
        ),
        title: const Text('Aucun accompagnement'),
        trailing: current == null ? const Icon(Icons.check) : null,
        onTap: () => Navigator.pop(context, const SidePickerResult.none()),
      ),
      if (candidates.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Text(
            'Aucune garniture ni recette d\'accompagnement disponible. Un '
            'administrateur peut semer les garnitures depuis Admin › '
            'Backfills ; vos recettes d\'accompagnement doivent porter leur '
            'rôle.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      if (suggested.isNotEmpty) ...[
        _Header('Suggérés pour « ${main.titre} »'),
        for (final c in suggested) _tile(context, c),
      ],
      if (staples.isNotEmpty) ...[
        for (var i = 0; i < staples.length; i++) ...[
          if (i == 0 ||
              staples[i].staple!.category != staples[i - 1].staple!.category)
            _Header(staples[i].staple!.category.label),
          _tile(context, staples[i]),
        ],
      ],
      if (recipes.isNotEmpty) ...[
        const _Header('Recettes d\'accompagnement'),
        for (final c in recipes) _tile(context, c),
      ],
    ];

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.4,
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text('Accompagnement', style: theme.textTheme.titleMedium),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.7,
            ),
            child: ListView(shrinkWrap: true, children: children),
          ),
        ],
      ),
    );
  }

  Widget _tile(BuildContext context, SideCandidate c) {
    final theme = Theme.of(context);
    final selected = current?.sourceId == c.id;
    final staple = c.staple;
    final subtitle = staple != null
        ? '${formatStapleQuantity(staple.quantityPerPortion, staple.unit)} par part'
              '${staple.note.trim().isNotEmpty ? ' · ${staple.note.trim()}' : ''}'
        : 'Recette d\'accompagnement';
    return ListTile(
      leading: Icon(
        c.isRecipe ? Icons.menu_book_outlined : Icons.rice_bowl_outlined,
        color: selected ? theme.colorScheme.primary : null,
      ),
      title: Text(c.name),
      subtitle: Text(subtitle),
      trailing: selected ? const Icon(Icons.check) : null,
      onTap: () => Navigator.pop(context, SidePickerResult.pick(c)),
    );
  }
}

class _Header extends StatelessWidget {
  final String label;
  const _Header(this.label);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        label,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
