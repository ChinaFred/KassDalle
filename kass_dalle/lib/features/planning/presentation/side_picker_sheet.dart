import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../recipes/domain/recipe.dart';
import '../../recipes/domain/recipe_filter.dart';
import '../domain/meal_component.dart';
import '../domain/meal_staple.dart';
import '../domain/side_chooser.dart';

/// Longueur maximale d'un accompagnement saisi en texte libre.
const int kSideFreeLabelMaxChars = 80;

/// Ce que la feuille rend : un candidat ou un texte libre. Fermer la feuille
/// sans choisir rend `null`.
class SidePickerResult {
  final SideCandidate? candidate;

  /// Texte saisi quand ni garniture ni recette ne convient.
  final String? freeLabel;

  /// Ce qu'apporte le texte libre, coché dans la feuille : `feculent`,
  /// `legume`. Vide : apport inconnu.
  final List<String> provides;

  const SidePickerResult.pick(SideCandidate this.candidate)
    : freeLabel = null,
      provides = const [];
  const SidePickerResult.free(String this.freeLabel, {this.provides = const []})
    : candidate = null;

  /// Le composant à poser.
  MealComponent toComponent({String? justification}) {
    final c = candidate;
    if (c != null) return c.toComponent(justification: justification);
    return MealComponent.free(
      freeLabel!,
      justification: justification,
      provides: provides,
    );
  }
}

/// Le texte saisi, tel qu'il sera posé : espaces réduites, première lettre
/// en majuscule, borné à [kSideFreeLabelMaxChars]. Vide si rien d'utile.
String sideFreeLabelFrom(String input) {
  final s = input.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (s.isEmpty) return '';
  final bounded = s.length > kSideFreeLabelMaxChars
      ? s.substring(0, kSideFreeLabelMaxChars).trimRight()
      : s;
  return bounded[0].toUpperCase() + bounded.substring(1);
}

/// Mots comparables d'un texte : minuscules, sans accents, au singulier
/// (« dauphines » → « dauphine »), comme [sideNameKey].
List<String> _searchWords(String value) => [
  for (final w in foldSearchText(value).split(' '))
    if (w.isNotEmpty)
      w.length > 3 && w.endsWith('s') ? w.substring(0, w.length - 1) : w,
];

/// Un filtre de la rangée de pastilles : une famille de garnitures, les
/// recettes d'accompagnement, ou ce qui manque au plat (« Pour le légume »,
/// garnitures et recettes confondues). `null` dans la feuille veut dire
/// « Tout ».
@immutable
class SideFamilyFilter {
  /// Famille de garnitures ; `null` pour les recettes ou pour un besoin.
  final StapleCategory? category;

  /// Ce qui manque au plat ; `null` pour une famille ou les recettes.
  final SideNeed? need;

  const SideFamilyFilter.category(StapleCategory this.category) : need = null;
  const SideFamilyFilter.recipes() : category = null, need = null;
  const SideFamilyFilter.need(SideNeed this.need) : category = null;

  bool get isRecipes => category == null && need == null;

  String get label =>
      need != null ? 'Pour le ${need!.label}' : category?.label ?? 'Recettes';

  bool accepts(SideCandidate c) {
    final n = need;
    if (n != null) return c.provides(n);
    return isRecipes ? c.isRecipe : c.staple?.category == category;
  }

  @override
  bool operator ==(Object other) =>
      other is SideFamilyFilter &&
      other.category == category &&
      other.need == need;

  @override
  int get hashCode => Object.hash(category, need);
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
/// La recherche ignore la casse, les accents et le pluriel, mot à mot :
/// chaque mot tapé doit commencer un mot du nom, dans n'importe quel ordre.
/// « pate » trouve « Pâtes », « vert » trouve « Haricots verts »,
/// « pommes dauphines » trouve « Pommes dauphine ».
bool sideCandidateMatches(
  SideCandidate c, {
  SideFamilyFilter? family,
  String query = '',
}) {
  if (family != null && !family.accepts(c)) return false;
  final wanted = _searchWords(query);
  if (wanted.isEmpty) return true;
  final words = _searchWords(c.name);
  return wanted.every((q) => words.any((w) => w.startsWith(q)));
}

/// Vrai si [c] porte le nom [query], au pluriel et aux accents près : la
/// tuile « texte libre » n'est alors pas proposée, le candidat suffit.
bool sideCandidateNamed(SideCandidate c, String query) {
  final wanted = _searchWords(query);
  return wanted.isNotEmpty && _listEquals(wanted, _searchWords(c.name));
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Choisir un accompagnement de plus pour un plat, à la main : « Compléter »,
/// « Ajouter un accompagnement » de l'éditeur et de Nouveau planning.
///
/// D'abord ce que le plat suggère, puis les garnitures par famille, puis les
/// recettes d'accompagnement. Une recherche par nom et une rangée de filtres
/// par famille réduisent la liste. Fermer la feuille, c'est ne rien ajouter.
///
/// Un texte libre passe par une étape de plus : deux pastilles facultatives,
/// « Féculent » et « Légume », puis « Ajouter ». Sans pastille, son apport
/// reste inconnu.
class SidePickerSheet extends StatefulWidget {
  final Recipe main;
  final List<SideCandidate> candidates;

  /// Ce qui manque au plat quand la feuille s'ouvre par « Compléter » : la
  /// liste s'ouvre filtrée sur ce besoin, et la pastille du texte libre est
  /// cochée d'office.
  final SideNeed? initialNeed;

  const SidePickerSheet({
    super.key,
    required this.main,
    required this.candidates,
    this.initialNeed,
  });

  @override
  State<SidePickerSheet> createState() => _SidePickerSheetState();
}

class _SidePickerSheetState extends State<SidePickerSheet> {
  final _searchCtrl = TextEditingController();
  String _query = '';
  late SideFamilyFilter? _family = widget.initialNeed == null
      ? null
      : SideFamilyFilter.need(widget.initialNeed!);

  /// Texte libre en attente de son apport, ou `null` hors de cette étape.
  String? _pendingFree;
  final Set<SideNeed> _pendingProvides = {};

  void _askProvides(String label) => setState(() {
    _pendingFree = label;
    _pendingProvides
      ..clear()
      ..addAll([?widget.initialNeed]);
  });

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
    final freeLabel = _freeLabelOffered();
    final pending = _pendingFree;
    if (pending != null) return _buildProvidesStep(theme, pending);

    final children = <Widget>[
      if (freeLabel.isNotEmpty)
        ListTile(
          leading: const Icon(Icons.edit_note_outlined),
          title: Text('Ajouter « $freeLabel »'),
          subtitle: const Text('Texte libre, sans quantité ni courses'),
          onTap: () => _askProvides(freeLabel),
        ),
      if (candidates.isEmpty && freeLabel.isEmpty)
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
            'Aucune garniture ni recette d\'accompagnement ne correspond.',
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: TextField(
              controller: _searchCtrl,
              textInputAction: TextInputAction.done,
              inputFormatters: [
                LengthLimitingTextInputFormatter(kSideFreeLabelMaxChars),
              ],
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Rechercher ou saisir un accompagnement',
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
              onSubmitted: (_) => _submit(),
            ),
          ),
          if (families.length > 1 || widget.initialNeed != null)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  _familyChip(null, 'Tout'),
                  if (widget.initialNeed != null)
                    _familyChip(
                      SideFamilyFilter.need(widget.initialNeed!),
                      SideFamilyFilter.need(widget.initialNeed!).label,
                    ),
                  for (final f in families) _familyChip(f, f.label),
                ],
              ),
            ),
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

  /// Le texte libre à proposer : ce qui est tapé, sauf si un candidat porte
  /// déjà ce nom — on choisit alors le candidat.
  String _freeLabelOffered() {
    final label = sideFreeLabelFrom(_query);
    if (label.isEmpty) return '';
    if (widget.candidates.any((c) => sideCandidateNamed(c, label))) return '';
    return label;
  }

  /// Entrée au clavier : le candidat qui porte ce nom, sinon le texte libre.
  void _submit() {
    final label = sideFreeLabelFrom(_query);
    if (label.isEmpty) return;
    for (final c in widget.candidates) {
      if (sideCandidateNamed(c, label)) {
        Navigator.pop(context, SidePickerResult.pick(c));
        return;
      }
    }
    _askProvides(label);
  }

  /// L'étape du texte libre : son nom, deux pastilles facultatives, puis
  /// « Ajouter ». « Retour » rend la liste.
  Widget _buildProvidesStep(ThemeData theme, String label) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        16,
        16,
        16 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('« $label »', style: theme.textTheme.titleMedium),
          const SizedBox(height: 12),
          Text(
            'Ce qu\'il apporte (facultatif)',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final need in SideNeed.values)
                FilterChip(
                  label: Text(need.chipLabel),
                  selected: _pendingProvides.contains(need),
                  onSelected: (v) => setState(() {
                    if (v) {
                      _pendingProvides.add(need);
                    } else {
                      _pendingProvides.remove(need);
                    }
                  }),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Sans choix, son apport reste inconnu.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => setState(() => _pendingFree = null),
                child: const Text('Retour'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () => Navigator.pop(
                  context,
                  SidePickerResult.free(
                    label,
                    provides: [
                      for (final n in SideNeed.values)
                        if (_pendingProvides.contains(n)) n.name,
                    ],
                  ),
                ),
                child: const Text('Ajouter'),
              ),
            ],
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
    final staple = c.staple;
    final subtitle = staple != null
        ? '${formatStapleQuantity(staple.quantityPerPortion, staple.unit)} par part'
              '${staple.note.trim().isNotEmpty ? ' · ${staple.note.trim()}' : ''}'
        : 'Recette d\'accompagnement';
    return ListTile(
      leading: Icon(
        c.isRecipe ? Icons.menu_book_outlined : Icons.rice_bowl_outlined,
      ),
      title: Text(c.name),
      subtitle: Text(subtitle),
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
