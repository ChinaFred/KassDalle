import 'package:flutter/material.dart';
import '../../domain/recipe.dart';

/// Mixin providing shared form state and logic for all recipe editing screens
/// (draft review, edit validated recipe, manual create).
///
/// Include on any [ConsumerState] that needs to edit recipe fields:
/// ```dart
/// class _MyState extends ConsumerState<MyWidget> with RecipeFormMixin<MyWidget> {
/// ```
mixin RecipeFormMixin<T extends StatefulWidget> on State<T> {
  // ── Controllers ────────────────────────────────────────────────────────────
  final titleCtrl = TextEditingController();
  final cooklangCtrl = TextEditingController();
  final portionsCtrl = TextEditingController();
  final difficultyCtrl = TextEditingController();
  final prepTimeCtrl = TextEditingController();
  final cookTimeCtrl = TextEditingController();
  final pageNumberCtrl = TextEditingController();

  // ── State ──────────────────────────────────────────────────────────────────
  List<RecipeIngredient> formIngredients = const [];
  String? selectedBookId;
  String? selectedBookTitre;
  bool formInitialized = false;
  bool saving = false;

  // ── Lifecycle ──────────────────────────────────────────────────────────────
  @override
  void dispose() {
    titleCtrl.dispose();
    cooklangCtrl.dispose();
    portionsCtrl.dispose();
    difficultyCtrl.dispose();
    prepTimeCtrl.dispose();
    cookTimeCtrl.dispose();
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
    cooklangCtrl.text = _stripManagedMeta(raw);
    portionsCtrl.text = recipe.portions?.toString() ?? '';
    difficultyCtrl.text = recipe.tags.difficulty ?? '';
    prepTimeCtrl.text = recipe.tags.prepTime?.toString() ?? '';
    cookTimeCtrl.text = recipe.tags.cookTime?.toString() ?? '';
    pageNumberCtrl.text = recipe.pageNumber?.toString() ?? '';
    formIngredients = List<RecipeIngredient>.from(recipe.ingredients);
    selectedBookId = recipe.bookId;
    selectedBookTitre = recipe.bookTitre;
    formInitialized = true;
  }

  /// Strip the metadata lines that are managed by form fields so they are not
  /// shown redundantly in the CookLang editor.
  /// They will be re-injected by [syncAllMetaFields] on save.
  String _stripManagedMeta(String cooklang) {
    const keys =
        r'titre|portions|prep_time|cook_time|temps_pr[eé]paration|temps_cuisson';
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
  /// themes/cuisines/occasions intact.
  RecipeTags buildTagsFromForm(RecipeTags baseTags) {
    return baseTags.copyWith(
      difficulty: difficultyCtrl.text.trim().isEmpty
          ? null
          : difficultyCtrl.text.trim(),
      prepTime: int.tryParse(prepTimeCtrl.text.trim()),
      cookTime: int.tryParse(cookTimeCtrl.text.trim()),
    );
  }
}
