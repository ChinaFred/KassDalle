import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/error_report_service.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/app_shortcuts.dart';
import '../../../core/widgets/app_states.dart';
import '../../recipes/domain/meal_role.dart';
import '../../recipes/domain/recipe.dart';
import '../domain/meal_component.dart';
import '../domain/meal_staple.dart';
import '../domain/side_chooser.dart';
import 'meal_staples_providers.dart';
import 'recipe_picker_sheet.dart';
import 'side_picker_sheet.dart';

/// Ce que l'éditeur lit avant de s'afficher.
class MealComposerData {
  /// Le plat du repas ; `null` quand sa recette est introuvable ou que le
  /// repas est un nom libre.
  final Recipe? main;

  /// Recettes proposées par « Changer », et recettes d'accompagnement
  /// proposées comme accompagnements.
  final List<Recipe> recipes;

  const MealComposerData({required this.main, required this.recipes});
}

/// Ce que l'éditeur rend à « Enregistrer ».
class MealComposition {
  /// Le plat ; `null` seulement si le repas n'en avait pas et qu'on n'en a
  /// pas choisi.
  final Recipe? main;

  /// Vrai quand « Changer » a posé un autre plat.
  final bool mainChanged;

  /// Les accompagnements du plat principal, dans l'ordre, 0 à
  /// [kMaxSidesPerDish].
  final List<MealComponent> sides;

  const MealComposition({
    required this.main,
    required this.mainChanged,
    required this.sides,
  });
}

/// Ouvre l'éditeur « Composer le repas » en mode plat.
///
/// Téléphone : feuille modale pleine hauteur, barre [Annuler] [Enregistrer]
/// fixe en bas. Au-delà de `PlatformUtils.wideBreakpoint` : boîte de
/// dialogue d'une colonne, 560 px au plus ; Ctrl/Cmd+S enregistre, Échap
/// ferme. L'éditeur travaille sur une copie : rien n'est écrit avant
/// « Enregistrer », qui appelle [onSave] une seule fois. Un échec de
/// [onSave] laisse l'éditeur ouvert ; un succès le ferme et affiche
/// [successMessage] s'il est donné.
///
/// Partagé : le planning l'ouvre sur un repas enregistré, la feuille
/// « Planifier » d'une recette sur un repas pas encore créé ([canChangeRecipe]
/// faux, [successMessage] nul : rien n'est écrit à ce moment).
Future<void> showMealComposer(
  BuildContext context, {
  required Future<MealComposerData> Function() load,
  required List<MealComponent> sides,
  required Future<void> Function(MealComposition composition) onSave,
  String fallbackTitle = 'Repas libre',
  bool canChangeRecipe = true,
  Set<String> dismissedRecipeIds = const {},
  String? successMessage = 'Repas enregistré.',
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final scheme = Theme.of(context).colorScheme;
  final size = MediaQuery.sizeOf(context);
  final wide = size.width >= PlatformUtils.wideBreakpoint;
  Widget sheet() => MealComposerSheet(
    load: load,
    initialSides: sides,
    onSave: onSave,
    fallbackTitle: fallbackTitle,
    canChangeRecipe: canChangeRecipe,
    dismissedRecipeIds: dismissedRecipeIds,
    onSaved: successMessage == null
        ? null
        : () => messenger?.showSuccessMessage(successMessage, scheme: scheme),
  );
  if (wide) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SizedBox(
            height: math.min(size.height * 0.85, 760),
            child: sheet(),
          ),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // Le glisser fermerait sans passer par la question « Abandonner les
    // modifications ? ».
    enableDrag: false,
    clipBehavior: Clip.antiAlias,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => sheet(),
  );
}

/// L'éditeur lui-même, dans son cadre (feuille ou boîte de dialogue).
///
/// Il porte son propre `Scaffold` : un message d'erreur s'affiche dans
/// l'éditeur, au-dessus de sa barre, et non sous la feuille.
class MealComposerSheet extends ConsumerStatefulWidget {
  final Future<MealComposerData> Function() load;
  final List<MealComponent> initialSides;
  final Future<void> Function(MealComposition composition) onSave;
  final String fallbackTitle;
  final bool canChangeRecipe;
  final Set<String> dismissedRecipeIds;

  /// Appelé après un enregistrement réussi, une fois l'éditeur fermé.
  final VoidCallback? onSaved;

  /// Pour les tests : le service qui reçoit les échecs.
  final ErrorReportService? errorReporter;

  const MealComposerSheet({
    super.key,
    required this.load,
    required this.initialSides,
    required this.onSave,
    this.fallbackTitle = 'Repas libre',
    this.canChangeRecipe = true,
    this.dismissedRecipeIds = const {},
    this.onSaved,
    this.errorReporter,
  });

  @override
  ConsumerState<MealComposerSheet> createState() => _MealComposerSheetState();
}

class _MealComposerSheetState extends ConsumerState<MealComposerSheet> {
  late Future<MealComposerData> _future = widget.load();
  MealComposerData? _data;

  /// Copie locale : rien ne part avant « Enregistrer ».
  Recipe? _main;
  late List<MealComponent> _sides = List.of(widget.initialSides);
  String? _initialMainId;
  late final String _initialSidesKey = _keyOf(widget.initialSides);

  bool _saving = false;

  /// Vrai une fois la fermeture décidée (enregistré, ou abandon confirmé).
  bool _closing = false;

  static String _keyOf(List<MealComponent> sides) =>
      jsonEncode([for (final c in sides) c.toMap()]);

  bool get _dirty =>
      _data != null &&
      (_main?.id != _initialMainId || _keyOf(_sides) != _initialSidesKey);

  void _retry() => setState(() {
    _data = null;
    _future = widget.load();
  });

  void _adopt(MealComposerData data) {
    if (_data != null) return;
    _data = data;
    _main = data.main;
    _initialMainId = data.main?.id;
  }

  // ── Fermeture ──────────────────────────────────────────────────────────

  Future<void> _requestClose() async {
    if (_saving) return;
    if (!_dirty) {
      _closing = true;
      Navigator.of(context).pop();
      return;
    }
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Abandonner les modifications ?'),
        content: const Text('Le repas reste tel qu\'il était.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Continuer'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Abandonner'),
          ),
        ],
      ),
    );
    if (discard != true || !mounted) return;
    setState(() => _closing = true);
    Navigator.of(context).pop();
  }

  Future<void> _save() async {
    if (_saving || _data == null) return;
    if (!_dirty) {
      _closing = true;
      Navigator.of(context).pop();
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onSave(
        MealComposition(
          main: _main,
          mainChanged: _main?.id != _initialMainId,
          sides: List.unmodifiable(_sides),
        ),
      );
      if (!mounted) return;
      setState(() => _closing = true);
      Navigator.of(context).pop();
      widget.onSaved?.call();
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'mealComposer.save',
        error: e,
        stackTrace: stackTrace,
        context: {
          'main_changed': _main?.id != _initialMainId,
          'side_count': _sides.length,
        },
        service: widget.errorReporter,
      );
      if (!mounted) return;
      setState(() => _saving = false);
      context.showErrorSnackBar('Repas non enregistré. Réessayez.');
    }
  }

  // ── Gestes ─────────────────────────────────────────────────────────────

  List<SideCandidate> _candidates(List<UserStaple> staples) =>
      sideCandidatesFrom(staples: staples, recipes: _data?.recipes ?? const []);

  Future<void> _changeRecipe(List<UserStaple> staples) async {
    final data = _data;
    if (data == null) return;
    final picked = await showModalBottomSheet<Recipe>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => RecipePickerSheet(
        recipes: data.recipes,
        dismissedRecipeIds: widget.dismissedRecipeIds,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _main = picked;
      // Un autre plat, d'autres accompagnements : le programme recompose.
      _sides = [
        for (final c in chooseSides(
          main: picked,
          candidates: _candidates(staples),
        ))
          c.component,
      ];
    });
  }

  Future<void> _addSide(List<UserStaple> staples, {SideNeed? need}) async {
    final main = _main;
    if (main == null || _sides.length >= kMaxSidesPerDish) return;
    final result = await showModalBottomSheet<SidePickerResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SidePickerSheet(
        main: main,
        candidates: _candidates(staples),
        initialNeed: need,
      ),
    );
    final component = result?.toComponent(justification: 'Choisi à la main.');
    if (component == null || !mounted) return;
    setState(() => _sides = [..._sides, component]);
  }

  void _addSuggested(MealComponent component) {
    if (_sides.length >= kMaxSidesPerDish) return;
    setState(() => _sides = [..._sides, component]);
  }

  void _removeSide(int index) =>
      setState(() => _sides = [..._sides]..removeAt(index));

  Future<void> _editProvides(int index) async {
    final side = _sides[index];
    final chosen = await showDialog<List<String>>(
      context: context,
      builder: (_) => _ProvidesDialog(side: side),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _sides = [..._sides]..[index] = side.withProvides(chosen);
    });
  }

  // ── Construction ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final staplesAsync = ref.watch(myStaplesProvider);
    return PopScope(
      canPop: _closing || (!_dirty && !_saving),
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _requestClose();
      },
      child: AppShortcuts(
        onSave: _save,
        child: ScaffoldMessenger(
          child: Scaffold(
            appBar: AppBar(
              automaticallyImplyLeading: false,
              title: const Text('Composer le repas'),
              actions: [
                IconButton(
                  tooltip: 'Fermer',
                  icon: const Icon(Icons.close),
                  onPressed: _requestClose,
                ),
              ],
            ),
            body: FutureBuilder<MealComposerData>(
              future: _future,
              builder: (context, snap) {
                // Défilable : sur un petit écran, le détail de l'erreur
                // dépasse la hauteur laissée par la barre du bas.
                if (snap.hasError) {
                  return SingleChildScrollView(
                    child: AppErrorState(
                      error: snap.error,
                      title: 'Les recettes n\'ont pas pu être lues.',
                      onRetry: _retry,
                      compact: true,
                    ),
                  );
                }
                if (staplesAsync.hasError) {
                  return SingleChildScrollView(
                    child: AppErrorState(
                      error: staplesAsync.error,
                      title: 'Les recettes n\'ont pas pu être lues.',
                      onRetry: () => ref.invalidate(baseMealStaplesProvider),
                      compact: true,
                    ),
                  );
                }
                final data = snap.data;
                final staples = staplesAsync.value;
                if (data == null || staples == null) {
                  return const AppLoadingState();
                }
                _adopt(data);
                return _buildContent(context, staples);
              },
            ),
            bottomNavigationBar: _buildBar(context),
          ),
        ),
      ),
    );
  }

  Widget _buildBar(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _saving ? null : _requestClose,
              child: const Text('Annuler'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _saving || _data == null ? null : _save,
              child: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, List<UserStaple> staples) {
    final theme = Theme.of(context);
    final main = _main;
    final recipesById = <String, Recipe>{
      for (final r in _data?.recipes ?? const <Recipe>[])
        if (r.id.isNotEmpty) r.id: r,
      if (main != null && main.id.isNotEmpty) main.id: main,
    };
    final categories = <String, StapleCategory>{
      for (final u in staples) u.staple.id: u.staple.category,
    };
    final status = main == null
        ? const DishSideStatus(DishSideState.unknown)
        : dishSideStatus(
            mainTags: main.tags,
            sides: _sides,
            stapleCategories: categories,
            recipesById: recipesById,
          );
    final full = _sides.length >= kMaxSidesPerDish;
    final suggestions = main == null || status.state != DishSideState.missing
        ? const <SideChoice>[]
        : chooseSides(
            main: main,
            candidates: _candidates(staples),
            needs: status.missing,
            takenIds: {for (final s in _sides) s.sourceId},
          );
    final contains = main == null
        ? const <String>[]
        : orderedMealContains(main.tags.contains);

    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
      children: [
        ListTile(
          leading: const Icon(Icons.restaurant_outlined),
          title: Text(main?.titre ?? widget.fallbackTitle),
          subtitle: Text(
            contains.isEmpty
                ? (main?.tags.hasMealRole ?? false)
                      ? 'Apporte : rien de noté'
                      : 'Apports du plat inconnus'
                : 'Apporte : ${contains.map(mealContainsLabel).join(', ')}',
          ),
          trailing: widget.canChangeRecipe
              ? TextButton(
                  onPressed: _saving ? null : () => _changeRecipe(staples),
                  child: const Text('Changer'),
                )
              : null,
        ),
        _StatusLine(status: status),
        const Divider(height: 24),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            'Accompagnements',
            style: theme.textTheme.labelLarge?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
        ),
        if (_sides.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(
              'Aucun accompagnement',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        for (var i = 0; i < _sides.length; i++)
          _sideTile(
            theme,
            i,
            sideComponentProvides(
              _sides[i],
              stapleCategories: categories,
              recipesById: recipesById,
            ),
          ),
        for (final s in suggestions)
          ListTile(
            leading: Icon(
              Icons.lightbulb_outline,
              color: theme.colorScheme.tertiary,
            ),
            title: Text(
              'Suggéré pour le ${s.need.label} : ${s.component.label}',
            ),
            trailing: TextButton(
              onPressed: full || _saving
                  ? null
                  : () => _addSuggested(s.component),
              child: const Text('Ajouter'),
            ),
          ),
        if (main != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 16, 0),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: full
                  ? Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        '$kMaxSidesPerDish accompagnements au plus',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    )
                  : TextButton.icon(
                      onPressed: _saving ? null : () => _addSide(staples),
                      icon: const Icon(Icons.add),
                      label: const Text('Ajouter un accompagnement'),
                    ),
            ),
          ),
      ],
    );
  }

  Widget _sideTile(ThemeData theme, int index, Set<SideNeed> provides) {
    final side = _sides[index];
    final String subtitle;
    if (side.isFree) {
      subtitle = side.provides.isEmpty
          ? 'Texte libre · apport inconnu'
          : 'Texte libre · apporte : ${_needsLabel(provides)}';
    } else {
      final parts = [
        ?side.quantityLabel,
        if (side.isRecipe) 'Recette',
        if (provides.isNotEmpty) 'apporte : ${_needsLabel(provides)}',
      ];
      subtitle = parts.join(' · ');
    }
    return ListTile(
      leading: Icon(
        side.isRecipe
            ? Icons.menu_book_outlined
            : side.isFree
            ? Icons.edit_note_outlined
            : Icons.rice_bowl_outlined,
      ),
      title: Text(side.label),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      trailing: PopupMenuButton<_SideAction>(
        tooltip: 'Actions sur « ${side.label} »',
        enabled: !_saving,
        onSelected: (a) => switch (a) {
          _SideAction.remove => _removeSide(index),
          _SideAction.editProvides => _editProvides(index),
        },
        itemBuilder: (_) => [
          if (side.isFree)
            const PopupMenuItem(
              value: _SideAction.editProvides,
              child: ListTile(
                leading: Icon(Icons.tune),
                title: Text('Modifier l\'apport'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          const PopupMenuItem(
            value: _SideAction.remove,
            child: ListTile(
              leading: Icon(Icons.close),
              title: Text('Retirer'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }

  static String _needsLabel(Set<SideNeed> needs) => [
    for (final n in SideNeed.values)
      if (needs.contains(n)) n.label,
  ].join(', ');
}

enum _SideAction { remove, editProvides }

/// « Il manque : légume », « Plat complet », ou « Apports du plat inconnus ».
class _StatusLine extends StatelessWidget {
  final DishSideStatus status;
  const _StatusLine({required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (IconData icon, String text, Color color) = switch (status.state) {
      DishSideState.complete => (
        Icons.check_circle_outline,
        'Plat complet',
        theme.colorScheme.primary,
      ),
      DishSideState.missing => (
        Icons.info_outline,
        status.missingLabel,
        theme.colorScheme.tertiary,
      ),
      DishSideState.unknown => (
        Icons.help_outline,
        'Apports inconnus : le plat n\'est pas classé.',
        theme.colorScheme.onSurfaceVariant,
      ),
      DishSideState.notApplicable => (
        Icons.info_outline,
        '',
        theme.colorScheme.onSurfaceVariant,
      ),
    };
    if (text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: Row(
        children: [
          Icon(icon, size: AppIconSize.small, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// « Modifier l'apport » d'un texte libre : Féculent, Légume, ou rien.
class _ProvidesDialog extends StatefulWidget {
  final MealComponent side;
  const _ProvidesDialog({required this.side});

  @override
  State<_ProvidesDialog> createState() => _ProvidesDialogState();
}

class _ProvidesDialogState extends State<_ProvidesDialog> {
  late final Set<String> _chosen = {...widget.side.provides};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('« ${widget.side.label} »'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Ce qu\'il apporte (facultatif)'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final need in SideNeed.values)
                FilterChip(
                  label: Text(need.chipLabel),
                  selected: _chosen.contains(need.name),
                  onSelected: (v) => setState(() {
                    if (v) {
                      _chosen.add(need.name);
                    } else {
                      _chosen.remove(need.name);
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
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, [
            // Les apports connus d'abord, dans l'ordre ; une valeur inconnue
            // lue en base reste.
            for (final n in SideNeed.values)
              if (_chosen.contains(n.name)) n.name,
            for (final v in _chosen)
              if (!SideNeed.values.any((n) => n.name == v)) v,
          ]),
          child: const Text('Valider'),
        ),
      ],
    );
  }
}
