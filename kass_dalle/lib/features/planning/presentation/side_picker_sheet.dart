import 'package:flutter/material.dart';

import '../../recipes/domain/recipe.dart';
import '../../recipes/domain/recipe_filter.dart';
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

/// Un filtre de la rangée de pastilles : une famille de garnitures, ou les
/// recettes d'accompagnement. `null` dans la feuille veut dire « Tout ».
@immutable
class SideFamilyFilter {
  /// Famille de garnitures ; `null` pour les recettes d'accompagnement.
  final StapleCategory? category;

  const SideFamilyFilter.category(StapleCategory this.category);
  const SideFamilyFilter.recipes() : category = null;

  bool get isRecipes => category == null;

  String get label => category?.label ?? 'Recettes';

  bool accepts(SideCandidate c) =>
      isRecipes ? c.isRecipe : c.staple?.category == category;

  @override
  bool operator ==(Object other) =>
      other is SideFamilyFilter && other.category == category;

  @override
  int get hashCode => category.hashCode;
}

/// Les filtres à proposer : les familles présentes parmi les candidats, dans
/// l'ordre des familles, puis « Recettes » s'il y en a.
List<SideFamilyFilter> sideFamilyFiltersFor(List<SideCandidate> candidates) {
  final categories = {
    for (final c in candidates)
      if (c.staple != null) c.staple!.category,
  }.toList()..sort((a, b) => a.index.compareTo(b.index));
  return [
    for (final category in categories) SideFamilyFilter.category(category),
    if (candidates.any((c) => c.isRecipe)) const SideFamilyFilter.recipes(),
  ];
}

/// Vrai si [c] passe le filtre de famille et la recherche par nom.
///
/// La recherche ignore la casse et les accents, et cherche une sous-chaîne :
/// « pate » trouve « Pâtes », « vert » trouve « Haricots verts ».
bool sideCandidateMatches(
  SideCandidate c, {
  SideFamilyFilter? family,
  String query = '',
}) {
  if (family != null && !family.accepts(c)) return false;
  final q = foldSearchText(query);
  return q.isEmpty || foldSearchText(c.name).contains(q);
}

/// Choisir l'accompagnement d'un plat, à la main.
///
/// D'abord ce que le plat suggère, puis les garnitures par famille, puis les
/// recettes d'accompagnement. Une recherche par nom et une rangée de filtres
/// par famille réduisent la liste. Ce que le programme a choisi est coché ;
/// on peut aussi ne rien mettre.
class SidePickerSheet extends StatefulWidget {
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
  State<SidePickerSheet> createState() => _SidePickerSheetState();
}

class _SidePickerSheetState extends State<SidePickerSheet> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  SideFamilyFilter? _family;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool _matches(SideCandidate c) =>
      sideCandidateMatches(c, family: _family, query: _query);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final candidates = widget.candidates;
    final current = widget.current;
    final filtering = _family != null || _query.trim().isNotEmpty;
    final families = sideFamilyFiltersFor(candidates);

    final allSuggested = suggestedCandidatesFor(widget.main, candidates);
    final suggestedIds = allSuggested.map((c) => c.id).toSet();
    final suggested = allSuggested.where(_matches).toList();
    final staples =
        candidates
            .where(
              (c) => !c.isRecipe && !suggestedIds.contains(c.id) && _matches(c),
            )
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
            .where(
              (c) => c.isRecipe && !suggestedIds.contains(c.id) && _matches(c),
            )
            .toList()
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    final noMatch =
        filtering && suggested.isEmpty && staples.isEmpty && recipes.isEmpty;

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
      if (noMatch)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
          child: Text(
            'Aucun accompagnement ne correspond.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      if (suggested.isNotEmpty) ...[
        _Header('Suggérés pour « ${widget.main.titre} »'),
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

    final list = ListView(
      shrinkWrap: candidates.isEmpty,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      children: children,
    );

    return Padding(
      padding: EdgeInsets.only(
        bottom: 16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
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
          if (candidates.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Rechercher un accompagnement',
                  border: const OutlineInputBorder(),
                  isDense: true,
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Effacer la recherche',
                          icon: const Icon(Icons.clear),
                          onPressed: () => setState(() {
                            _searchCtrl.clear();
                            _query = '';
                          }),
                        ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            if (families.length > 1)
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    _familyChip(null, 'Tout'),
                    for (final f in families) _familyChip(f, f.label),
                  ],
                ),
              ),
          ],
          // Hauteur fixe tant qu'il y a des candidats : la liste ne saute
          // pas à chaque lettre tapée. `Flexible` la laisse se réduire quand
          // le clavier prend la place.
          Flexible(
            child: candidates.isEmpty
                ? list
                : SizedBox(
                    height: MediaQuery.sizeOf(context).height * 0.6,
                    child: list,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _familyChip(SideFamilyFilter? family, String label) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: ChoiceChip(
      label: Text(label),
      selected: _family == family,
      onSelected: (_) => setState(() => _family = family),
    ),
  );

  Widget _tile(BuildContext context, SideCandidate c) {
    final theme = Theme.of(context);
    final selected = widget.current?.sourceId == c.id;
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
