import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/utils/context_extensions.dart';
import '../../../core/utils/platform_utils.dart';
import '../../recipes/domain/recipe.dart';
import '../../recipes/presentation/detail/shopping_list_sheet.dart';
import '../domain/planning_history.dart';
import '../../recipes/presentation/recipe_providers.dart';
import '../domain/calendar_event_description.dart';
import '../domain/meal_candidates.dart';
import '../domain/meal_component.dart';
import '../domain/meal_recipe_location.dart';
import '../domain/side_chooser.dart';
import 'meal_staples_providers.dart';
import '../domain/meal_storage_rules.dart';
import '../domain/planned_meal.dart';
import '../domain/planning_preferences.dart';
import '../domain/planning_week.dart';
import '../services/calendar_service.dart';
import 'planning_month_grid.dart';
import 'planning_providers.dart';
import 'planning_week_bar.dart';
import 'planning_widgets.dart';
import 'recipe_picker_sheet.dart';
import 'storage_advice_sheet.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../../core/theme/app_icons.dart';

class PlanningScreen extends ConsumerStatefulWidget {
  const PlanningScreen({super.key});

  @override
  ConsumerState<PlanningScreen> createState() => _PlanningScreenState();
}

class _PlanningScreenState extends ConsumerState<PlanningScreen>
    with SingleTickerProviderStateMixin {
  List<Recipe> _availableRecipes = [];
  bool _recipesLoaded = false;
  final Set<String> _aiLoadingIds = {};
  final Set<String> _storageLoadingIds = {};

  late final TabController _tabs = TabController(length: 2, vsync: this);

  /// Mois et jour affichés par l'onglet Calendrier.
  ///
  /// Ils vivent dans l'état de l'écran et nulle part ailleurs : choisir un mois
  /// à regarder n'est pas une donnée du planning, c'est une position de lecture.
  late DateTime _visibleMonth = PlanningMonthBand.monthOf(DateTime.now());
  late DateTime _selectedDay = PlanningMonthBand.dayOf(DateTime.now());

  /// Semaine lue par l'onglet Liste, par un jour repère.
  ///
  /// La semaine se recalcule à chaque construction : son premier jour dépend
  /// du jour de démarrage du cycle, lu dans les préférences, qui peuvent
  /// arriver après le premier affichage. Null tant qu'on n'a pas navigué :
  /// c'est alors la semaine d'aujourd'hui.
  DateTime? _weekAnchor;

  /// Vrai quand la liste montre toutes les semaines à la suite — la lecture
  /// d'avant, gardée derrière la puce « Tout ».
  bool _allWeeks = false;

  /// Mois d'archive déjà lus, et ceux en cours de lecture.
  ///
  /// Le flux temps réel s'arrête à quatre-vingt-dix jours — sans cette borne,
  /// l'écran relit à chaque ouverture la totalité des repas jamais planifiés,
  /// et la facture de lectures ne fait que croître. Les repas plus anciens
  /// existent pourtant toujours : rien ne les efface. Ils se lisent donc **à la
  /// demande**, un mois à la fois, quand on va les chercher — et une seule fois
  /// par mois visité.
  final Map<DateTime, List<PlannedMeal>> _archive = {};
  final Set<DateTime> _archiveLoading = {};

  /// Profondeur d'historique consultable dans le calendrier.
  ///
  /// Deux ans : assez pour retrouver ce qu'on cuisinait l'été dernier, assez
  /// court pour que la navigation vers le passé ait une fin. Sans borne, la
  /// flèche continuerait indéfiniment sur des mois vides.
  static const _archiveDepth = Duration(days: 730);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _loadRecipesIfNeeded() async {
    if (_recipesLoaded) return;
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return;
    try {
      final recipes = await repo.getValidatedRecipes();
      if (mounted) {
        setState(() {
          _availableRecipes = recipes;
          _recipesLoaded = true;
        });
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.loadRecipes',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showErrorSnackBar('Impossible de charger les recettes : $e');
      }
    }
  }

  /// La recette que [meal] perd si [newRecipeId] la remplace, ou null si le
  /// repas n'en avait pas ou garde la même. Elle rejoint les recettes écartées
  /// du repas, que l'IA ne repropose plus.
  String? _oustedBy(PlannedMeal meal, String? newRecipeId) {
    final current = meal.recipeId;
    if (current == null || current.isEmpty || current == newRecipeId) {
      return null;
    }
    return current;
  }

  /// L'accompagnement que le programme pose sur [recipe], depuis les
  /// garnitures du compte et les recettes d'accompagnement chargées.
  ///
  /// Rien tant que les garnitures ne sont pas lues : mieux vaut un repas sans
  /// accompagnement qu'un accompagnement au hasard.
  List<MealComponent> _composeComponents(Recipe recipe) {
    final staples = ref.read(myStaplesProvider).value;
    if (staples == null) return const [];
    final choice = chooseSide(
      main: recipe,
      candidates: sideCandidatesFrom(
        staples: staples,
        recipes: _availableRecipes,
      ),
    );
    return [?choice?.component];
  }

  Future<void> _changeRecipe(PlannedMeal meal) async {
    await _loadRecipesIfNeeded();
    if (!mounted) return;
    final recipe = await showModalBottomSheet<Recipe>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => RecipePickerSheet(
        recipes: _availableRecipes,
        dismissedRecipeIds: meal.dismissedRecipeIds.toSet(),
        hintText: 'Rechercher ou saisir un nom libre\u2026',
        freeNameAlways: true,
      ),
    );
    if (recipe == null || !mounted) return;
    final repo = ref.read(planningRepositoryProvider);
    final prepMinutes = recipe.tags.prepTime;
    final cookMinutes = recipe.tags.cookTime;
    final duration = (prepMinutes ?? 0) + (cookMinutes ?? 0);
    await repo?.updateMealRecipe(
      meal.id,
      recipeId: recipe.id.isEmpty ? null : recipe.id,
      recipeTitre: recipe.titre,
      durationMinutes: duration,
      prepMinutes: prepMinutes,
      cookMinutes: cookMinutes,
      basePortions: recipe.portions,
      targetPortions: meal.targetPortions ?? recipe.portions,
      dismissRecipeId: _oustedBy(meal, recipe.id),
      // Un autre plat, un autre accompagnement.
      components: _composeComponents(recipe),
    );
  }

  Future<void> _changeTime(PlannedMeal meal) async {
    final initial = TimeOfDay.fromDateTime(meal.plannedAt);
    final t = await showTimePicker(context: context, initialTime: initial);
    if (t == null || !mounted) return;
    final newTime = DateTime(
      meal.plannedAt.year,
      meal.plannedAt.month,
      meal.plannedAt.day,
      t.hour,
      t.minute,
    );
    final repo = ref.read(planningRepositoryProvider);
    await repo?.updateMealTime(meal.id, newTime);
  }

  Future<void> _exportAllToCalendar(List<PlannedMeal> meals) async {
    final now = DateTime.now();
    final futureMeals = meals
        .where(
          (m) => !m.plannedAt.isBefore(DateTime(now.year, now.month, now.day)),
        )
        .toList();
    if (futureMeals.isEmpty) {
      if (mounted) {
        context.showSnackBar('Aucun repas futur à exporter.');
      }
      return;
    }
    // Récupérer le token UNE SEULE FOIS pour éviter un popup OAuth par événement.
    final String token;
    try {
      token = await CalendarService.getToken();
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.exportAllToCalendar',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showSnackBar('Autorisation Calendar refusée : $e');
      }
      return;
    }
    final prefs = ref.read(planningPreferencesProvider).value;
    final calendarId = prefs?.calendarId ?? 'primary';
    final defaultDuration = prefs?.defaultCalendarDurationMinutes ?? 60;
    int exported = 0;
    for (final meal in futureMeals) {
      try {
        await CalendarService.createEvent(
          titre: meal.recipeTitre,
          startTime: meal.plannedAt,
          duration: Duration(minutes: defaultDuration),
          description: mealCalendarDescription(meal),
          reminderMinutes: meal.prepMinutes ?? 0,
          calendarId: calendarId,
          token: token,
        );
        exported++;
      } catch (error, stackTrace) {
        reportUnexpectedError(
          feature: 'planningScreen.exportAllToCalendar',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    if (mounted) {
      context.showSnackBar('$exported repas exportés vers le calendrier ✓');
    }
  }

  Future<void> _exportMealToCalendar(PlannedMeal meal) async {
    final prefs = ref.read(planningPreferencesProvider).value;
    final calendarId = prefs?.calendarId ?? 'primary';
    final defaultDuration = prefs?.defaultCalendarDurationMinutes ?? 60;
    try {
      await CalendarService.createEvent(
        titre: meal.recipeTitre,
        startTime: meal.plannedAt,
        duration: Duration(minutes: defaultDuration),
        description: mealCalendarDescription(meal),
        reminderMinutes: meal.prepMinutes ?? 0,
        calendarId: calendarId,
      );
      if (mounted) {
        context.showSnackBar('Repas ajouté au calendrier ✓');
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.exportMealToCalendar',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showSnackBar('Erreur : $e');
      }
    }
  }

  Future<void> _showIngredientsList(List<PlannedMeal> meals) async {
    final today = DateTime.now();
    // Les courses ne concernent que ce qui reste à cuisiner.
    final upcoming = meals
        .where(
          (m) => !m.plannedAt.isBefore(
            DateTime(today.year, today.month, today.day),
          ),
        )
        .toList();
    if (upcoming.isEmpty) {
      if (mounted) {
        context.showSnackBar('Aucun repas à venir dans le planning.');
      }
      return;
    }
    // Résoudre par identifiant : un repas peut pointer sur un brouillon ou une
    // recette de la famille, absente des recettes validées de l'utilisateur.
    final repo = ref.read(planningRepositoryProvider);
    // Les plats, et les recettes d'accompagnement des repas : une garniture
    // avec recette se compte comme le plat qu'elle accompagne.
    final ids = <String>[
      for (final m in upcoming) ...[
        if (m.recipeId != null) m.recipeId!,
        for (final c in m.components)
          if (c.isRecipe) c.recipeId!,
      ],
    ];
    final List<Recipe> resolved;
    try {
      resolved = await repo?.getRecipesByIds(ids) ?? const [];
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.showIngredientsList',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showErrorSnackBar('Impossible de charger les recettes : $e');
      }
      return;
    }
    if (!mounted) return;
    final recipesById = {for (final r in resolved) r.id: r};
    final missing = <String>[];
    final planningRecipes = <Recipe>[];
    // Les garnitures, multipliées par les parts du repas ; elles se fondent
    // dans les lignes des recettes — le riz d'une garniture et le riz d'une
    // recette font une seule ligne de courses.
    final extras = <PlanningExtraProduct>[];
    for (final meal in upcoming) {
      // Les composants d'abord : ils comptent même quand le plat est un repas
      // libre, sans recette.
      for (final c in meal.components) {
        if (c.isStaple) {
          final total = c.totalQuantityFor(meal.portionsForComponents);
          if (total == null) continue;
          extras.add((
            product: RecipeShoppingProduct(
              name: c.effectiveShoppingProduct,
              qty: total == total.truncateToDouble()
                  ? total.toInt().toString()
                  : total.toStringAsFixed(1),
              unit: c.unit ?? 'g',
            ),
            source: '${meal.recipeTitre} · ${c.role.label.toLowerCase()}',
          ));
        } else if (c.isRecipe) {
          final side = recipesById[c.recipeId!];
          if (side == null) {
            missing.add(c.label);
            continue;
          }
          planningRecipes.add(
            planningScaleRecipeForMeal(
              recipe: side,
              basePortions: side.portions,
              targetPortions: meal.portionsForComponents,
            ),
          );
        }
      }
      final recipeId = meal.recipeId;
      if (recipeId == null) continue;
      final recipe = recipesById[recipeId];
      if (recipe == null) {
        missing.add(meal.recipeTitre);
        continue;
      }
      planningRecipes.add(
        planningScaleRecipeForMeal(
          recipe: recipe,
          basePortions: meal.basePortions,
          targetPortions: meal.targetPortions,
        ),
      );
    }
    if (planningRecipes.isEmpty && extras.isEmpty) {
      if (mounted) {
        context.showSnackBar(
          'Aucune recette avec ingrédients dans le planning.',
        );
      }
      return;
    }
    // Une recette introuvable ne doit pas disparaître sans un mot : sinon la
    // liste paraît complète alors qu'il y manque un repas entier.
    if (missing.isNotEmpty) {
      context.showSnackBar(
        'Recette introuvable, ingrédients non comptés : ${missing.join(', ')}',
      );
    }
    final aggregated = planningAggregateProducts(
      planningRecipes,
      extras: extras,
    );
    final uid = ref.read(planningRepositoryProvider)?.uid ?? '';
    if (!mounted) return;
    await showShoppingListSheet(
      context,
      aggregated.products,
      const [],
      'Planning',
      uid,
      ingredientSources: aggregated.sources,
    );
  }

  Future<void> _clearRecipe(PlannedMeal meal) async {
    final repo = ref.read(planningRepositoryProvider);
    await repo?.updateMealRecipe(
      meal.id,
      recipeId: null,
      recipeTitre: 'Repas libre',
      durationMinutes: 0,
      clearPortions: true,
      dismissRecipeId: _oustedBy(meal, null),
      // Sans plat, pas d'accompagnement.
      components: const [],
    );
  }

  Future<void> _suggestRecipeWithAI(PlannedMeal meal) async {
    await _loadRecipesIfNeeded();
    if (!mounted) return;
    if (_availableRecipes.isEmpty) {
      context.showSnackBar('Aucune recette disponible pour l\'IA.');
      return;
    }
    // Ni la recette en place, ni celles déjà écartées de ce repas : l'IA ne
    // voit que ce qu'elle a le droit de proposer.
    final candidates = candidatesForMeal(
      _availableRecipes,
      currentRecipeId: meal.recipeId,
      dismissedRecipeIds: meal.dismissedRecipeIds,
    );
    if (candidates.isEmpty) {
      context.showSnackBar(
        'Toutes les recettes disponibles ont déjà été écartées pour ce repas.',
      );
      return;
    }
    setState(() => _aiLoadingIds.add(meal.id));
    try {
      final prefs =
          ref.read(planningPreferencesProvider).value ??
          const PlanningPreferences();
      // La fenêtre de variété regarde les repas servis avant ce jour-là, lus
      // dans ce que l'écran affiche déjà : aucune lecture de plus.
      final recentlyServed = recentlyServedBefore(
        ref.read(plannedMealsProvider).value ?? const [],
        cycleStart: meal.plannedAt,
        windowWeeks: prefs.varietyWindowWeeks,
      );
      final result = await ref
          .read(planningAiServiceProvider)
          .suggestMealPlan(
            recipes: candidates,
            slotDates: [meal.plannedAt],
            dailyConstraints: prefs.dailyConstraints,
            globalConstraints: prefs.globalConstraints,
            batchCookingDay: prefs.batchCookingDay,
            recentlyServed: recentlyServed,
          );
      final suggestions = result.slots;
      if (!mounted) return;
      if (suggestions.isNotEmpty && suggestions[0].recipe != null) {
        final suggestion = suggestions[0];
        final recipe = suggestion.recipe!;
        final repo = ref.read(planningRepositoryProvider);
        final duration =
            (recipe.tags.prepTime ?? 0) + (recipe.tags.cookTime ?? 0);
        await repo?.updateMealRecipe(
          meal.id,
          recipeId: recipe.id.isEmpty ? null : recipe.id,
          recipeTitre: recipe.titre,
          durationMinutes: duration,
          prepMinutes: recipe.tags.prepTime,
          cookMinutes: recipe.tags.cookTime,
          basePortions: recipe.portions,
          targetPortions: meal.targetPortions ?? recipe.portions,
          dismissRecipeId: _oustedBy(meal, recipe.id),
          components: _composeComponents(recipe),
        );
        if (mounted) {
          final why = (suggestion.justification ?? '').trim();
          final resized = suggestion.wasResized
              ? ' · redimensionnée'
              : ' · non redimensionnée';
          final explain = why.isNotEmpty ? ' — $why' : '';
          context.showSnackBar(
            '\'${recipe.titre}\' suggéré par l\'IA$resized$explain ✓',
          );
        }
      } else if (mounted) {
        context.showSnackBar('L\'IA n\'a pas trouvé de suggestion.');
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.suggestRecipeWithAI',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showErrorSnackBar('Erreur IA : $e');
      }
    } finally {
      if (mounted) setState(() => _aiLoadingIds.remove(meal.id));
    }
  }

  /// Affiche le conseil de conservation d'un repas, en le produisant s'il
  /// manque.
  ///
  /// Un conseil déjà produit ne se repaie pas : il appartient au plat, pas au
  /// repas, et sert donc à toutes ses planifications.
  Future<void> _showStorageAdvice(PlannedMeal meal) async {
    final recipeId = meal.recipeId;
    if (recipeId == null || recipeId.isEmpty) return;
    setState(() => _storageLoadingIds.add(meal.id));
    try {
      final advice = await ref
          .read(storageRepositoryProvider)
          .ensure(recipeId: recipeId);
      if (!mounted) return;
      final daysAhead = meal.prepDate == null
          ? 0
          : mealStorageDaysAhead(
              prepDate: meal.prepDate!,
              mealDate: meal.plannedAt,
            );
      await showStorageAdviceSheet(
        context,
        titre: meal.recipeTitre,
        advice: advice,
        daysAhead: daysAhead,
      );
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.showStorageAdvice',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showErrorSnackBar('Erreur conservation : $e');
      }
    } finally {
      if (mounted) setState(() => _storageLoadingIds.remove(meal.id));
    }
  }

  Future<void> _deleteMeal(PlannedMeal meal) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer ce repas ?'),
        content: Text(
          '« ${meal.recipeTitre} » du ${DateFormat('d MMMM à HH:mm', 'fr').format(meal.plannedAt)} sera supprimé du planning.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final repo = ref.read(planningRepositoryProvider);
    await repo?.deleteMeal(meal.id);
  }

  @override
  Widget build(BuildContext context) {
    final mealsAsync = ref.watch(plannedMealsProvider);
    // Garder le provider de préférences vivant pour que ref.read() dans les
    // callbacks d'export ait toujours la valeur Firestore à jour.
    ref.watch(planningPreferencesProvider);
    // Les garnitures aussi : « Changer la recette » compose l'accompagnement
    // depuis ce que le compte a sous la main, lu ici pour être prêt.
    ref.watch(myStaplesProvider);
    final theme = Theme.of(context);
    final isWide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Planning des repas'),
        centerTitle: false,
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(icon: Icon(Icons.view_agenda_outlined), text: 'Liste'),
            Tab(icon: Icon(Icons.calendar_month_outlined), text: 'Calendrier'),
          ],
        ),
        actions: [
          if (isWide) ...[
            // Le « tirer pour rafraîchir » du corps n'existe pas à la souris.
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: 'Actualiser le planning',
              onPressed: _refreshMeals,
            ),
            if (mealsAsync.value?.isNotEmpty == true) ...[
              IconButton(
                icon: const Icon(Icons.shopping_cart_outlined),
                tooltip: 'Liste des ingrédients',
                onPressed: () => _showIngredientsList(mealsAsync.value!),
              ),
              // La même icône que sur chaque repas et chaque créneau : un
              // geste, une icône. Elle reste distincte du calendrier de
              // l'onglet juste en dessous, qui sert à voir, pas à envoyer.
              IconButton(
                icon: const Icon(AppIcons.calendarExport),
                tooltip: 'Exporter le planning vers le calendrier',
                onPressed: () => _exportAllToCalendar(mealsAsync.value!),
              ),
            ],
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: 'Paramètres du planning',
              onPressed: () => context.push('/planning/config'),
            ),
          ] else ...[
            PopupMenuButton<int>(
              tooltip: 'Actions',
              onSelected: (value) {
                if (value == 0) context.push('/planning/config');
                if (value == 1 && mealsAsync.value?.isNotEmpty == true) {
                  _showIngredientsList(mealsAsync.value!);
                }
                if (value == 2 && mealsAsync.value?.isNotEmpty == true) {
                  _exportAllToCalendar(mealsAsync.value!);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 0,
                  child: ListTile(
                    leading: Icon(Icons.settings_outlined),
                    title: Text('Paramètres'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                if (mealsAsync.value?.isNotEmpty == true) ...[
                  const PopupMenuItem(
                    value: 1,
                    child: ListTile(
                      leading: Icon(Icons.shopping_cart_outlined),
                      title: Text('Liste des ingrédients'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  const PopupMenuItem(
                    value: 2,
                    child: ListTile(
                      leading: Icon(AppIcons.calendarExport),
                      title: Text('Exporter vers le calendrier'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/planning/batch'),
        icon: const Icon(Icons.auto_awesome_outlined),
        label: const Text('Nouveau planning'),
      ),
      body: RefreshIndicator(
        onRefresh: _refreshMeals,
        child: mealsAsync.when(
          loading: () => const AppLoadingState(),
          error: (e, _) => AppErrorState(error: e, onRetry: _refreshMeals),
          data: (meals) => TabBarView(
            controller: _tabs,
            children: [
              _buildList(context, theme, meals, isWide),
              _buildMonth(context, theme, meals, isWide),
            ],
          ),
        ),
      ),
    );
  }

  /// Onglet « Liste » : la lecture chronologique, inchangée.
  Widget _buildList(
    BuildContext context,
    ThemeData theme,
    List<PlannedMeal> meals,
    bool isWide,
  ) {
    if (meals.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.calendar_today_outlined,
                size: AppIconSize.hero,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.4,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Aucun repas planifié',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 24),
              // Bouton principal
              FilledButton.icon(
                onPressed: () => context.push('/planning/batch'),
                icon: const Icon(Icons.auto_awesome_outlined),
                label: const Text('Générer un nouveau planning'),
              ),
              const SizedBox(height: 12),
              // Accès direct aux préférences
              OutlinedButton.icon(
                onPressed: () => context.push('/planning/config'),
                icon: const Icon(Icons.tune_outlined),
                label: const Text('Configurer mes préférences'),
              ),
              const SizedBox(height: 24),
              Text(
                'Vous pouvez aussi planifier un repas isolé\ndepuis la page d\'une recette (icône 📅).',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Regrouper par date (sans heure)
    final grouped = <DateTime, List<PlannedMeal>>{};
    for (final meal in meals) {
      final day = DateTime(
        meal.plannedAt.year,
        meal.plannedAt.month,
        meal.plannedAt.day,
      );
      (grouped[day] ??= []).add(meal);
    }

    // La semaine lue, et celles qu'on peut atteindre. La liste partait de
    // quatre-vingt-dix jours en arrière : la semaine à cuisiner arrivait après
    // trois écrans de repas passés.
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final cycleStartDay =
        ref.watch(planningPreferencesProvider).value?.cycleStartDay ??
        DateTime.friday;
    final selectedWeek = planningWeekOf(
      _weekAnchor ?? today,
      cycleStartDay: cycleStartDay,
    );
    final weeks = planningWeeksFor(
      mealDays: grouped.keys,
      today: today,
      cycleStartDay: cycleStartDay,
      alsoCover: [selectedWeek.start],
    );
    // En lecture continue, seuls les jours qui portent un repas ; en lecture
    // par semaine, les sept jours, vides compris — un jour libre est une
    // information, et l'endroit où poser une recette.
    final days = _allWeeks
        ? (grouped.keys.toList()..sort())
        : selectedWeek.days;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: PlanningWeekBar(
            weeks: weeks,
            selected: selectedWeek,
            allSelected: _allWeeks,
            today: today,
            isWide: isWide,
            onSelect: (week) => setState(() {
              _weekAnchor = week.start;
              _allWeeks = false;
            }),
            onSelectAll: () => setState(() => _allWeeks = true),
          ),
        ),
        Expanded(
          child: ListView.builder(
            // La marge du bas laisse passer la dernière ligne sous le bouton
            // « Nouveau planning » : sans elle, il couvrait l'icône d'export
            // du dernier repas, et rien ne permettait de descendre plus bas.
            padding: const EdgeInsets.fromLTRB(0, 8, 0, 96),
            itemCount: days.length,
            itemBuilder: (context, index) {
              final day = days[index];
              final dayMeals = grouped[day] ?? const <PlannedMeal>[];
              final isToday = _isToday(day);
              final isPast = day.isBefore(today);

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PlanningDayHeader(day: day, isToday: isToday, isPast: isPast),
                  if (dayMeals.isEmpty)
                    PlanningEmptyDayRow(
                      isPast: isPast,
                      onPick: isPast ? null : () => _addMealOnDay(day),
                    ),
                  ...dayMeals.map(
                    (meal) => PlanningMealTile(
                      meal: meal,
                      isPast: isPast,
                      aiLoading:
                          _aiLoadingIds.contains(meal.id) ||
                          _storageLoadingIds.contains(meal.id),
                      isWide: isWide,
                      onDelete: () => _deleteMeal(meal),
                      onChangeRecipe: () => _changeRecipe(meal),
                      onClearRecipe: () => _clearRecipe(meal),
                      onSuggestWithAI: () => _suggestRecipeWithAI(meal),
                      onStorageAdvice: () => _showStorageAdvice(meal),
                      onTimeChanged: () => _changeTime(meal),
                      onExportToCalendar: () => _exportMealToCalendar(meal),
                      onTap: _openRecipeFor(meal),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  /// Pose une recette sur un jour libre de la semaine lue.
  ///
  /// Le repas prend l'heure et les parts de son jour de semaine, comme dans
  /// « Nouveau planning » ; l'heure se change ensuite d'un appui sur le repas.
  Future<void> _addMealOnDay(DateTime day) async {
    await _loadRecipesIfNeeded();
    if (!mounted) return;
    final recipe = await showModalBottomSheet<Recipe>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => RecipePickerSheet(
        recipes: _availableRecipes,
        hintText: 'Rechercher ou saisir un nom libre\u2026',
        freeNameAlways: true,
      ),
    );
    if (recipe == null || !mounted) return;
    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return;
    final prefs =
        ref.read(planningPreferencesProvider).value ??
        const PlanningPreferences();
    final time = prefs.mealTimeFor(day.weekday);
    final constraint = prefs.dailyConstraints[day.weekday];
    final targetPortions = (constraint?.targetPortions ?? 0) > 0
        ? constraint!.targetPortions
        : recipe.portions;
    final prepMinutes = recipe.tags.prepTime;
    final cookMinutes = recipe.tags.cookTime;
    try {
      await repo.addMeal(
        PlannedMeal(
          id: '',
          uid: repo.uid,
          recipeId: recipe.id.isEmpty ? null : recipe.id,
          recipeTitre: recipe.titre,
          plannedAt: DateTime(
            day.year,
            day.month,
            day.day,
            time.hour,
            time.minute,
          ),
          durationMinutes: (prepMinutes ?? 0) + (cookMinutes ?? 0),
          prepMinutes: prepMinutes,
          cookMinutes: cookMinutes,
          basePortions: recipe.portions,
          targetPortions: targetPortions,
          components: _composeComponents(recipe),
          createdAt: DateTime.now(),
        ),
      );
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.addMealOnDay',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) context.showErrorSnackBar('Repas non enregistré : $e');
    }
  }

  /// Onglet « Calendrier » : la grille du mois, puis l'agenda du jour choisi.
  ///
  /// Aucun document n'est créé pour cette vue, et aucune requête ne lui est
  /// propre : elle range par jour les repas déjà chargés par le stream. Un mois
  /// est une lecture, pas un porteur.
  Widget _buildMonth(
    BuildContext context,
    ThemeData theme,
    List<PlannedMeal> live,
    bool isWide,
  ) {
    final selected = PlanningMonthBand.dayOf(_selectedDay);
    final today = PlanningMonthBand.dayOf(DateTime.now());

    // Le flux temps réel ne remonte que quatre-vingt-dix jours ; les mois plus
    // anciens sont lus à la demande. On les réunit ici, en écartant les
    // doublons : un mois d'archive peut chevaucher le flux.
    final meals = <String, PlannedMeal>{
      for (final m in live) m.id: m,
      for (final month in _archive.values)
        for (final m in month) m.id: m,
    }.values.toList();

    final dayMeals =
        meals
            .where((m) => PlanningMonthBand.dayOf(m.plannedAt) == selected)
            .toList()
          ..sort((a, b) => a.plannedAt.compareTo(b.plannedAt));

    // Un plat préparé un autre jour occupe AUSSI son jour de préparation :
    // c'est ce jour-là qu'on cuisine, et l'oublier ferait mentir la vue sur la
    // charge réelle de la semaine.
    final dayPrepared = meals.where((m) {
      final prep = m.prepDate;
      return prep != null && PlanningMonthBand.dayOf(prep) == selected;
    }).toList();

    final isPast = selected.isBefore(today);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // La bande garde une hauteur imposée : le calendrier est un repère, le
        // détail du jour est ce qu'on lit. L'inverse donnait des cases de deux
        // cents pixels et une journée hors de l'écran.
        SizedBox(
          height: PlanningMonthBand.bandHeight(context),
          child: PlanningMonthBand(
            month: _visibleMonth,
            selectedDay: selected,
            meals: meals,
            earliestMonth: PlanningMonthBand.monthOf(
              today.subtract(_archiveDepth),
            ),
            // Choisir un jour dans un mois latéral ne déplace pas la bande :
            // le regard vient d'y aller, la faire sauter le perdrait.
            onSelectDay: (day) => setState(() => _selectedDay = day),
            onMonthChanged: (month) {
              setState(() => _visibleMonth = month);
              _loadArchiveAround(month);
            },
          ),
        ),
        const PlanningMonthLegend(),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 96),
            children: [
              PlanningDayHeader(
                day: selected,
                isToday: selected == today,
                isPast: isPast,
              ),
              if (dayMeals.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Text(
                    dayPrepared.isEmpty
                        ? 'Aucun repas ce jour-là.'
                        : 'Aucun repas servi ce jour-là — mais de la cuisine à faire.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              else
                ...dayMeals.map(
                  (meal) => PlanningMealTile(
                    meal: meal,
                    isPast: isPast,
                    aiLoading:
                        _aiLoadingIds.contains(meal.id) ||
                        _storageLoadingIds.contains(meal.id),
                    isWide: isWide,
                    onDelete: () => _deleteMeal(meal),
                    onChangeRecipe: () => _changeRecipe(meal),
                    onClearRecipe: () => _clearRecipe(meal),
                    onSuggestWithAI: () => _suggestRecipeWithAI(meal),
                    onStorageAdvice: () => _showStorageAdvice(meal),
                    onTimeChanged: () => _changeTime(meal),
                    onExportToCalendar: () => _exportMealToCalendar(meal),
                    onTap: _openRecipeFor(meal),
                  ),
                ),
              // Ce qui se prépare ce jour-là pour être mangé plus tard : la grille le
              // signale par une pastille creuse, l'agenda dit quoi et pour quand.
              if (dayPrepared.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.soup_kitchen_outlined,
                        size: AppIconSize.inline,
                        color: theme.colorScheme.tertiary,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'À préparer ce jour-là',
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: theme.colorScheme.tertiary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                ...dayPrepared.map(
                  (meal) => ListTile(
                    dense: true,
                    leading: const Icon(
                      Icons.schedule_outlined,
                      size: AppIconSize.small,
                    ),
                    title: Text(meal.recipeTitre),
                    subtitle: Text(
                      'pour le ${DateFormat('EEEE d MMMM', 'fr').format(meal.plannedAt)}',
                    ),
                    onTap: _openRecipeFor(meal),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// Charge, si besoin, les mois d'archive que la bande va montrer.
  ///
  /// La bande affiche trois mois : celui qu'on regarde, et ses deux voisins.
  /// Charger les trois évite qu'un mois latéral s'affiche vide alors qu'il
  /// contient des repas — un vide qui ressemblerait à une semaine sans cuisine.
  void _loadArchiveAround(DateTime month) {
    for (final m in [
      DateTime(month.year, month.month - 1),
      month,
      DateTime(month.year, month.month + 1),
    ]) {
      _loadArchiveMonth(m);
    }
  }

  /// Lit un mois d'archive, une seule fois.
  ///
  /// Les mois couverts par le flux temps réel ne sont pas relus : ils arrivent
  /// déjà, et les relire les paierait deux fois.
  Future<void> _loadArchiveMonth(DateTime month) async {
    final key = PlanningMonthBand.monthOf(month);
    if (_archive.containsKey(key) || _archiveLoading.contains(key)) return;

    final today = PlanningMonthBand.dayOf(DateTime.now());
    final liveFrom = today.subtract(PlanningRepository.historyWindow);
    final lastDay = DateTime(key.year, key.month + 1, 0);
    if (!lastDay.isBefore(liveFrom)) return;
    if (key.isBefore(
      PlanningMonthBand.monthOf(today.subtract(_archiveDepth)),
    )) {
      return;
    }

    final repo = ref.read(planningRepositoryProvider);
    if (repo == null) return;

    _archiveLoading.add(key);
    try {
      final meals = await repo.getMealsBetween(from: key, to: lastDay);
      if (!mounted) return;
      setState(() => _archive[key] = meals);
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningScreen.loadArchiveMonth',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showErrorSnackBar('Historique du mois illisible : $e');
      }
    } finally {
      _archiveLoading.remove(key);
    }
  }

  /// Recharge le planning : geste de rafraîchissement et bouton Réessayer.
  Future<void> _refreshMeals() async {
    ref.invalidate(plannedMealsProvider);
    await ref.read(plannedMealsProvider.future);
  }

  /// Ouvre la fiche recette du repas, ou rien s'il n'en a pas.
  ///
  /// Le contexte du repas voyage dans l'adresse — voir [mealRecipeLocation] :
  /// la même route sert au lien collé dans l'événement Google Calendar.
  VoidCallback? _openRecipeFor(PlannedMeal meal) {
    final location = mealRecipeLocation(meal);
    return location == null ? null : () => context.push(location);
  }

  bool _isToday(DateTime day) {
    final now = DateTime.now();
    return day.year == now.year && day.month == now.month && day.day == now.day;
  }
}
