import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/meal_role.dart';
import '../../domain/recipe.dart';
import '../../../books/domain/book.dart';
import '../../../books/presentation/book_picker_field.dart';
import '../../../books/presentation/book_providers.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../../core/theme/app_icon_size.dart';

/// Valeur du menu déroulant pour « Non classé ». Un `DropdownButtonFormField`
/// veut un élément par valeur, `null` compris ; une chaîne vide en tient lieu
/// et redevient `null` au moment de prévenir le parent.
const _kNoMealRole = '';

/// Même rôle pour « Non renseigné » dans les listes protéine et féculent.
const _kNotFilled = '';

/// Aide sous les listes protéine et féculent.
const kMainIngredientHelper =
    'Laissé à Non renseigné, il sera proposé par l\'IA.';

/// Shared metadata form panel used by draft review, recipe edit, and recipe
/// create screens.
///
/// Pass [cuisines]/[onCuisinesChanged] and [dishTypes]/[onDishTypesChanged]
/// to enable the tag editing section (Cuisine + Type de plat).
class RecipeMetaPanel extends ConsumerStatefulWidget {
  final TextEditingController titleCtrl;
  final TextEditingController portionsCtrl;
  final TextEditingController difficultyCtrl;
  final TextEditingController prepTimeCtrl;
  final TextEditingController cookTimeCtrl;
  final TextEditingController restTimeCtrl;
  final TextEditingController pageNumberCtrl;
  final bool saving;
  final String? selectedBookId;
  final void Function(String? id, String? titre) onBookChanged;
  final Recipe? recipe;
  final bool showBookSelector;
  final String? infoBookLabel;
  final List<String>? cuisines;
  final void Function(List<String>)? onCuisinesChanged;
  final List<String>? dishTypes;
  final void Function(List<String>)? onDishTypesChanged;

  /// Rôle dans un repas (`plat`, `accompagnement`…), `null` pour « non
  /// classé ». La liste n'apparaît que si [onMealRoleChanged] est donné.
  final String? mealRole;
  final void Function(String?)? onMealRoleChanged;

  /// Protéine et féculent principaux (`tags.main_protein`,
  /// `tags.main_starch`), `null` pour « Non renseigné ». Chaque liste
  /// n'apparaît que si son rappel est donné, et seulement quand le rôle
  /// choisi est un plat ou un accompagnement.
  final String? mainProtein;
  final void Function(String?)? onMainProteinChanged;
  final String? mainStarch;
  final void Function(String?)? onMainStarchChanged;
  final bool suggestingTags;
  final VoidCallback? onSuggestTags;

  /// Si non-null, affiche un sélecteur de type et appelle ce callback à chaque changement.
  final PageType? pageType;
  final void Function(PageType)? onPageTypeChanged;

  const RecipeMetaPanel({
    super.key,
    required this.titleCtrl,
    required this.portionsCtrl,
    required this.difficultyCtrl,
    required this.prepTimeCtrl,
    required this.cookTimeCtrl,
    required this.restTimeCtrl,
    required this.pageNumberCtrl,
    required this.saving,
    required this.selectedBookId,
    required this.onBookChanged,
    this.recipe,
    this.showBookSelector = true,
    this.infoBookLabel,
    this.cuisines,
    this.onCuisinesChanged,
    this.dishTypes,
    this.onDishTypesChanged,
    this.mealRole,
    this.onMealRoleChanged,
    this.mainProtein,
    this.onMainProteinChanged,
    this.mainStarch,
    this.onMainStarchChanged,
    this.suggestingTags = false,
    this.onSuggestTags,
    this.pageType,
    this.onPageTypeChanged,
  });

  @override
  ConsumerState<RecipeMetaPanel> createState() => _RecipeMetaPanelState();
}

/// Livres proposés, avec en tête le livre d'origine de [recipe] quand il
/// n'en fait pas partie — une page rangée dans le livre d'un autre membre.
///
/// Sans lui, le champ affichait un livre vide, et revenir au livre d'origine
/// après un autre choix était impossible. Pure et exportée pour être testée.
List<Book> booksWithOrigin(List<Book> books, Recipe? recipe) {
  final originId = recipe?.bookId ?? '';
  if (originId.isEmpty || books.any((b) => b.id == originId)) return books;
  final now = DateTime.now();
  return [
    Book(
      id: originId,
      titre: recipe?.bookTitre ?? 'Livre d\'un autre membre',
      auteur: '',
      langue: 'fr',
      tags: const [],
      createdBy: '',
      createdAt: now,
      updatedAt: now,
    ),
    ...books,
  ];
}

/// Aide affichée quand la recette est dans le livre d'un autre membre.
const kForeignBookHelper =
    'Livre d\'un autre membre. Choisir un de vos livres y déplace la recette.';

class _RecipeMetaPanelState extends ConsumerState<RecipeMetaPanel> {
  // La liste passée au sélecteur doit rester la même instance d'un rendu à
  // l'autre : `BookPickerField` remet son filtre à zéro dès qu'il en reçoit
  // une autre.
  List<Book>? _booksSource;
  String? _originId;
  List<Book>? _booksShown;

  List<Book> _booksFor(List<Book> books) {
    final originId = widget.recipe?.bookId;
    if (!identical(books, _booksSource) || originId != _originId) {
      _booksSource = books;
      _originId = originId;
      _booksShown = booksWithOrigin(books, widget.recipe);
    }
    return _booksShown!;
  }

  final _cuisineCtrl = TextEditingController();

  @override
  void dispose() {
    _cuisineCtrl.dispose();
    super.dispose();
  }

  void _addCuisine(String value) {
    final v = value.trim();
    if (v.isEmpty) return;
    final current = List<String>.from(widget.cuisines ?? []);
    if (!current.contains(v)) {
      current.add(v);
      widget.onCuisinesChanged?.call(current);
    }
    _cuisineCtrl.clear();
  }

  void _removeCuisine(String v) {
    final current = List<String>.from(widget.cuisines ?? [])..remove(v);
    widget.onCuisinesChanged?.call(current);
  }

  void _toggleDishType(String v) {
    final current = List<String>.from(widget.dishTypes ?? []);
    if (current.contains(v)) {
      current.remove(v);
    } else {
      current.add(v);
    }
    widget.onDishTypesChanged?.call(current);
  }

  @override
  Widget build(BuildContext context) {
    final booksAsync = ref.watch(targetBooksProvider);
    final theme = Theme.of(context);
    final isRecipe = (widget.pageType ?? PageType.recipe) == PageType.recipe;
    final showTags =
        isRecipe &&
        (widget.onCuisinesChanged != null ||
            widget.onDishTypesChanged != null ||
            widget.onMealRoleChanged != null);
    // Une valeur hors liste — écrite avant que la liste n'existe, ou par un
    // serveur plus récent — reste proposée telle quelle : un menu déroulant
    // exige que la valeur courante soit l'un de ses éléments.
    final currentRole = widget.mealRole;
    final roleHorsListe =
        currentRole != null &&
        currentRole.isNotEmpty &&
        !kMealRoles.contains(currentRole);
    final showMainIngredients =
        widget.onMealRoleChanged != null &&
        kRolesWithMainIngredients.contains(currentRole);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        if (widget.onPageTypeChanged != null) ..._buildTypeSelector(context),
        TextField(
          controller: widget.titleCtrl,
          enabled: !widget.saving,
          decoration: InputDecoration(
            labelText: (widget.pageType ?? PageType.recipe) != PageType.recipe
                ? 'Titre de la page'
                : 'Titre de la recette',
            prefixIcon: const Icon(Icons.title),
          ),
        ),
        const SizedBox(height: 16),
        if (widget.showBookSelector)
          booksAsync.when(
            loading: () => const SizedBox.shrink(),
            error: (_, _) => const SizedBox.shrink(),
            // « Aucun livre » n'est plus une option : toute recette a un
            // livre. Ce choix laissait des recettes orphelines, rangées dans
            // une section qui portait le nom d'un livre système existant —
            // deux endroits pour une même idée, et un livre qui restait vide
            // à côté de ses propres recettes.
            data: (books) => BookPickerField(
              books: _booksFor(books),
              selectedBookId: widget.selectedBookId,
              helperText:
                  (widget.selectedBookId ?? '').isNotEmpty &&
                      !books.any((b) => b.id == widget.selectedBookId)
                  ? kForeignBookHelper
                  : 'À défaut de choix, la recette rejoint « Mes recettes libres »',
              enabled: !widget.saving,
              onChanged: widget.onBookChanged,
            ),
          )
        else if (widget.infoBookLabel != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                // Ce bandeau dit où atterrit une recette conçue par l'IA :
                // c'est un constat sur une création de la machine, pas un
                // bouton pour en demander une.
                Icon(
                  Icons.smart_toy_outlined,
                  size: AppIconSize.inline,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Sera ajoutée dans : ${widget.infoBookLabel}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (widget.showBookSelector) ...[
          const SizedBox(height: 12),
          TextField(
            controller: widget.pageNumberCtrl,
            enabled: !widget.saving,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Page dans le livre',
              prefixIcon: Icon(Icons.bookmark_outline),
            ),
          ),
        ],
        if (isRecipe) ...[
          const SizedBox(height: 16),
          TextField(
            controller: widget.portionsCtrl,
            enabled: !widget.saving,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Portions',
              prefixIcon: Icon(Icons.groups_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: widget.difficultyCtrl,
            enabled: !widget.saving,
            decoration: const InputDecoration(
              labelText: 'Difficulté',
              prefixIcon: Icon(Icons.bolt_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: widget.prepTimeCtrl,
            enabled: !widget.saving,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Temps préparation (min)',
              prefixIcon: Icon(Icons.timer_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: widget.cookTimeCtrl,
            enabled: !widget.saving,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Temps cuisson (min)',
              prefixIcon: Icon(Icons.local_fire_department_outlined),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: widget.restTimeCtrl,
            enabled: !widget.saving,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Temps de repos (min)',
              helperText:
                  'Marinade, réfrigération, levée : le temps où rien ne se fait',
              prefixIcon: Icon(Icons.bedtime_outlined),
            ),
          ),
        ],

        if (showTags) ...[
          const SizedBox(height: 20),
          Text('Catégorisation', style: theme.textTheme.labelMedium),
          const SizedBox(height: 8),

          if (widget.onMealRoleChanged != null) ...[
            DropdownButtonFormField<String>(
              // `initialValue` suit la valeur du parent : le rôle posé par
              // « Suggérer les tags » se voit ici sans rien recréer.
              initialValue: (currentRole == null || currentRole.isEmpty)
                  ? _kNoMealRole
                  : currentRole,
              // Le panneau fait 220 px dans sa disposition la plus étroite :
              // « Accompagnement » avec l'icône et la flèche dépasse sans
              // cela de six pixels.
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Rôle dans un repas',
                helperText:
                    'Ce que le planning compose autour : un plat reçoit un '
                    'accompagnement, une entrée ou un dessert se placent à côté',
                helperMaxLines: 3,
                prefixIcon: Icon(Icons.restaurant_outlined),
              ),
              items: [
                const DropdownMenuItem(
                  value: _kNoMealRole,
                  child: Text('Non classé'),
                ),
                for (final role in kMealRoles)
                  DropdownMenuItem(
                    value: role,
                    child: Text(mealRoleLabel(role)),
                  ),
                if (roleHorsListe)
                  DropdownMenuItem(
                    value: currentRole,
                    child: Text(mealRoleLabel(currentRole)),
                  ),
              ],
              onChanged: widget.saving
                  ? null
                  : (v) => widget.onMealRoleChanged!(
                      (v == null || v == _kNoMealRole) ? null : v,
                    ),
            ),
            const SizedBox(height: 12),
          ],

          if (showMainIngredients && widget.onMainProteinChanged != null) ...[
            _mainIngredientDropdown(
              key: const ValueKey('mainProteinDropdown'),
              label: 'Protéine principale',
              icon: Icons.set_meal_outlined,
              value: widget.mainProtein,
              values: kMainProteins,
              labelOf: mainProteinLabel,
              onChanged: widget.onMainProteinChanged!,
            ),
            const SizedBox(height: 12),
          ],
          if (showMainIngredients && widget.onMainStarchChanged != null) ...[
            _mainIngredientDropdown(
              key: const ValueKey('mainStarchDropdown'),
              label: 'Féculent principal',
              icon: Icons.rice_bowl_outlined,
              value: widget.mainStarch,
              values: kMainStarches,
              labelOf: mainStarchLabel,
              onChanged: widget.onMainStarchChanged!,
            ),
            const SizedBox(height: 12),
          ],

          Text(
            'Cuisine',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          if ((widget.cuisines ?? []).isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final c in widget.cuisines!)
                  Chip(
                    label: Text(c, style: const TextStyle(fontSize: 12)),
                    onDeleted: widget.saving ? null : () => _removeCuisine(c),
                    deleteIcon: const Icon(
                      Icons.close,
                      size: AppIconSize.inline,
                    ),
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
              ],
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _cuisineCtrl,
                  enabled: !widget.saving,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Ajouter une cuisine…',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onSubmitted: _addCuisine,
                  textInputAction: TextInputAction.done,
                ),
              ),
              const SizedBox(width: 6),
              IconButton(
                icon: const Icon(Icons.add, size: AppIconSize.small),
                visualDensity: VisualDensity.compact,
                onPressed: widget.saving
                    ? null
                    : () => _addCuisine(_cuisineCtrl.text),
                tooltip: 'Ajouter',
              ),
            ],
          ),
          const SizedBox(height: 12),

          Text(
            'Type de plat',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final dt in kDishTypes)
                FilterChip(
                  label: Text(dt, style: const TextStyle(fontSize: 12)),
                  selected: (widget.dishTypes ?? []).contains(dt),
                  onSelected: widget.saving ? null : (_) => _toggleDishType(dt),
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  showCheckmark: false,
                ),
            ],
          ),
        ],

        if (widget.recipe != null) ...[
          const SizedBox(height: 24),
          if (widget.recipe!.sourceFileName != null) ...[
            Text('Source', style: theme.textTheme.labelMedium),
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.attach_file, size: AppIconSize.inline),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.recipe!.sourceFileName!,
                    style: theme.textTheme.bodySmall,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ],
          if (widget.recipe!.aiProcessedAt != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.smart_toy_outlined, size: AppIconSize.inline),
                const SizedBox(width: 6),
                Text(
                  'Analysé le ${_fmt(widget.recipe!.aiProcessedAt!)}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            if (ref.watch(isAdminProvider) &&
                widget.recipe!.importVersion != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.build_outlined, size: AppIconSize.inline),
                  const SizedBox(width: 6),
                  Text(
                    'Importé avec v${widget.recipe!.importVersion}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ],
      ],
    );
  }

  /// Liste « Protéine principale » ou « Féculent principal », construite comme
  /// celle du rôle : `initialValue` qui suit le parent, valeur hors liste
  /// gardée telle quelle, désactivée pendant l'enregistrement.
  Widget _mainIngredientDropdown({
    required Key key,
    required String label,
    required IconData icon,
    required String? value,
    required List<String> values,
    required String Function(String) labelOf,
    required void Function(String?) onChanged,
  }) {
    final horsListe =
        value != null && value.isNotEmpty && !values.contains(value);
    return DropdownButtonFormField<String>(
      key: key,
      initialValue: (value == null || value.isEmpty) ? _kNotFilled : value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        helperText: kMainIngredientHelper,
        helperMaxLines: 3,
        prefixIcon: Icon(icon),
      ),
      items: [
        const DropdownMenuItem(
          value: _kNotFilled,
          child: Text('Non renseigné'),
        ),
        for (final v in values)
          DropdownMenuItem(value: v, child: Text(labelOf(v))),
        if (horsListe)
          DropdownMenuItem(value: value, child: Text(labelOf(value))),
      ],
      onChanged: widget.saving
          ? null
          : (v) => onChanged((v == null || v == _kNotFilled) ? null : v),
    );
  }

  String _fmt(DateTime dt) =>
      '${dt.day.toString().padLeft(2, "0")}/'
      '${dt.month.toString().padLeft(2, "0")}/'
      '${dt.year}';

  static String _pageTypeLabel(PageType t) => switch (t) {
    PageType.recipe => 'Recette',
    PageType.technique => 'Technique',
    PageType.equipment => 'Matériel',
    PageType.ingredientNote => 'Fiche ingrédients',
    PageType.other => 'Autre document',
  };

  List<Widget> _buildTypeSelector(BuildContext context) {
    return [
      DropdownButtonFormField<PageType>(
        initialValue: widget.pageType ?? PageType.recipe,
        decoration: const InputDecoration(
          labelText: 'Type de page',
          prefixIcon: Icon(Icons.category_outlined),
        ),
        items: PageType.values
            .map(
              (t) => DropdownMenuItem(value: t, child: Text(_pageTypeLabel(t))),
            )
            .toList(),
        onChanged: widget.saving
            ? null
            : (t) {
                if (t != null) widget.onPageTypeChanged?.call(t);
              },
      ),
      const SizedBox(height: 12),
    ];
  }
}
