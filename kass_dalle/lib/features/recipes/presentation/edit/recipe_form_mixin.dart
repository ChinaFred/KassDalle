import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../../core/services/gemini_providers.dart';
import '../../../../core/services/cooklang_parser.dart'
    show extractIngredientsStructured;
import '../../domain/recipe.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/services/error_reporting.dart';

/// Mixin providing shared form state and logic for all recipe editing screens
/// (draft review, edit validated recipe, manual create).
///
/// Include on any [ConsumerState] that needs to edit recipe fields:
/// ```dart
/// class _MyState extends ConsumerState<MyWidget> with RecipeFormMixin<MyWidget> {
/// ```
mixin RecipeFormMixin<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  // ── Controllers ────────────────────────────────────────────────────────────
  final titleCtrl = TextEditingController();
  final cooklangCtrl = TextEditingController();
  final portionsCtrl = TextEditingController();
  final difficultyCtrl = TextEditingController();
  final prepTimeCtrl = TextEditingController();
  final cookTimeCtrl = TextEditingController();
  final restTimeCtrl = TextEditingController();
  final pageNumberCtrl = TextEditingController();

  // ── State ──────────────────────────────────────────────────────────────────
  List<RecipeIngredient> formIngredients = const [];
  String? selectedBookId;
  String? selectedBookTitre;
  bool formInitialized = false;
  bool saving = false;
  List<String> selectedCuisines = const [];
  List<String> selectedDishTypes = const [];

  // ── Lifecycle ──────────────────────────────────────────────────────────────
  @override
  void dispose() {
    titleCtrl.dispose();
    cooklangCtrl.dispose();
    portionsCtrl.dispose();
    difficultyCtrl.dispose();
    prepTimeCtrl.dispose();
    cookTimeCtrl.dispose();
    restTimeCtrl.dispose();
    pageNumberCtrl.dispose();
    super.dispose();
  }

  // ── Init ───────────────────────────────────────────────────────────────────

  /// Populate controllers from a [Recipe]. Call with [useDraft] = true for
  /// the draft review flow (reads draftCooklang first).
  void initFormFromRecipe(Recipe recipe, {bool useDraft = false}) {
    if (formInitialized) return;
    titleCtrl.text = recipe.titre;
    final raw = useDraft
        ? (recipe.draftCooklang ?? recipe.rawCooklang)
        : recipe.rawCooklang;
    cooklangCtrl.text = stripManagedMeta(raw);
    portionsCtrl.text = recipe.portions?.toString() ?? '';
    difficultyCtrl.text = recipe.tags.difficulty ?? '';
    prepTimeCtrl.text = recipe.tags.prepTime?.toString() ?? '';
    cookTimeCtrl.text = recipe.tags.cookTime?.toString() ?? '';
    restTimeCtrl.text = recipe.tags.restTime?.toString() ?? '';
    pageNumberCtrl.text = recipe.pageNumber?.toString() ?? '';
    // Un brouillon conçu par l'IA arrivait sans liste structurée : le texte
    // portait les ingrédients, le document non. Les lire ici plutôt que
    // d'afficher un onglet vide sous un CookLang qui en compte quinze.
    formIngredients = recipe.ingredients.isNotEmpty
        ? List<RecipeIngredient>.from(recipe.ingredients)
        : extractIngredientsStructured(raw);
    selectedBookId = recipe.bookId;
    selectedBookTitre = recipe.bookTitre;
    selectedCuisines = List<String>.from(recipe.tags.cuisines);
    selectedDishTypes = List<String>.from(recipe.tags.dishTypes);
    formInitialized = true;
  }

  /// Strip the metadata lines that are managed by form fields so they are not
  /// shown redundantly in the CookLang editor.
  /// They will be re-injected by [syncAllMetaFields] on save.
  String stripManagedMeta(String cooklang) {
    const keys =
        r'titre|portions|prep_time|cook_time|rest_time|temps_pr[eé]paration|temps_cuisson|temps_repos|repos|page_type|page_number|page';
    final pattern = RegExp(
      r'^>>\s*(' + keys + r')\s*:.*',
      caseSensitive: false,
      multiLine: true,
    );
    return cooklang
        .replaceAll(pattern, '')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();
  }

  // ── Setters (trigger setState) ─────────────────────────────────────────────

  void setIngredients(List<RecipeIngredient> v) =>
      setState(() => formIngredients = v);

  void setBook(String? id, String? titre) => setState(() {
    selectedBookId = id;
    selectedBookTitre = titre;
  });

  void setSaving(bool v) => setState(() => saving = v);

  void setCuisines(List<String> v) => setState(() => selectedCuisines = v);

  void setDishTypes(List<String> v) => setState(() => selectedDishTypes = v);

  // ── CookLang meta sync ─────────────────────────────────────────────────────

  /// Insert, replace or delete a `>> key: value` metadata line in CookLang text.
  String syncMetaLine(String cooklang, String key, String? value) {
    final lines = cooklang.split('\n');
    final newLine = value != null && value.isNotEmpty
        ? '>> $key: $value'
        : null;
    final pattern = RegExp(
      '^>>\\s*${RegExp.escape(key)}\\s*:',
      caseSensitive: false,
    );
    final idx = lines.indexWhere((l) => pattern.hasMatch(l.trim()));
    if (newLine == null) {
      if (idx >= 0) lines.removeAt(idx);
    } else if (idx >= 0) {
      lines[idx] = newLine;
    } else {
      final lastMeta = lines.lastIndexWhere((l) => l.trim().startsWith('>>'));
      lines.insert(lastMeta >= 0 ? lastMeta + 1 : 0, newLine);
    }
    return lines.join('\n');
  }

  /// Sync all structured fields (titre, portions, prep_time, cook_time) into
  /// the CookLang text.
  String syncAllMetaFields(String cooklang) {
    var c = cooklang;
    c = syncMetaLine(c, 'titre', titleCtrl.text.trim());
    c = syncMetaLine(
      c,
      'portions',
      portionsCtrl.text.trim().isEmpty ? null : portionsCtrl.text.trim(),
    );
    c = syncMetaLine(
      c,
      'prep_time',
      prepTimeCtrl.text.trim().isEmpty ? null : prepTimeCtrl.text.trim(),
    );
    c = syncMetaLine(
      c,
      'cook_time',
      cookTimeCtrl.text.trim().isEmpty ? null : cookTimeCtrl.text.trim(),
    );
    return c;
  }

  /// Build a [RecipeTags] from the current form state, keeping [baseTags]
  /// themes and occasions intact.
  RecipeTags buildTagsFromForm(RecipeTags baseTags) {
    return baseTags.copyWith(
      cuisines: selectedCuisines,
      dishTypes: selectedDishTypes,
      // Le rôle dans un repas n'a pas de champ dans le formulaire : il vient
      // de la base, ou de la dernière suggestion de l'IA dans cette session.
      // Un `null` laisse celui de la base — `copyWith` ne l'efface pas.
      mealRole: suggestedMealRole,
      contains: suggestedMealRole == null ? null : suggestedContains,
      suggestedSides: suggestedMealRole == null ? null : suggestedSidesByAI,
      difficulty: difficultyCtrl.text.trim().isEmpty
          ? null
          : difficultyCtrl.text.trim(),
      prepTime: int.tryParse(prepTimeCtrl.text.trim()),
      cookTime: int.tryParse(cookTimeCtrl.text.trim()),
      restTime: int.tryParse(restTimeCtrl.text.trim()),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// UID de l'utilisateur courant — essaie Firebase Auth en premier,
  /// puis le provider Riverpod (fallback pour le web après hot-reload).
  String get currentUid =>
      FirebaseAuth.instance.currentUser?.uid ??
      ref.read(appUserProvider).value?.uid ??
      '';

  // ── IA ─────────────────────────────────────────────────────────────────────

  bool suggestingTags = false;

  /// Le rôle dans un repas rendu par la dernière suggestion de l'IA, s'il y en
  /// a eu une dans cette session. Sans champ de formulaire, c'est le seul
  /// chemin par lequel une recette saisie à la main reçoit son rôle avant le
  /// backfill.
  String? suggestedMealRole;
  List<String> suggestedContains = const [];
  List<String> suggestedSidesByAI = const [];

  /// Suggère des tags (cuisine, type de plat, rôle dans un repas) via l'IA
  /// pour la recette dont le titre est [titre].
  Future<void> suggestTagsWithAI(String titre) async {
    setState(() => suggestingTags = true);
    try {
      final gemini = ref.read(geminiServiceProvider);
      final result = await gemini.suggestRecipeTags(
        titre: titre,
        cooklang: cooklangCtrl.text,
      );
      if (!mounted) return;
      setCuisines(result.cuisines);
      setDishTypes(result.dishTypes);
      if (result.mealRole != null) {
        suggestedMealRole = result.mealRole;
        suggestedContains = result.contains;
        suggestedSidesByAI = result.suggestedSides;
      }
      context.showSuccessSnackBar('Tags suggérés par l\'IA ✓');
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'recipeFormMixin.suggestTagsWithAI',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showErrorSnackBar('Erreur IA : $e');
      }
    } finally {
      if (mounted) setState(() => suggestingTags = false);
    }
  }
}
