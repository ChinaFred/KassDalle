import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../recipes/domain/recipe.dart';
import '../../recipes/presentation/cooklang_preview.dart';
import 'generated_recipe_illustrations.dart';
import '../../recipes/presentation/edit/ingredient_list_editor.dart';
import '../../recipes/presentation/editor/hybrid_recipe_editor.dart';
import '../../recipes/presentation/edit/recipe_form_mixin.dart';
import '../../recipes/presentation/edit/recipe_meta_panel.dart';
import '../../../core/services/cooklang_parser.dart';
import '../../../core/services/gemini_providers.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/widgets/error_message.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../../core/presentation/leave_guard.dart';
import '../../../core/presentation/stylus_pad_text_field.dart';
import '../../../core/widgets/app_shortcuts.dart';

// ── Écran de prévisualisation de la recette générée par l'IA ──────────────────

/// Relecture d'une recette créée par l'IA, avant son enregistrement.
///
/// La recette n'existe qu'en mémoire : « Enregistrer en brouillon » la range
/// dans « Mes créations Kass'Dalle ✨ », en brouillon, à relire. Quitter sans
/// l'enregistrer la perd : l'écran le demande avant.
class GeneratedRecipeScreen extends ConsumerStatefulWidget {
  final Recipe recipe;

  /// Enregistre la recette en brouillon et rend son identifiant.
  final Future<String> Function(Recipe) onSave;

  const GeneratedRecipeScreen({
    super.key,
    required this.recipe,
    required this.onSave,
  });

  @override
  ConsumerState<GeneratedRecipeScreen> createState() =>
      _GeneratedRecipeScreenState();
}

class _GeneratedRecipeScreenState extends ConsumerState<GeneratedRecipeScreen>
    with RecipeFormMixin<GeneratedRecipeScreen> {
  bool _saving = false;
  bool _refining = false;

  /// Images choisies avant l'enregistrement, en mémoire.
  ///
  /// La recette n'a pas encore d'identifiant : rien ne peut être écrit sur
  /// elle. Ces URL partent avec elle à l'enregistrement.
  List<String> _imageUrls = const [];
  late Recipe _currentRecipe;
  final _refineCtrl = TextEditingController();
  List<String>? _refineDiff;

  @override
  void initState() {
    super.initState();
    _currentRecipe = widget.recipe;
    initFormFromRecipe(widget.recipe);
    _leaveGuardNotifier = ref.read(leaveGuardProvider.notifier);
    _previousGuard = ref.read(leaveGuardProvider);
    // Après le rendu : un provider ne se modifie pas pendant la construction.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _leaveGuardNotifier.set(_leaveGuard);
    });
  }

  @override
  void dispose() {
    // Différé : un provider ne se modifie pas pendant le démontage de l'arbre.
    final notifier = _leaveGuardNotifier;
    final guard = _leaveGuard;
    final previous = _previousGuard;
    Future.microtask(() => notifier.restoreIf(guard, previous));
    _refineCtrl.dispose();
    super.dispose();
  }

  Recipe _buildCurrentRecipe() => Recipe(
    id: '',
    titre: titleCtrl.text.trim().isEmpty
        ? _currentRecipe.titre
        : titleCtrl.text.trim(),
    langue: _currentRecipe.langue,
    rawCooklang: cooklangCtrl.text,
    imageUrls: _imageUrls,
    reviewStatus: ReviewStatus.draft,
    tags: _currentRecipe.tags.copyWith(
      difficulty: difficultyCtrl.text.trim().isEmpty
          ? null
          : difficultyCtrl.text.trim(),
      prepTime: int.tryParse(prepTimeCtrl.text.trim()),
      cookTime: int.tryParse(cookTimeCtrl.text.trim()),
    ),
    ingredientsIndex: buildIngredientsIndex(formIngredients),
    createdBy: '',
    createdAt: DateTime.now(),
    updatedAt: DateTime.now(),
    portions: int.tryParse(portionsCtrl.text.trim()),
    ingredients: formIngredients,
    bookId: selectedBookId,
    bookTitre: selectedBookTitre,
  );

  /// Vrai une fois la recette enregistrée : quitter ne perd plus rien.
  bool _saved = false;

  bool get _canSave => !_saving && !_refining && !_saved;

  // Garde de sortie : la barre de navigation et le menu latéral appellent
  // `context.go`, que `PopScope` ne voit pas (voir `leave_guard.dart`).
  late final LeaveGuardNotifier _leaveGuardNotifier;
  late final LeaveGuard _leaveGuard = _confirmShellLeave;

  /// Le garde de l'écran du dessous (l'Explorer), rendu à la fermeture.
  LeaveGuard? _previousGuard;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final id = await widget.onSave(_buildCurrentRecipe());
      _saved = true;
      if (!mounted) return;
      // Le messager survit à la fermeture de l'écran : l'action « Ouvrir »
      // reste joignable depuis l'Explorer.
      final router = GoRouter.of(context);
      context.showSuccessSnackBar(
        'Brouillon enregistré dans « Mes créations Kass\'Dalle ✨ ».',
        action: SnackBarAction(
          label: 'Ouvrir',
          onPressed: () => router.push('${AppRoutes.drafts}/$id'),
        ),
      );
      Navigator.of(context).pop();
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'generatedRecipeScreen.save',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showFailureSnackBar('Brouillon non enregistré', e);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Demande confirmation avant de quitter une recette non enregistrée.
  /// Vrai quand l'écran peut être quitté.
  Future<bool> _confirmLeave() async {
    if (_saved) return true;
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Quitter sans enregistrer ?'),
        content: const Text('Cette recette créée par l\'IA sera perdue.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Rester'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Quitter'),
          ),
        ],
      ),
    );
    return leave == true;
  }

  /// La question posée quand la navigation du shell (barre, menu latéral)
  /// quitte l'écran : elle quitte aussi l'Explorer du dessous. Ctrl/Cmd+K,
  /// déjà sur l'Explorer, ne navigue pas et ne pose donc rien.
  ///
  /// Un seul dialogue. Si l'Explorer avait posé son garde, c'est sa question
  /// qui est posée : elle couvre cette recette et les autres idées non
  /// enregistrées. Sinon, celle de cet écran.
  Future<bool> _confirmShellLeave() {
    final previous = _previousGuard;
    if (previous != null) return previous();
    return _confirmLeave();
  }

  Future<void> _leaveAfterConfirmation() async {
    if (!await _confirmLeave() || !mounted) return;
    _saved = true; // la question est posée : le pop suivant passe
    Navigator.of(context).pop();
  }

  Future<void> _refine() async {
    final instruction = _refineCtrl.text.trim();
    if (instruction.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _refining = true);
    try {
      final gemini = ref.read(geminiServiceProvider);
      final raw = await gemini.refineRecipe(
        currentTitre: titleCtrl.text.trim().isEmpty
            ? _currentRecipe.titre
            : titleCtrl.text.trim(),
        currentCooklang: cooklangCtrl.text,
        currentIngredients: formIngredients
            .map((i) => {'name': i.name, 'qty': i.qty, 'unit': i.unit})
            .toList(),
        currentTags: {
          'themes': _currentRecipe.tags.themes,
          'cuisines': _currentRecipe.tags.cuisines,
          'difficulty': _currentRecipe.tags.difficulty,
          'prep_time': _currentRecipe.tags.prepTime,
          'cook_time': _currentRecipe.tags.cookTime,
        },
        currentPortions:
            int.tryParse(portionsCtrl.text.trim()) ?? _currentRecipe.portions,
        instruction: instruction,
      );

      final titre = raw['titre'] as String? ?? _currentRecipe.titre;
      final langue = raw['langue'] as String? ?? _currentRecipe.langue;
      final cooklang = raw['cooklang'] as String? ?? '';
      final ingredientsIndex = List<String>.from(
        raw['ingredients_index'] as List? ?? [],
      );
      final ingredientsRaw = raw['ingredients'] as List? ?? [];
      final ingredients = ingredientsRaw.map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        return RecipeIngredient(
          name: m['name'] as String? ?? '',
          qty: m['qty'] as String? ?? '',
          unit: m['unit'] as String? ?? '',
        );
      }).toList();
      final tagsRaw = Map<String, dynamic>.from(raw['tags'] as Map? ?? {});
      final tags = RecipeTags(
        themes: List<String>.from(tagsRaw['themes'] as List? ?? []),
        cuisines: List<String>.from(tagsRaw['cuisines'] as List? ?? []),
        occasions: List<String>.from(tagsRaw['occasions'] as List? ?? []),
        dishTypes: List<String>.from(tagsRaw['dish_types'] as List? ?? []),
        difficulty: tagsRaw['difficulty'] as String?,
        prepTime: _toInt(tagsRaw['prep_time']),
        cookTime: _toInt(tagsRaw['cook_time']),
      );
      final portions = _toInt(raw['portions']);

      final refined = Recipe(
        id: '',
        titre: titre,
        langue: langue,
        rawCooklang: cooklang,
        imageUrls: const [],
        reviewStatus: ReviewStatus.draft,
        tags: tags,
        ingredientsIndex: ingredientsIndex,
        createdBy: '',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        portions: portions,
        ingredients: ingredients,
      );

      // Capturer l'état avant les modifications pour le diff
      final oldTitle = titleCtrl.text.trim();
      final oldCooklang = cooklangCtrl.text;
      final oldPortions = int.tryParse(portionsCtrl.text.trim());
      final oldDifficulty = difficultyCtrl.text.trim().isEmpty
          ? null
          : difficultyCtrl.text.trim();
      final oldPrepTime = int.tryParse(prepTimeCtrl.text.trim());
      final oldCookTime = int.tryParse(cookTimeCtrl.text.trim());
      final oldIngredientNames = formIngredients
          .map((i) => i.name.toLowerCase())
          .toSet();

      titleCtrl.text = refined.titre;
      cooklangCtrl.text = refined.rawCooklang;
      portionsCtrl.text = refined.portions?.toString() ?? '';
      difficultyCtrl.text = refined.tags.difficulty ?? '';
      prepTimeCtrl.text = refined.tags.prepTime?.toString() ?? '';
      cookTimeCtrl.text = refined.tags.cookTime?.toString() ?? '';

      // Calculer le diff
      final diffs = <String>[];
      final newTitle = refined.titre.trim();
      if (newTitle != oldTitle) {
        diffs.add('Titre : "$oldTitle" → "$newTitle"');
      }
      if (refined.rawCooklang != oldCooklang) {
        diffs.add('Contenu de la recette modifié');
      }
      final newIngredientNames = refined.ingredients
          .map((i) => i.name.toLowerCase())
          .toSet();
      final added = newIngredientNames.difference(oldIngredientNames);
      final removed = oldIngredientNames.difference(newIngredientNames);
      if (added.isNotEmpty) {
        final preview = added.take(3).join(', ');
        diffs.add(
          'Ingrédient(s) ajouté(s) : $preview${added.length > 3 ? '…' : ''}',
        );
      }
      if (removed.isNotEmpty) {
        final preview = removed.take(3).join(', ');
        diffs.add(
          'Ingrédient(s) supprimé(s) : $preview${removed.length > 3 ? '…' : ''}',
        );
      }
      if (refined.portions != oldPortions) {
        diffs.add(
          'Portions : ${oldPortions ?? '—'} → ${refined.portions ?? '—'}',
        );
      }
      if (refined.tags.difficulty != oldDifficulty) {
        diffs.add(
          'Difficulté : ${oldDifficulty ?? '—'} → ${refined.tags.difficulty ?? '—'}',
        );
      }
      if (refined.tags.prepTime != oldPrepTime) {
        diffs.add(
          'Préparation : ${oldPrepTime != null ? '${oldPrepTime}min' : '—'} → ${refined.tags.prepTime != null ? '${refined.tags.prepTime}min' : '—'}',
        );
      }
      if (refined.tags.cookTime != oldCookTime) {
        diffs.add(
          'Cuisson : ${oldCookTime != null ? '${oldCookTime}min' : '—'} → ${refined.tags.cookTime != null ? '${refined.tags.cookTime}min' : '—'}',
        );
      }

      setState(() {
        _currentRecipe = refined;
        formIngredients = List<RecipeIngredient>.from(refined.ingredients);
        formInitialized = true;
        _refineDiff = diffs.isEmpty ? ['Aucune modification détectée'] : diffs;
      });
      _refineCtrl.clear();
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'generatedRecipeScreen.refine',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showErrorSnackBar(aiFailureMessage('Recette non améliorée', e));
      }
    } finally {
      if (mounted) setState(() => _refining = false);
    }
  }

  static int? _toInt(dynamic v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is double) return v.toInt();
    return int.tryParse(v.toString());
  }

  @override
  Widget build(BuildContext context) {
    final isWide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;
    final theme = Theme.of(context);
    final badge = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.smart_toy_outlined,
            size: AppIconSize.inline,
            color: theme.colorScheme.onPrimaryContainer,
          ),
          const SizedBox(width: 4),
          Text(
            'Générée par l\'IA',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
    final saveButton = FilledButton.icon(
      onPressed: _canSave ? _save : null,
      icon: _saving
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.save_outlined),
      label: const Text('Enregistrer en brouillon'),
    );
    final scaffold = Scaffold(
      appBar: AppBar(
        title: Text(
          titleCtrl.text.isEmpty ? _currentRecipe.titre : titleCtrl.text,
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Retour',
          onPressed: _leaveAfterConfirmation,
        ),
        // Sur téléphone, la pastille passe dans le corps et le bouton dans
        // une barre fixe en bas : la barre d'application n'a pas la place.
        actions: isWide
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Center(child: badge),
                ),
                saveButton,
                const SizedBox(width: 8),
              ]
            : null,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!isWide)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Align(alignment: Alignment.centerLeft, child: badge),
            ),
          if (_refineDiff != null) _buildDiffBanner(),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: isWide ? _buildWide() : _buildNarrow(),
            ),
          ),
          _buildRefineBar(context),
        ],
      ),
      bottomNavigationBar: isWide
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                child: saveButton,
              ),
            ),
    );
    return PopScope(
      canPop: _saved,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _leaveAfterConfirmation();
      },
      // Ctrl/Cmd+S enregistre, comme dans les autres écrans d'édition.
      child: AppShortcuts(onSave: _canSave ? _save : null, child: scaffold),
    );
  }

  Widget _buildDiffBanner() {
    final theme = Theme.of(context);
    final diffs = _refineDiff ?? [];
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.smart_toy_outlined,
            size: AppIconSize.inline,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Modifications apportées :',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSecondaryContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                ...diffs.map(
                  (d) => Text(
                    '• $d',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: AppIconSize.inline),
            tooltip: 'Masquer les modifications',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            color: theme.colorScheme.onSecondaryContainer,
            onPressed: () => setState(() => _refineDiff = null),
          ),
        ],
      ),
    );
  }

  Widget _buildRefineBar(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        8 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: _refining
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'L\'IA modifie la recette…',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: StylusPadTextField(
                    controller: _refineCtrl,
                    padTitle: 'Modifier la recette',
                    enabled: !_saving,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _refine(),
                    decoration: InputDecoration(
                      hintText:
                          'Modifier la recette… (ex : "rendre végétarienne", "doubler les portions")',
                      hintStyle: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      isDense: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: _saving ? null : _refine,
                  icon: const Icon(Icons.send_rounded),
                  tooltip: 'Envoyer à l\'IA',
                ),
              ],
            ),
    );
  }

  Widget _buildWide() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: PlatformUtils.sidePanelWidth,
          child: SingleChildScrollView(
            child: RecipeMetaPanel(
              titleCtrl: titleCtrl,
              portionsCtrl: portionsCtrl,
              difficultyCtrl: difficultyCtrl,
              prepTimeCtrl: prepTimeCtrl,
              cookTimeCtrl: cookTimeCtrl,
              restTimeCtrl: restTimeCtrl,
              pageNumberCtrl: pageNumberCtrl,
              saving: _saving || _refining,
              selectedBookId: null,
              onBookChanged: (_, _) {},
              showBookSelector: false,
              infoBookLabel: "Mes créations Kass'Dalle ✨",
            ),
          ),
        ),
        const SizedBox(width: 16),
        Expanded(child: _buildTabs()),
      ],
    );
  }

  /// Onglet photos, partagé par les deux dispositions.
  ///
  /// Un seul endroit le construit : deux copies finiraient par diverger, et
  /// c'est l'onglet le plus facile à oublier de mettre à jour.
  Widget _illustrationsTab() => GeneratedRecipeIllustrations(
    recipeTitle: titleCtrl.text.trim().isEmpty
        ? _currentRecipe.titre
        : titleCtrl.text.trim(),
    recipeContext: cooklangCtrl.text,
    imageUrls: _imageUrls,
    enabled: !_saving && !_refining,
    onChanged: (urls) => setState(() => _imageUrls = urls),
  );

  Widget _buildNarrow() {
    return DefaultTabController(
      length: 4,
      child: Column(
        children: [
          const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: 'Informations'),
              Tab(text: 'CookLang'),
              Tab(text: 'Ingrédients'),
              Tab(text: 'Photos'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                SingleChildScrollView(
                  padding: const EdgeInsets.only(top: 16),
                  child: RecipeMetaPanel(
                    titleCtrl: titleCtrl,
                    portionsCtrl: portionsCtrl,
                    difficultyCtrl: difficultyCtrl,
                    prepTimeCtrl: prepTimeCtrl,
                    cookTimeCtrl: cookTimeCtrl,
                    restTimeCtrl: restTimeCtrl,
                    pageNumberCtrl: pageNumberCtrl,
                    saving: _saving || _refining,
                    selectedBookId: null,
                    onBookChanged: (_, _) {},
                    showBookSelector: false,
                    infoBookLabel: "Mes créations Kass'Dalle ✨",
                  ),
                ),
                HybridRecipeEditor(
                  ctrl: cooklangCtrl,
                  enabled: !_saving && !_refining,
                  showHelp: true,
                  previewWidget: CooklangPreview(
                    ctrl: cooklangCtrl,
                    overrideIngredients: formIngredients,
                  ),
                ),
                SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: IngredientListEditor(
                    initialIngredients: formIngredients,
                    enabled: !_saving && !_refining,
                    onChanged: setIngredients,
                  ),
                ),
                _illustrationsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabs() {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          const TabBar(
            tabs: [
              Tab(text: 'CookLang'),
              Tab(text: 'Ingrédients'),
              Tab(text: 'Photos'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                HybridRecipeEditor(
                  ctrl: cooklangCtrl,
                  enabled: !_saving && !_refining,
                  showHelp: true,
                  previewWidget: CooklangPreview(
                    ctrl: cooklangCtrl,
                    overrideIngredients: formIngredients,
                  ),
                ),
                SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: IngredientListEditor(
                    initialIngredients: formIngredients,
                    enabled: !_saving && !_refining,
                    onChanged: setIngredients,
                  ),
                ),
                _illustrationsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
