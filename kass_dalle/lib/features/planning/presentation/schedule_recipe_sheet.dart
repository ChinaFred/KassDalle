import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../recipes/domain/recipe.dart';
import '../domain/calendar_event_description.dart';
import '../domain/meal_component.dart';
import '../domain/side_chooser.dart';
import '../domain/meal_recipe_location.dart';
import '../domain/meal_choice_source.dart';
import '../domain/planned_meal.dart';
import '../domain/planning_criteria.dart';
import '../domain/planning_preferences.dart';
import '../domain/planning_target.dart';
import '../services/calendar_service.dart';
import '../../groups/presentation/group_providers.dart';
import 'meal_composer.dart';
import 'meal_staples_providers.dart';
import 'planning_providers.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/utils/duration_format.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../../core/theme/app_icons.dart';

/// Ouvre le bottom sheet de planification pour une recette.
Future<void> showScheduleRecipeSheet(
  BuildContext context, {
  required String titre,
  String? recipeId,
  required int? prepTimeMin,
  required int? cookTimeMin,
  required List<RecipeIngredient> ingredients,
  int? portions,
  Recipe? recipe,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => _ScheduleSheet(
      titre: titre,
      recipeId: recipeId,
      prepTimeMin: prepTimeMin,
      cookTimeMin: cookTimeMin,
      ingredients: ingredients,
      portions: portions,
      recipe: recipe,
    ),
  );
}

// ── Sheet ──────────────────────────────────────────────────────────────────────

class _ScheduleSheet extends ConsumerStatefulWidget {
  final String titre;
  final String? recipeId;
  final int? prepTimeMin;
  final int? cookTimeMin;
  final List<RecipeIngredient> ingredients;

  /// Parts de la recette, pour un repas de groupe : les quantités se
  /// recalculent des parts de la recette vers celles du groupe.
  final int? portions;

  /// La recette planifiée : le programme en tire ses accompagnements
  /// (`chooseSides`). Absente, la ligne « Accompagnement » n'apparaît pas.
  final Recipe? recipe;

  const _ScheduleSheet({
    required this.titre,
    this.recipeId,
    required this.prepTimeMin,
    required this.cookTimeMin,
    required this.ingredients,
    this.portions,
    this.recipe,
  });

  @override
  ConsumerState<_ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends ConsumerState<_ScheduleSheet> {
  late DateTime _selectedDate;
  TimeOfDay? _selectedTime;
  late TextEditingController _reminderCtrl;
  bool _loading = false;

  /// Le planning où le repas s'inscrit : « Mon planning » par défaut, ou un
  /// groupe dont l'utilisateur est le propriétaire.
  PlanningTarget _target = const PlanningTarget.personal();

  /// Recettes d'accompagnement possibles : les recettes validées du compte et
  /// celles, non privées, des autres membres de la famille — les mêmes
  /// sources que « Composer le repas » depuis le planning. Lues à
  /// l'ouverture ; `null` tant qu'elles ne le sont pas.
  List<Recipe>? _sideRecipes;

  /// La ligne « Accompagnement » ne vaut que pour un plat, ou une recette pas
  /// encore classée : un dessert, une entrée, un accompagnement n'en reçoit
  /// pas.
  bool get _composable {
    final tags = widget.recipe?.tags;
    if (tags == null) return false;
    return !tags.hasMealRole || tags.mealRole == 'plat';
  }

  /// Les accompagnements du repas : choisis par le programme dès que
  /// garnitures et recettes sont lues, puis changés dans « Composer le
  /// repas ». `null` tant qu'ils ne sont pas calculés.
  List<MealComponent>? _sides;

  /// L'échec de lecture des garnitures a été signalé.
  bool _staplesErrorReported = false;

  /// Préférences de planning, ou les valeurs par défaut tant qu'elles chargent.
  PlanningPreferences get _prefs =>
      ref.watch(planningPreferencesProvider).value ??
      const PlanningPreferences();

  /// Heure retenue : le choix de l'utilisateur, sinon l'heure configurée.
  TimeOfDay get _effectiveTime =>
      _selectedTime ??
      TimeOfDay(hour: _prefs.defaultMealHour, minute: _prefs.defaultMealMinute);

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedDate = DateTime(now.year, now.month, now.day);
    _reminderCtrl = TextEditingController(text: '${widget.prepTimeMin ?? 30}');
    if (_composable) _loadSideRecipes();
  }

  /// Lit les recettes validées du compte, puis celles de la famille hors
  /// livres privés, pour les accompagnements. Chaque échec est signalé ; le
  /// programme choisit alors parmi ce qui a pu être lu, garnitures comprises.
  Future<void> _loadSideRecipes() async {
    final repo = ref.read(planningRepositoryProvider);
    var own = const <Recipe>[];
    var family = const <Recipe>[];
    try {
      own = await repo?.getValidatedRecipes() ?? const [];
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'scheduleRecipeSheet.loadSideRecipes',
        error: e,
        stackTrace: stackTrace,
      );
    }
    if (repo != null) {
      try {
        final familyIds = (ref.read(groupMemberIdsProvider).value ?? {})
            .where((id) => id != repo.uid)
            .toList();
        family = await repo.getFamilyValidatedRecipes(familyIds);
      } catch (e, stackTrace) {
        reportUnexpectedError(
          feature: 'scheduleRecipeSheet.loadFamilySideRecipes',
          error: e,
          stackTrace: stackTrace,
        );
      }
    }
    final seen = <String>{};
    if (mounted) {
      setState(
        () => _sideRecipes = [
          for (final r in [...own, ...family])
            if (seen.add(r.id)) r,
        ],
      );
    }
  }

  /// Les accompagnements à afficher et à enregistrer : ceux déjà calculés ou
  /// choisis, sinon ceux du programme dès que tout est lu.
  List<MealComponent>? _currentSides() {
    final current = _sides;
    if (current != null) return current;
    final recipe = widget.recipe;
    if (!_composable || recipe == null) return null;
    final staples = ref.read(myStaplesProvider).value;
    final recipes = _sideRecipes;
    if (staples == null || recipes == null) return null;
    final chosen = [
      for (final c in chooseSides(
        main: recipe,
        candidates: sideCandidatesFrom(staples: staples, recipes: recipes),
        criteria: _criteria,
      ))
        c.component,
    ];
    _sides = chosen;
    return chosen;
  }

  /// Les critères compris des préférences du jour choisi : un
  /// accompagnement qui viole une exclusion n'est pas proposé.
  PlanningCriteria get _criteria => criteriaForDay(
    prefs:
        ref.read(planningPreferencesProvider).value ??
        const PlanningPreferences(),
    translations:
        ref.read(planningConstraintTranslationsProvider).value ?? const {},
    date: _selectedDate,
  );

  /// « Changer » : l'éditeur « Composer le repas », sur ce repas pas encore
  /// créé. Le plat ne change pas ; rien n'est écrit avant « Ajouter au
  /// planning ».
  Future<void> _changeSides() async {
    final recipe = widget.recipe;
    final sides = _currentSides();
    if (recipe == null || sides == null) return;
    await showMealComposer(
      context,
      load: () async =>
          MealComposerData(main: recipe, recipes: _sideRecipes ?? const []),
      sides: sides,
      // La feuille ne compose que l'accompagnement : le menu se fait depuis
      // le planning, une fois le repas créé.
      allowMenu: false,
      mealDate: _selectedDate,
      canChangeRecipe: false,
      successMessage: null,
      criteria: _criteria,
      onSave: (composition) async {
        if (mounted) setState(() => _sides = composition.sides);
      },
    );
  }

  @override
  void dispose() {
    _reminderCtrl.dispose();
    super.dispose();
  }

  int get _totalDurationMin =>
      (widget.prepTimeMin ?? 0) + (widget.cookTimeMin ?? 0);

  // ── Sélecteurs ──────────────────────────────────────────────────────────────

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) setState(() => _selectedDate = picked);
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _effectiveTime,
    );
    if (picked != null) setState(() => _selectedTime = picked);
  }

  // ── Action principale ────────────────────────────────────────────────────────

  /// « Ajouté à votre planning », « Ajouté au planning de Famille Dupont ».
  String get _addedTo => _target.isGroup
      ? 'Ajouté au planning de ${_target.groupName}'
      : 'Ajouté à votre planning';

  /// Enregistre le repas au planning choisi, puis pose l'événement dans
  /// Google Calendar.
  ///
  /// Le planning d'abord : un agenda qui refuse (autorisation, réseau) ne
  /// fait plus perdre le repas. Chaque échec a son message, qui nomme le
  /// planning visé.
  Future<void> _addToCalendar() async {
    setState(() => _loading = true);
    final prefs = _prefs;
    final time = _effectiveTime;
    final start = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      time.hour,
      time.minute,
    );
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      final repo = ref.read(planningRepositoryProvider);
      if (uid == null || repo == null) {
        throw StateError('Utilisateur non connecté.');
      }
      // Un repas de groupe se cuisine pour le groupe : ses parts par défaut
      // (réglées, sinon le nombre de membres), comme un jour libre du
      // planning.
      final group = _target.isGroup
          ? ref
                .read(ownedPlanningGroupsProvider)
                .value
                ?.where((g) => g.id == _target.groupId)
                .firstOrNull
          : null;
      await repo.addMeal(
        PlannedMeal(
          id: '',
          uid: uid,
          groupId: _target.groupId,
          recipeId: widget.recipeId,
          recipeTitre: widget.titre,
          plannedAt: start,
          durationMinutes: _totalDurationMin,
          prepMinutes: widget.prepTimeMin,
          cookMinutes: widget.cookTimeMin,
          basePortions: group == null ? null : widget.portions,
          targetPortions: group == null
              ? null
              : groupDefaultPortions(
                  groupPortions: prefs.groupPortions,
                  group: group,
                ),
          choiceSource: MealChoiceSource.manual,
          components: _currentSides() ?? const [],
          createdAt: DateTime.now(),
        ),
      );
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'scheduleRecipeSheet.addMeal',
        error: e,
        stackTrace: stackTrace,
        context: {'group_id': ?_target.groupId},
      );
      if (mounted) {
        setState(() => _loading = false);
        // Le détail part au rapport d'erreurs, pas à l'écran.
        context.showErrorSnackBar('Repas non enregistré. Réessayez.');
      }
      return;
    }

    final reminder =
        int.tryParse(_reminderCtrl.text.trim()) ?? (widget.prepTimeMin ?? 30);
    try {
      // L'événement dure la durée par défaut des préférences : dans le
      // calendrier, le repas est le moment où l'on mange, pas celui où l'on
      // prépare. Les temps de la recette servent au rappel et à la durée
      // affichée dans le planning.
      await CalendarService.createEvent(
        titre: widget.titre,
        startTime: start,
        duration: Duration(minutes: prefs.defaultCalendarDurationMinutes),
        description: _buildDescription(),
        reminderMinutes: reminder,
        calendarId: prefs.calendarId,
      );
      if (mounted) {
        Navigator.of(context).pop();
        context.showSuccessSnackBar('$_addedTo et à l\'agenda.');
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'scheduleRecipeSheet.addToCalendar',
        error: e,
        stackTrace: stackTrace,
        context: {'group_id': ?_target.groupId},
      );
      if (mounted) {
        // Le repas est enregistré : la feuille se ferme, et le message dit
        // ce qui manque.
        Navigator.of(context).pop();
        context.showErrorSnackBar(
          '$_addedTo. L\'agenda n\'a pas reçu l\'événement.',
        );
      }
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

  Widget _buildSidesRow() {
    // Abonné ici : les garnitures arrivent après l'ouverture.
    final staples = ref.watch(myStaplesProvider);
    // Lu par les accompagnements proposés : gardé ouvert avec la feuille.
    ref.watch(planningConstraintTranslationsProvider);
    final sides = _currentSides();
    // Garnitures illisibles : le repas s'ajoute quand même, sans
    // accompagnement. Le flux ne remonte pas son erreur : on la signale ici,
    // une fois.
    final unavailable = sides == null && staples.hasError;
    if (unavailable && !_staplesErrorReported) {
      _staplesErrorReported = true;
      reportUnexpectedError(
        feature: 'scheduleRecipeSheet.loadStaples',
        error: staples.error!,
        stackTrace: staples.stackTrace,
      );
    }
    return _PickerRow(
      icon: Icons.rice_bowl_outlined,
      label: 'Accompagnement',
      value: unavailable
          ? 'Accompagnements indisponibles'
          : sides == null
          ? 'Calcul…'
          : sides.isEmpty
          ? 'Aucun'
          : componentsSummary(sides),
      actionLabel: 'Changer',
      onTap: sides == null || _loading ? null : _changeSides,
    );
  }

  String _buildDescription() {
    final lines = <String>[];
    if (widget.prepTimeMin != null) {
      lines.add('⏱ Préparation : ${widget.prepTimeMin} min');
    }
    if (widget.cookTimeMin != null) {
      lines.add('🔥 Cuisson : ${widget.cookTimeMin} min');
    }
    if (widget.ingredients.isNotEmpty) {
      lines
        ..add('')
        ..add('🛒 Ingrédients :');
      for (final ing in widget.ingredients) {
        final qty = [
          ing.qty,
          ing.unit,
        ].where((s) => s.isNotEmpty).join('\u00a0');
        lines.add('• ${ing.name}${qty.isNotEmpty ? '  ($qty)' : ''}');
      }
    }
    final recipeId = widget.recipeId;
    return buildCalendarDescription(
      recipeLocation: recipeId == null || recipeId.isEmpty
          ? null
          : recipeLocationFor(recipeId: recipeId),
      details: lines,
    );
  }

  String _formatDate(DateTime d) {
    const days = ['lun.', 'mar.', 'mer.', 'jeu.', 'ven.', 'sam.', 'dim.'];
    const months = [
      'jan.',
      'fév.',
      'mars',
      'avr.',
      'mai',
      'juin',
      'juil.',
      'août',
      'sep.',
      'oct.',
      'nov.',
      'déc.',
    ];
    return '${days[d.weekday - 1]} ${d.day} ${months[d.month - 1]} ${d.year}';
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // La ligne « Planning » n'apparaît qu'à qui possède au moins un groupe :
    // sans elle, le repas va dans « Mon planning », comme avant.
    final ownedGroups =
        ref.watch(ownedPlanningGroupsProvider).value ?? const [];
    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 32,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Titre
          Row(
            children: [
              Icon(
                Icons.calendar_month_outlined,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Planifier : ${widget.titre}',
                  style: theme.textTheme.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Divider(color: theme.colorScheme.outlineVariant),
          const SizedBox(height: 8),

          if (ownedGroups.isNotEmpty) ...[
            PopupMenuButton<PlanningTarget>(
              tooltip: 'Choisir le planning',
              initialValue: _target,
              onSelected: (target) => setState(() => _target = target),
              itemBuilder: (_) => [
                for (final target in [
                  const PlanningTarget.personal(),
                  for (final g in ownedGroups) PlanningTarget.ofGroup(g),
                ])
                  PopupMenuItem(
                    value: target,
                    child: ListTile(
                      leading: Icon(
                        target.isGroup
                            ? Icons.groups_outlined
                            : Icons.calendar_today_outlined,
                      ),
                      title: Text(target.title),
                      subtitle: target.subtitle == null
                          ? null
                          : Text(target.subtitle!),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
              ],
              child: _PickerRow(
                icon: _target.isGroup
                    ? Icons.groups_outlined
                    : Icons.calendar_today_outlined,
                label: 'Planning',
                value: _target.title,
              ),
            ),
            const SizedBox(height: 4),
          ],

          // Date
          _PickerRow(
            icon: Icons.event_outlined,
            label: 'Date',
            value: _formatDate(_selectedDate),
            onTap: _pickDate,
          ),
          const SizedBox(height: 4),

          // Heure
          _PickerRow(
            icon: Icons.schedule_outlined,
            label: 'Heure de début',
            value: _effectiveTime.format(context),
            onTap: _pickTime,
          ),
          const SizedBox(height: 4),

          // Accompagnement : choisi par le programme, changé dans l'éditeur.
          if (_composable) ...[_buildSidesRow(), const SizedBox(height: 4)],

          // Durée (informative)
          if (_totalDurationMin > 0) ...[
            _InfoRow(
              icon: Icons.timer_outlined,
              label: 'Durée estimée',
              value: formatDurationMinutes(_totalDurationMin),
            ),
            const SizedBox(height: 4),
          ],

          const SizedBox(height: 8),

          // Rappel
          Row(
            children: [
              Icon(
                Icons.notifications_outlined,
                size: AppIconSize.small,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Rappel', style: theme.textTheme.bodyMedium),
              ),
              SizedBox(
                width: 72,
                child: TextField(
                  controller: _reminderCtrl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(
                    suffixText: 'min',
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text('avant', style: theme.textTheme.bodySmall),
            ],
          ),

          const SizedBox(height: 24),

          // Bouton principal
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _loading ? null : _addToCalendar,
              icon: _loading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(AppIcons.calendarExport),
              label: const Text('Ajouter au planning et à l\'agenda'),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Helpers de layout ──────────────────────────────────────────────────────────

class _PickerRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  /// Null quand un menu englobant reçoit l'appui (ligne « Planning »).
  final VoidCallback? onTap;

  /// Libellé en bout de ligne à la place du chevron : « Changer ».
  final String? actionLabel;

  const _PickerRow({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
    this.actionLabel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Row(
        children: [
          Icon(
            icon,
            size: AppIconSize.small,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Text(label, style: theme.textTheme.bodyMedium),
          const SizedBox(width: 12),
          // Un nom de groupe long se coupe au lieu de déborder.
          Expanded(
            child: Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.end,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 4),
          if (actionLabel != null)
            Text(
              actionLabel!,
              style: theme.textTheme.labelLarge?.copyWith(
                color: onTap == null
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.primary,
              ),
            )
          else
            Icon(
              Icons.chevron_right,
              size: AppIconSize.small,
              color: theme.colorScheme.onSurfaceVariant,
            ),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: row,
    );
  }
}

class _InfoRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _InfoRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
      child: Row(
        children: [
          Icon(
            icon,
            size: AppIconSize.small,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Text(label, style: theme.textTheme.bodyMedium),
          const Spacer(),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
