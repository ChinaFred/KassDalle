import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

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
import '../domain/meal_composition.dart';
import '../domain/meal_kind.dart';
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

  /// Recettes proposées par « Changer », comme accompagnements et comme
  /// contenu des services d'un menu.
  final List<Recipe> recipes;

  const MealComposerData({required this.main, required this.recipes});
}

/// Ce que l'éditeur rend à « Enregistrer ».
class MealComposerResult {
  /// Le plat ; `null` seulement si le repas n'en avait pas et qu'on n'en a
  /// pas choisi.
  final Recipe? main;

  /// Vrai quand « Changer » a posé un autre plat.
  final bool mainChanged;

  /// La composition enregistrée : un plat ne porte plus que ses
  /// accompagnements, les services masqués sont retirés.
  final MealComposition composition;

  const MealComposerResult({
    required this.main,
    required this.mainChanged,
    required this.composition,
  });

  MealKind get kind => composition.kind;

  /// Les accompagnements du plat principal, dans l'ordre, 0 à
  /// [kMaxSidesPerDish].
  List<MealComponent> get sides => composition.mainSides;

  /// Les `components` à écrire, le marqueur du plat principal portant
  /// [mainTitle].
  List<MealComponent> componentsFor(String mainTitle) =>
      composition.toComponents(mainTitle: mainTitle);
}

/// « Repas du dimanche 25 oct. » ; « Composer le repas » sans date.
String mealComposerTitle(DateTime? date) => date == null
    ? 'Composer le repas'
    : 'Repas du ${DateFormat('EEEE d MMM', 'fr').format(date)}';

/// Ouvre l'éditeur d'un repas : plat, ou menu de services.
///
/// Téléphone : feuille modale pleine hauteur, barre [Annuler] [Enregistrer]
/// fixe en bas. Au-delà de `PlatformUtils.wideBreakpoint` : boîte de
/// dialogue d'une colonne, 560 px au plus ; Ctrl/Cmd+S enregistre, Échap
/// ferme. L'éditeur travaille sur une copie : rien n'est écrit avant
/// « Enregistrer », qui appelle [onSave] une seule fois. Un échec de
/// [onSave] laisse l'éditeur ouvert ; un succès le ferme et affiche
/// [successMessage] s'il est donné.
///
/// [initial] : la composition du repas ; à défaut, un plat portant [sides].
/// [initialKind] à menu ouvre l'éditeur en mode menu (« Passer en menu »).
/// [allowMenu] faux masque le choix « Plat | Menu » (la feuille
/// « Planifier » d'une recette, qui ne compose que l'accompagnement).
///
/// Partagé : le planning l'ouvre sur un repas enregistré, Nouveau planning
/// sur un créneau, la feuille « Planifier » d'une recette sur un repas pas
/// encore créé ([canChangeRecipe] faux, [successMessage] nul : rien n'est
/// écrit à ce moment).
Future<void> showMealComposer(
  BuildContext context, {
  required Future<MealComposerData> Function() load,
  List<MealComponent> sides = const [],
  MealComposition? initial,
  MealKind? initialKind,
  DateTime? mealDate,
  bool allowMenu = true,
  required Future<void> Function(MealComposerResult result) onSave,
  String fallbackTitle = kFreeMealTitle,
  bool canChangeRecipe = true,
  Set<String> dismissedRecipeIds = const {},
  String? successMessage = 'Repas enregistré.',
  ErrorReportService? errorReporter,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final scheme = Theme.of(context).colorScheme;
  final size = MediaQuery.sizeOf(context);
  final wide = size.width >= PlatformUtils.wideBreakpoint;
  Widget sheet() => MealComposerSheet(
    load: load,
    initial: initial ?? MealComposition.dish(sides: sides),
    initialKind: initialKind,
    mealDate: mealDate,
    allowMenu: allowMenu,
    onSave: onSave,
    fallbackTitle: fallbackTitle,
    canChangeRecipe: canChangeRecipe,
    dismissedRecipeIds: dismissedRecipeIds,
    errorReporter: errorReporter,
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
  final MealComposition initial;
  final MealKind? initialKind;
  final DateTime? mealDate;
  final bool allowMenu;
  final Future<void> Function(MealComposerResult result) onSave;
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
    required this.initial,
    this.initialKind,
    this.mealDate,
    this.allowMenu = true,
    required this.onSave,
    this.fallbackTitle = kFreeMealTitle,
    this.canChangeRecipe = true,
    this.dismissedRecipeIds = const {},
    this.onSaved,
    this.errorReporter,
  });

  @override
  ConsumerState<MealComposerSheet> createState() => _MealComposerSheetState();
}

enum _CourseAction {
  changeContent,
  changeType,
  moveUp,
  moveDown,
  remove,
  backToDish,
}

enum _SideAction { remove, editProvides }

class _MealComposerSheetState extends ConsumerState<MealComposerSheet> {
  late Future<MealComposerData> _future = widget.load();
  MealComposerData? _data;

  /// Copie locale : rien ne part avant « Enregistrer ».
  Recipe? _main;
  late MealComposition _composition = widget.initialKind == MealKind.menu
      ? widget.initial.toMenu()
      : widget.initial;
  String? _initialMainId;
  late final String _initialKey = _keyOf(widget.initial);

  bool _saving = false;

  /// Vrai une fois la fermeture décidée (enregistré, ou abandon confirmé).
  bool _closing = false;

  /// Le messager de l'éditeur : un échec d'enregistrement s'affiche dans
  /// l'éditeur, au-dessus de sa barre, et non sous la feuille.
  final _messengerKey = GlobalKey<ScaffoldMessengerState>();

  /// L'échec de lecture des garnitures a été signalé.
  bool _staplesErrorReported = false;

  /// L'échec de la lecture en cours a été signalé ; remis à faux par
  /// « Réessayer ».
  bool _loadErrorReported = false;

  static String _keyOf(MealComposition c) => jsonEncode([
    c.kind.key,
    [for (final m in c.toComponents(mainTitle: '')) m.toMap()],
  ], toEncodable: (o) => o.toString());

  bool get _dirty =>
      _data != null &&
      (_main?.id != _initialMainId || _keyOf(_composition) != _initialKey);

  void _retry() => setState(() {
    _data = null;
    _loadErrorReported = false;
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
    final composition = _composition.isMenu
        ? _composition
        : _composition.toDish();
    try {
      await widget.onSave(
        MealComposerResult(
          main: _main,
          mainChanged: _main?.id != _initialMainId,
          composition: composition,
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
          'meal_kind': composition.kind.key,
          'course_count': composition.courses.length,
          'side_count': composition.mainSides.length,
        },
        service: widget.errorReporter,
      );
      if (!mounted) return;
      setState(() => _saving = false);
      _messengerKey.currentState?.showErrorMessage(
        'Repas non enregistré. Réessayez.',
        scheme: Theme.of(context).colorScheme,
      );
    }
  }

  // ── Lectures ───────────────────────────────────────────────────────────

  Map<String, Recipe> get _recipesById => {
    for (final r in _data?.recipes ?? const <Recipe>[])
      if (r.id.isNotEmpty) r.id: r,
    if (_main != null && _main!.id.isNotEmpty) _main!.id: _main!,
  };

  /// La recette d'un plat du menu : celle du repas pour le plat principal,
  /// celle du service pour un plat secondaire.
  Recipe? _dishRecipe(MealCourse course) {
    if (course.isMain) return _main;
    final id = course.component.recipeId;
    return id == null ? null : _recipesById[id];
  }

  List<SideCandidate> _sideCandidates(List<UserStaple> staples) =>
      sideCandidatesFrom(staples: staples, recipes: _data?.recipes ?? const []);

  int get _mainIndex => _composition.mainIndex;

  // ── Gestes : plat principal ────────────────────────────────────────────

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
      _composition = _composition.withMainSides([
        for (final c in chooseSides(
          main: picked,
          candidates: _sideCandidates(staples),
        ))
          c.component,
      ]);
    });
  }

  // ── Gestes : accompagnements d'un plat ─────────────────────────────────

  Future<void> _addSide(
    int courseIndex,
    List<UserStaple> staples, {
    SideNeed? need,
  }) async {
    final course = _composition.courses[courseIndex];
    if (course.sides.length >= kMaxSidesPerDish) return;
    final recipe = _dishRecipe(course);
    if (course.isMain && recipe == null) return;
    final result = await showModalBottomSheet<SidePickerResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => SidePickerSheet(
        main: recipe,
        candidates: _sideCandidates(staples),
        initialNeed: need,
      ),
    );
    final component = result?.toComponent(justification: 'Choisi à la main.');
    if (component == null || !mounted) return;
    _addSuggested(courseIndex, component);
  }

  void _addSuggested(int courseIndex, MealComponent component) {
    final course = _composition.courses[courseIndex];
    if (course.sides.length >= kMaxSidesPerDish) return;
    setState(() {
      _composition = _composition.setSides(courseIndex, [
        ...course.sides,
        component,
      ]);
    });
  }

  void _removeSide(int courseIndex, int sideIndex) => setState(() {
    final sides = [..._composition.courses[courseIndex].sides]
      ..removeAt(sideIndex);
    _composition = _composition.setSides(courseIndex, sides);
  });

  Future<void> _editProvides(int courseIndex, int sideIndex) async {
    final side = _composition.courses[courseIndex].sides[sideIndex];
    final chosen = await showDialog<List<String>>(
      context: context,
      builder: (_) => _ProvidesDialog(side: side),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      final sides = [..._composition.courses[courseIndex].sides];
      sides[sideIndex] = side.withProvides(chosen);
      _composition = _composition.setSides(courseIndex, sides);
    });
  }

  // ── Gestes : services d'un menu ────────────────────────────────────────

  void _setKind(MealKind kind) => setState(() {
    _composition = kind == MealKind.menu
        ? _composition.toMenu()
        : _composition.withKind(MealKind.plat);
  });

  void _applyTemplate(MenuTemplate template) =>
      setState(() => _composition = _composition.applyTemplate(template));

  Future<void> _addCourse(MealComponentRole role) async {
    String? courseLabel;
    if (role == MealComponentRole.autre) {
      final label = await _askCourseLabel(null);
      if (label == null || !mounted) return;
      courseLabel = courseLabelFrom(label);
    }
    setState(() {
      _composition = _composition.addCourse(role, courseLabel: courseLabel);
    });
  }

  Future<void> _changeContent(int index, List<UserStaple> staples) async {
    final course = _composition.courses[index];
    if (course.isMain) {
      if (widget.canChangeRecipe) await _changeRecipe(staples);
      return;
    }
    final data = _data;
    if (data == null) return;
    MealComponent? content;
    if (course.isDish) {
      final picked = await showModalBottomSheet<Recipe>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => RecipePickerSheet(
          recipes: data.recipes,
          hintText: 'Rechercher ou saisir un nom libre…',
          freeNameAlways: true,
        ),
      );
      if (picked == null) return;
      content = picked.id.isEmpty
          ? MealComponent.free(picked.titre, role: MealComponentRole.plat)
          : MealComponent.recipe(picked, role: MealComponentRole.plat);
    } else {
      final result = await showModalBottomSheet<SidePickerResult>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => SidePickerSheet(
          title: course.typeLabel,
          role: course.role,
          candidates: courseCandidatesFor(
            course.role,
            staples: staples,
            recipes: data.recipes,
          ),
        ),
      );
      content = result?.toComponent(role: course.role);
    }
    if (content == null || !mounted) return;
    setState(() {
      _composition = _composition.setCourseContent(index, content);
    });
  }

  Future<void> _changeType(int index) async {
    final course = _composition.courses[index];
    final picked = await showDialog<MealComponentRole>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Type du service'),
        children: [
          for (final role in kCourseRoles)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, role),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 40),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(_roleMenuLabel(role)),
                ),
              ),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    String? courseLabel;
    if (picked == MealComponentRole.autre) {
      final label = await _askCourseLabel(course.component.courseLabel);
      if (label == null || !mounted) return;
      courseLabel = courseLabelFrom(label);
    }
    setState(() {
      _composition = _composition.changeCourseType(
        index,
        picked,
        courseLabel: courseLabel,
      );
    });
  }

  /// Le libellé d'un service « Autre… » ; `null` si l'on annule, vide pour
  /// garder « Autre ».
  Future<String?> _askCourseLabel(String? initial) => showDialog<String>(
    context: context,
    builder: (_) => _CourseLabelDialog(initial: initial ?? ''),
  );

  void _move(int index, int delta) => setState(() {
    _composition = _composition.moveCourse(index, index + delta);
  });

  void _removeCourse(int index) =>
      setState(() => _composition = _composition.removeCourse(index));

  void _onCourseAction(
    int index,
    _CourseAction action,
    List<UserStaple> staples,
  ) {
    switch (action) {
      case _CourseAction.changeContent:
        _changeContent(index, staples);
      case _CourseAction.changeType:
        _changeType(index);
      case _CourseAction.moveUp:
        _move(index, -1);
      case _CourseAction.moveDown:
        _move(index, 1);
      case _CourseAction.remove:
        _removeCourse(index);
      case _CourseAction.backToDish:
        _setKind(MealKind.plat);
    }
  }

  static String _roleMenuLabel(MealComponentRole role) =>
      role == MealComponentRole.autre ? 'Autre…' : role.label;

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
          key: _messengerKey,
          child: Scaffold(
            appBar: AppBar(
              automaticallyImplyLeading: false,
              title: Text(mealComposerTitle(widget.mealDate)),
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
                  if (!_loadErrorReported) {
                    _loadErrorReported = true;
                    reportUnexpectedError(
                      feature: 'mealComposer.load',
                      error: snap.error!,
                      stackTrace: snap.stackTrace,
                      service: widget.errorReporter,
                    );
                  }
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
                  // Le flux des garnitures ne remonte pas son erreur.
                  if (!_staplesErrorReported) {
                    _staplesErrorReported = true;
                    reportUnexpectedError(
                      feature: 'mealComposer.loadStaples',
                      error: staplesAsync.error!,
                      stackTrace: staplesAsync.stackTrace,
                      service: widget.errorReporter,
                    );
                  }
                  return SingleChildScrollView(
                    child: AppErrorState(
                      error: staplesAsync.error,
                      title: 'Vos garnitures n\'ont pas pu être lues.',
                      onRetry: () {
                        _staplesErrorReported = false;
                        ref.invalidate(baseMealStaplesProvider);
                        ref.invalidate(myStapleOverridesProvider);
                      },
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
                return _composition.isMenu
                    ? _buildMenu(context, staples)
                    : _buildDish(context, staples);
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

  /// « Plat | Menu », en tête de l'éditeur.
  Widget? _buildKindSwitch() {
    if (!widget.allowMenu) return null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: SegmentedButton<MealKind>(
        segments: const [
          ButtonSegment(
            value: MealKind.plat,
            label: Text('Plat'),
            icon: Icon(Icons.restaurant_outlined),
          ),
          ButtonSegment(
            value: MealKind.menu,
            label: Text('Menu'),
            icon: Icon(Icons.restaurant_menu_outlined),
          ),
        ],
        selected: {_composition.kind},
        showSelectedIcon: false,
        onSelectionChanged: _saving ? null : (s) => _setKind(s.first),
      ),
    );
  }

  /// Le plat seul : la recette, ce qu'elle apporte, ses accompagnements.
  Widget _buildDish(BuildContext context, List<UserStaple> staples) {
    final theme = Theme.of(context);
    final main = _main;
    final dropped = _composition.droppedAsDish.length;
    final contains = main == null
        ? const <String>[]
        : orderedMealContains(main.tags.contains);
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
      children: [
        ?_buildKindSwitch(),
        if (dropped > 0)
          _InfoLine(
            icon: Icons.info_outline,
            text: dropped == 1
                ? '1 service sera retiré à l\'enregistrement'
                : '$dropped services seront retirés à l\'enregistrement',
            color: theme.colorScheme.error,
          ),
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
        ..._buildDishBlock(theme, staples, _mainIndex, withHeader: true),
      ],
    );
  }

  /// Ce qu'un plat apporte avec ses accompagnements : « Il manque : … » ou
  /// « Plat complet », puis les accompagnements, les suggestions du
  /// programme et « + Ajouter un accompagnement ».
  List<Widget> _buildDishBlock(
    ThemeData theme,
    List<UserStaple> staples,
    int courseIndex, {
    bool withHeader = false,
    double indent = 0,
  }) {
    final course = _composition.courses[courseIndex];
    final recipe = _dishRecipe(course);
    final recipesById = _recipesById;
    final categories = <String, StapleCategory>{
      for (final u in staples) u.staple.id: u.staple.category,
    };
    final sides = course.sides;
    final status = recipe == null
        ? const DishSideStatus(DishSideState.unknown)
        : dishSideStatus(
            mainTags: recipe.tags,
            sides: sides,
            stapleCategories: categories,
            recipesById: recipesById,
          );
    final full = sides.length >= kMaxSidesPerDish;
    final suggestions = recipe == null || status.state != DishSideState.missing
        ? const <SideChoice>[]
        : chooseSides(
            main: recipe,
            candidates: _sideCandidates(staples),
            needs: status.missing,
            takenIds: {for (final s in sides) s.sourceId},
          );
    final canAdd = !course.isMain || recipe != null;
    Widget padded(Widget child) => indent == 0
        ? child
        : Padding(
            padding: EdgeInsetsDirectional.only(start: indent),
            child: child,
          );
    return [
      padded(_StatusLine(status: status)),
      if (withHeader) ...[
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
      ],
      if (sides.isEmpty && withHeader)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Text(
            'Aucun accompagnement',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      for (var i = 0; i < sides.length; i++)
        padded(
          _sideTile(
            theme,
            courseIndex,
            i,
            sideComponentProvides(
              sides[i],
              stapleCategories: categories,
              recipesById: recipesById,
            ),
          ),
        ),
      for (final s in suggestions)
        padded(
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
                  : () => _addSuggested(courseIndex, s.component),
              child: const Text('Ajouter'),
            ),
          ),
        ),
      if (canAdd)
        Padding(
          padding: EdgeInsetsDirectional.fromSTEB(8 + indent, 4, 16, 0),
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
                    onPressed: _saving
                        ? null
                        : () => _addSide(courseIndex, staples),
                    icon: const Icon(Icons.add),
                    label: const Text('Ajouter un accompagnement'),
                  ),
          ),
        ),
    ];
  }

  Widget _sideTile(
    ThemeData theme,
    int courseIndex,
    int index,
    Set<SideNeed> provides,
  ) {
    final side = _composition.courses[courseIndex].sides[index];
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
          _SideAction.remove => _removeSide(courseIndex, index),
          _SideAction.editProvides => _editProvides(courseIndex, index),
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

  // ── Mode menu ──────────────────────────────────────────────────────────

  /// Le menu : les modèles de départ tant que les services ajoutés sont
  /// vides, puis la liste réordonnable des services, puis « + Ajouter un
  /// service ».
  Widget _buildMenu(BuildContext context, List<UserStaple> staples) {
    final theme = Theme.of(context);
    final courses = _composition.courses;
    final showTemplates = _composition.onlyEmptyCourses;
    final selected = _composition.template;
    return ReorderableListView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 16),
      buildDefaultDragHandles: false,
      onReorderItem: (from, to) {
        if (_saving) return;
        setState(() => _composition = _composition.moveCourse(from, to));
      },
      header: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?_buildKindSwitch(),
          if (showTemplates)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final t in MenuTemplate.values)
                    ChoiceChip(
                      label: Text(t.label),
                      selected: selected == t,
                      onSelected: _saving ? null : (_) => _applyTemplate(t),
                    ),
                ],
              ),
            ),
        ],
      ),
      footer: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: _composition.canAddCourse
              ? PopupMenuButton<MealComponentRole>(
                  tooltip: 'Ajouter un service',
                  enabled: !_saving,
                  onSelected: _addCourse,
                  itemBuilder: (_) => [
                    for (final role in kCourseRoles)
                      PopupMenuItem(
                        value: role,
                        child: Text(_roleMenuLabel(role)),
                      ),
                  ],
                  child: IgnorePointer(
                    child: TextButton.icon(
                      onPressed: _saving ? null : () {},
                      icon: const Icon(Icons.add),
                      label: const Text('Ajouter un service'),
                    ),
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    '$kMaxCoursesPerMenu services au plus',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
        ),
      ),
      children: [
        for (var i = 0; i < courses.length; i++)
          KeyedSubtree(
            key: ObjectKey(courses[i]),
            child: _buildCourse(theme, staples, i),
          ),
      ],
    );
  }

  /// Les actions du menu ⋮ d'un service.
  List<PopupMenuEntry<_CourseAction>> _courseMenuItems(int index) {
    final courses = _composition.courses;
    final course = courses[index];
    final twoOrLess = courses.length <= 2;
    PopupMenuItem<_CourseAction> item(
      _CourseAction a,
      IconData icon,
      String label,
    ) => PopupMenuItem(
      value: a,
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        contentPadding: EdgeInsets.zero,
      ),
    );
    return [
      if (!course.isMain || widget.canChangeRecipe)
        item(
          _CourseAction.changeContent,
          Icons.swap_horiz_outlined,
          'Changer le contenu',
        ),
      if (!course.isMain)
        item(
          _CourseAction.changeType,
          Icons.category_outlined,
          'Changer le type',
        ),
      if (index > 0) item(_CourseAction.moveUp, Icons.arrow_upward, 'Monter'),
      if (index < courses.length - 1)
        item(_CourseAction.moveDown, Icons.arrow_downward, 'Descendre'),
      if (!course.isMain && twoOrLess)
        item(
          _CourseAction.backToDish,
          Icons.restaurant_outlined,
          'Repasser en plat',
        )
      else if (!course.isMain)
        item(_CourseAction.remove, Icons.close, 'Retirer'),
    ];
  }

  Future<void> _showCourseContextMenu(
    int index,
    Offset globalPosition,
    List<UserStaple> staples,
  ) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null || _saving) return;
    final action = await showMenu<_CourseAction>(
      context: context,
      position: RelativeRect.fromRect(
        globalPosition & Size.zero,
        Offset.zero & overlay.size,
      ),
      items: _courseMenuItems(index),
    );
    if (action != null && mounted) _onCourseAction(index, action, staples);
  }

  /// Une ligne de service : poignée, type, contenu ou « à choisir »
  /// [Choisir], et son menu ⋮ ; un plat porte dessous ses accompagnements.
  Widget _buildCourse(ThemeData theme, List<UserStaple> staples, int index) {
    final course = _composition.courses[index];
    final main = _main;
    final String? content;
    String? detail;
    if (course.isMain) {
      content =
          main?.titre ??
          (widget.fallbackTitle == kFreeMealTitle
              ? null
              : widget.fallbackTitle);
    } else if (course.isEmpty) {
      content = null;
    } else {
      content = course.component.label;
      detail = course.component.quantityLabel;
    }
    final missing = content == null;
    final color = missing
        ? theme.colorScheme.error
        : theme.colorScheme.onSurface;
    final canChoose = missing && (!course.isMain || widget.canChangeRecipe);
    final row = GestureDetector(
      onSecondaryTapDown: (d) =>
          _showCourseContextMenu(index, d.globalPosition, staples),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              enabled: !_saving,
              child: Tooltip(
                message: 'Déplacer « ${course.typeLabel} »',
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: SizedBox.square(
                    dimension: 48,
                    child: Icon(
                      Icons.drag_indicator,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    course.typeLabel,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  Text(
                    content ?? 'à choisir',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: color,
                      fontWeight: missing ? FontWeight.w600 : null,
                    ),
                  ),
                  if (detail != null)
                    Text(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (canChoose)
              TextButton(
                onPressed: _saving
                    ? null
                    : () => _changeContent(index, staples),
                child: const Text('Choisir'),
              ),
            PopupMenuButton<_CourseAction>(
              tooltip: 'Actions sur « ${course.typeLabel} »',
              enabled: !_saving,
              onSelected: (a) => _onCourseAction(index, a, staples),
              itemBuilder: (_) => _courseMenuItems(index),
            ),
          ],
        ),
      ),
    );
    if (!course.isDish) {
      return Material(type: MaterialType.transparency, child: row);
    }
    return Material(
      type: MaterialType.transparency,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          row,
          ..._buildDishBlock(theme, staples, index, indent: 40),
          const Divider(height: 16),
        ],
      ),
    );
  }
}

/// Une ligne d'information, icône et texte.
class _InfoLine extends StatelessWidget {
  final IconData icon;
  final String text;
  final Color color;
  const _InfoLine({
    required this.icon,
    required this.text,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          Icon(icon, size: AppIconSize.small, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// « Il manque : légume » ou « Plat complet ». Un plat aux apports inconnus
/// n'a pas de ligne ici : le sous-titre de la recette le dit.
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
      // Déjà dit sous le titre : « Apports du plat inconnus ». Une recette
      // supprimée ou un nom libre n'est pas « non classé ».
      DishSideState.unknown => (
        Icons.help_outline,
        '',
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

/// Le libellé d'un service « Autre… » : « Trou normand », 30 caractères au
/// plus. Vide : « Autre ».
class _CourseLabelDialog extends StatefulWidget {
  final String initial;
  const _CourseLabelDialog({required this.initial});

  @override
  State<_CourseLabelDialog> createState() => _CourseLabelDialogState();
}

class _CourseLabelDialogState extends State<_CourseLabelDialog> {
  late final _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Autre service'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        maxLength: kCourseLabelMaxChars,
        inputFormatters: [
          LengthLimitingTextInputFormatter(kCourseLabelMaxChars),
        ],
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: 'Nom du service',
          hintText: 'Ex. : Trou normand',
        ),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('Valider'),
        ),
      ],
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
