import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../../core/services/gemini_providers.dart';
import '../../../../core/services/cooklang_parser.dart'
    show extractIngredientsStructured;
import '../../domain/meal_role.dart';
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

  /// Rôle dans un repas tel que le formulaire le montre : celui de la base à
  /// l'ouverture, puis ce que l'utilisateur choisit dans la liste ou ce que
  /// « Suggérer les tags » a posé. `null` : non classé.
  String? selectedMealRole;

  /// Protéine et féculent principaux tels que le formulaire les montre :
  /// ceux de la base à l'ouverture (si le rôle de la base les porte), puis le
  /// choix de l'utilisateur ou ce que « Suggérer les tags » a posé. `null` :
  /// « Non renseigné », que le backfill reprendra.
  String? selectedMainProtein;
  String? selectedMainStarch;

  /// Ce que la recette apporte (`tags.contains`) tel que le formulaire le
  /// montre : celui de la base à l'ouverture, puis les pastilles « Ce que la
  /// recette apporte », le féculent principal, ou « Suggérer les tags ».
  List<String> selectedContains = const [];

  /// Vrai dès que [selectedContains] a été corrigé à la main, ou quand la base
  /// porte déjà une correction (`contains_manual`) : le modèle ne le réécrit
  /// plus, ni ici ni côté serveur.
  bool containsManual = false;

  /// Marqueur d'examen (`main_ingredients_checked_at`) que l'enregistrement
  /// écrira. Celui de la base à l'ouverture ; l'heure du choix quand
  /// l'utilisateur a renseigné les deux champs ; `null` dès que l'un des deux
  /// est remis à « Non renseigné », pour que le backfill le propose.
  DateTime? mainIngredientsCheckedAt;

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
    selectedMealRole = recipe.tags.hasMealRole ? recipe.tags.mealRole : null;
    // Une valeur restée d'un ancien rôle (une entrée qui était un plat) n'est
    // pas reprise : elle ne vaut plus, et l'enregistrement la retire.
    final carries = recipe.tags.carriesMainIngredients;
    selectedMainProtein = carries ? recipe.tags.mainProtein : null;
    selectedMainStarch = carries ? recipe.tags.mainStarch : null;
    mainIngredientsCheckedAt = carries
        ? recipe.tags.mainIngredientsCheckedAt
        : null;
    selectedContains = List<String>.from(recipe.tags.contains);
    containsManual = recipe.tags.containsManual;
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

  void setMealRole(String? v) => setState(() => selectedMealRole = v);

  /// Choix à la main de la protéine principale ; `null` : « Non renseigné ».
  void setMainProtein(String? v) => setState(() {
    selectedMainProtein = v;
    _markMainIngredientsChosenByHand();
  });

  /// Choix à la main du féculent principal ; `null` : « Non renseigné ».
  ///
  /// Un féculent coche « Féculent » dans ce que la recette apporte, « Sans
  /// féculent » le décoche : c'est alors une correction à la main.
  void setMainStarch(String? v) => setState(() {
    selectedMainStarch = v;
    _markMainIngredientsChosenByHand();
    final next = mealContainsWithStarch(selectedContains, v);
    if (!_sameContains(next, selectedContains)) {
      selectedContains = next;
      containsManual = true;
    }
  });

  /// Correction à la main de ce que la recette apporte (pastilles Protéine,
  /// Féculent, Légume).
  void setContains(List<String> v) => setState(() {
    selectedContains = orderedMealContains(v);
    containsManual = true;
  });

  static bool _sameContains(List<String> a, List<String> b) =>
      a.length == b.length && a.toSet().containsAll(b);

  /// Les deux champs renseignés : la recette est examinée, le backfill la
  /// saute. Un seul renseigné : pas de marqueur, le backfill demande au
  /// modèle celui qui manque et ne remplace pas l'autre.
  void _markMainIngredientsChosenByHand() {
    mainIngredientsCheckedAt =
        selectedMainProtein != null && selectedMainStarch != null
        ? DateTime.now()
        : null;
  }

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
    final tags = baseTags.copyWith(
      cuisines: selectedCuisines,
      dishTypes: selectedDishTypes,
      // Le rôle est celui de la liste du formulaire, ce que la recette
      // apporte celui des pastilles, avec son marqueur de correction. Les
      // accompagnements classiques ne se saisissent pas : ils viennent de la
      // base, ou de la dernière suggestion de l'IA dans cette session — un
      // `null` laisse ceux de la base, `copyWith` n'efface pas.
      mealRole: selectedMealRole,
      contains: selectedContains,
      containsManual: containsManual,
      suggestedSides: aiClassifiedInSession ? suggestedSidesByAI : null,
      difficulty: difficultyCtrl.text.trim().isEmpty
          ? null
          : difficultyCtrl.text.trim(),
      prepTime: int.tryParse(prepTimeCtrl.text.trim()),
      cookTime: int.tryParse(cookTimeCtrl.text.trim()),
      restTime: int.tryParse(restTimeCtrl.text.trim()),
    );
    if (selectedMealRole != null) {
      // La protéine et le féculent sont ceux du formulaire, `null` compris :
      // « Non renseigné » retire le champ. Un rôle qui ne les porte pas
      // (entrée, dessert, snack) les retire tous les deux, avec le marqueur.
      final carries = kRolesWithMainIngredients.contains(selectedMealRole);
      return tags.withMainIngredients(
        mainProtein: carries ? selectedMainProtein : null,
        mainStarch: carries ? selectedMainStarch : null,
        mainIngredientsCheckedAt: carries ? mainIngredientsCheckedAt : null,
      );
    }
    // « Non classé » : le rôle part, et ce qui en dépendait avec lui.
    // `copyWith` ne sait pas effacer ; on reconstruit sans les cinq champs
    // (rôle, apports, accompagnements, protéine, féculent),
    // et `toMap` ne les écrit pas — une écriture de la carte entière les
    // retire, une écriture champ par champ passe par `clearMealRole`.
    return RecipeTags(
      themes: tags.themes,
      cuisines: tags.cuisines,
      occasions: tags.occasions,
      dishTypes: tags.dishTypes,
      difficulty: tags.difficulty,
      prepTime: tags.prepTime,
      cookTime: tags.cookTime,
      restTime: tags.restTime,
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

  /// Vrai dès que « Suggérer les tags » a rendu un rôle dans cette session :
  /// [suggestedSidesByAI] vaut alors pour la recette et remplace celui de la
  /// base à l'enregistrement.
  bool aiClassifiedInSession = false;
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
        setState(() {
          selectedMealRole = result.mealRole;
          aiClassifiedInSession = true;
          // Une correction à la main de ce que la recette apporte n'est
          // jamais remplacée par le modèle.
          selectedContains = mealContainsAfterSuggestion(
            manual: containsManual,
            current: selectedContains,
            suggested: result.contains,
          );
          suggestedSidesByAI = result.suggestedSides;
          // La suggestion remplit les deux listes. Une réponse vide ou hors
          // liste laisse la valeur du formulaire, choisie à la main ou lue
          // en base. Le marqueur suit le modèle quand il a répondu : le
          // backfill ne requestionnera pas la recette.
          selectedMainProtein = result.mainProtein ?? selectedMainProtein;
          selectedMainStarch = result.mainStarch ?? selectedMainStarch;
          if (result.mainIngredientsChecked) {
            mainIngredientsCheckedAt = DateTime.now();
          }
        });
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
