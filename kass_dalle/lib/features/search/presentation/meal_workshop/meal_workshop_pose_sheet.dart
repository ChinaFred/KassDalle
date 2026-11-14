import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart' show FirebaseException;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/presentation/adaptive_sheet.dart';
import '../../../../core/services/error_reporting.dart';
import '../../../../core/theme/app_icon_size.dart';
import '../../../../core/theme/app_icons.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../../core/utils/platform_utils.dart';
import '../../../../core/utils/short_date_format.dart';
import '../../../../core/widgets/app_states.dart';
import '../../../admin/presentation/admin_providers.dart'
    show errorReportServiceProvider;
import '../../../groups/domain/family_group.dart';
import '../../../planning/domain/meal_component.dart' show MealComponentRole;
import '../../../planning/domain/planned_meal.dart';
import '../../../planning/domain/planning_preferences.dart';
import '../../../planning/domain/planning_target.dart';
import '../../../planning/presentation/planning_providers.dart';
import '../../../planning/presentation/schedule_rows.dart';
import '../../../recipes/domain/recipe.dart';
import '../../../recipes/presentation/detail/portions_input_dialog.dart';
import '../../domain/meal_workshop_freeze.dart';
import '../../domain/meal_workshop_menu.dart';
import '../../domain/meal_workshop_pose.dart';
import 'meal_workshop_providers.dart';

/// Jours au plus dans le futur pour poser un repas : les bornes de
/// « Replanifier » du planning.
const int kWorkshopPoseMaxDays = 730;

/// Ce que la boîte rend après une pose réussie.
class WorkshopPoseResult {
  final DateTime plannedAt;
  final PlanningTarget target;

  const WorkshopPoseResult({required this.plannedAt, required this.target});
}

/// La boîte « Poser dans le planning » : feuille du bas sur téléphone, boîte
/// de 480 px au plus sur grand écran. Rend la pose faite, ou `null` si elle
/// est fermée sans poser.
///
/// La boîte s'ouvre sur [portions], les parts de l'atelier. Chaque choix de
/// parts fait dans la boîte est rendu aussitôt par [onPortionsChanged], que
/// la pose ait lieu ou non : l'atelier reprend la valeur dans son en-tête.
Future<WorkshopPoseResult?> showWorkshopPoseSheet(
  BuildContext context, {
  required WorkshopMenu menu,
  required List<FreezeLineState> lines,
  required MealWorkshopContext workshop,
  required int portions,
  ValueChanged<int>? onPortionsChanged,
}) => showAdaptiveSheet<WorkshopPoseResult>(
  context,
  maxWidth: 480,
  // Le glisser fermerait la feuille pendant l'écriture sans passer par le
  // `PopScope` : « Annuler » la ferme.
  enableDrag: false,
  child: WorkshopPoseSheet(
    menu: menu,
    lines: lines,
    workshop: workshop,
    portions: portions,
    onPortionsChanged: onPortionsChanged,
  ),
);

/// Le contenu de la boîte : récapitulatif des services, planning, date,
/// heure, parts, jour occupé, puis « Poser ». Deux lectures (la recette du
/// plat principal, les repas du jour visé) et une écriture
/// (`PlanningRepository.addMeal`). Aucun appel d'IA.
class WorkshopPoseSheet extends ConsumerStatefulWidget {
  final WorkshopMenu menu;
  final List<FreezeLineState> lines;
  final MealWorkshopContext workshop;

  /// Les parts à l'ouverture : celles de l'atelier.
  final int portions;

  /// Appelé à chaque changement de parts dans la boîte.
  final ValueChanged<int>? onPortionsChanged;

  const WorkshopPoseSheet({
    super.key,
    required this.menu,
    required this.lines,
    required this.workshop,
    required this.portions,
    this.onPortionsChanged,
  });

  @override
  ConsumerState<WorkshopPoseSheet> createState() => _WorkshopPoseSheetState();
}

class _WorkshopPoseSheetState extends ConsumerState<WorkshopPoseSheet> {
  PlanningTarget _target = const PlanningTarget.personal();
  late DateTime _date;

  /// L'heure choisie à la main ; `null` tant qu'elle suit le jour de
  /// semaine (`mealTimeFor`).
  TimeOfDay? _time;

  /// Les parts du repas posé (`target_portions`) : celles de l'atelier à
  /// l'ouverture, puis celles choisies dans la boîte.
  late int _portions = widget.portions;

  // ── La recette du plat principal ──
  late final String? _mainRecipeId = workshopMainRecipeId(
    widget.menu,
    widget.lines,
  );
  bool _mainRead = false;
  Object? _mainError;
  Recipe? _mainRecipe;

  // ── Les repas du jour visé ──
  bool _dayLoading = false;
  bool _dayError = false;
  List<PlannedMeal>? _dayMeals;
  int _dayToken = 0;

  bool _writing = false;

  /// Le message de la dernière pose refusée, répété dans la boîte : sur
  /// téléphone, le snack passe sous la feuille. Effacé au prochain appui sur
  /// « Poser » et au changement de date ou de planning.
  String? _poseError;

  WorkshopMenu get _menu => widget.menu;
  int get _mainIndex => workshopMainCourseIndex(_menu);

  PlanningPreferences get _prefs =>
      ref.watch(planningPreferencesProvider).value ??
      const PlanningPreferences();

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _date = DateTime(now.year, now.month, now.day);
    _readMain();
    _readDay();
  }

  // ── Lectures ─────────────────────────────────────────────────────────────

  Future<void> _readMain() async {
    final id = _mainRecipeId;
    if (id == null) {
      setState(() => _mainRead = true);
      return;
    }
    setState(() {
      _mainRead = false;
      _mainError = null;
    });
    try {
      final recipe = await ref
          .read(mealWorkshopDraftRepositoryProvider)
          .readForPose(id);
      if (!mounted) return;
      setState(() {
        _mainRecipe = recipe;
        _mainRead = true;
      });
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'mealWorkshop.pose.readMain',
        error: error,
        stackTrace: stackTrace,
        context: {'recipe_id': id},
        service: ref.read(errorReportServiceProvider),
      );
      if (!mounted) return;
      setState(() {
        _mainError = error;
        _mainRead = true;
      });
    }
  }

  /// Les repas du planning visé ce jour-là. Rend la liste lue, ou `null` en
  /// échec ; l'état de la boîte suit la dernière lecture lancée.
  Future<List<PlannedMeal>?> _readDay() async {
    final token = ++_dayToken;
    final repo = ref.read(planningRepositoryProvider);
    setState(() {
      _dayLoading = true;
      _dayError = false;
    });
    List<PlannedMeal>? meals;
    try {
      if (repo == null) throw StateError('Utilisateur non connecté.');
      meals = await repo.getMealsBetween(
        from: _date,
        to: _date,
        groupId: _target.groupId,
      );
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'mealWorkshop.pose.readDay',
        error: error,
        stackTrace: stackTrace,
        context: {'group_id': ?_target.groupId},
        service: ref.read(errorReportServiceProvider),
      );
      meals = null;
    }
    if (!mounted || token != _dayToken) return meals;
    setState(() {
      _dayLoading = false;
      if (meals == null) {
        _dayError = true;
      } else {
        _dayMeals = meals;
      }
    });
    return meals;
  }

  // ── Sélecteurs ───────────────────────────────────────────────────────────

  TimeOfDay get _effectiveTime {
    final chosen = _time;
    if (chosen != null) return chosen;
    final t = _prefs.mealTimeFor(_date.weekday);
    return TimeOfDay(hour: t.hour, minute: t.minute);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _date.isBefore(today) ? today : _date,
      firstDate: today,
      lastDate: today.add(const Duration(days: kWorkshopPoseMaxDays)),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _date = DateTime(picked.year, picked.month, picked.day);
      _dayMeals = null;
      _poseError = null;
    });
    unawaited(_readDay());
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _effectiveTime,
    );
    if (picked != null && mounted) setState(() => _time = picked);
  }

  Future<void> _pickPortions() async {
    final value = await showPortionsInputDialog(
      context,
      current: _portions,
      minPortions: 1,
      maxPortions: 99,
      title: 'Nombre de parts',
      unit: 'parts',
    );
    if (value == null || !mounted) return;
    _setPortions(value);
  }

  void _setPortions(int value) {
    if (value == _portions) return;
    setState(() => _portions = value);
    widget.onPortionsChanged?.call(value);
  }

  void _selectTarget(PlanningTarget target) {
    if (target == _target) return;
    setState(() {
      _target = target;
      _dayMeals = null;
      _poseError = null;
    });
    unawaited(_readDay());
  }

  // ── Poser ────────────────────────────────────────────────────────────────

  bool get _canPose => !_writing && _mainRead && _mainError == null;

  /// « Poser » / « Ajouter quand même » : la lecture du jour est d'abord
  /// rejouée (P2-11) ; un repas apparu depuis l'affichage — écrit côté
  /// serveur malgré une coupure — est montré au lieu d'être doublé. Puis le
  /// repas est écrit par le dépôt du planning.
  Future<void> _pose() async {
    if (!_canPose) return;
    setState(() {
      _writing = true;
      _poseError = null;
    });
    final known = {for (final m in _dayMeals ?? const <PlannedMeal>[]) m.id};
    final meals = await _readDay();
    if (!mounted) return;
    if (meals != null && meals.any((m) => !known.contains(m.id))) {
      setState(() => _writing = false);
      return;
    }
    final time = _effectiveTime;
    final plannedAt = DateTime(
      _date.year,
      _date.month,
      _date.day,
      time.hour,
      time.minute,
    );
    final target = _target;
    try {
      final repo = ref.read(planningRepositoryProvider);
      if (repo == null) throw StateError('Utilisateur non connecté.');
      await repo.addMeal(
        buildWorkshopMeal(
          menu: _menu,
          lines: widget.lines,
          mainRecipe: _mainRecipe,
          stapleById: widget.workshop.stapleById,
          target: target,
          uid: widget.workshop.myUid,
          plannedAt: plannedAt,
          now: DateTime.now(),
          portions: _portions,
        ),
      );
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'mealWorkshop.pose',
        error: error,
        stackTrace: stackTrace,
        context: {'group_id': ?target.groupId},
        service: ref.read(errorReportServiceProvider),
      );
      if (!mounted) return;
      final denied =
          error is FirebaseException && error.code == 'permission-denied';
      final message = poseFailureMessage(
        permissionDenied: denied,
        target: target,
      );
      setState(() {
        _writing = false;
        _poseError = message;
      });
      context.showErrorSnackBar(message);
      return;
    }
    if (!mounted) return;
    Navigator.of(
      context,
    ).pop(WorkshopPoseResult(plannedAt: plannedAt, target: target));
  }

  // ── Construction ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final ownedGroups =
        ref.watch(ownedPlanningGroupsProvider).value ?? const <FamilyGroup>[];
    final group = _target.isGroup
        ? ownedGroups.where((g) => g.id == _target.groupId).firstOrNull
        : null;
    final prefs = _prefs;
    // Le cadre est celui de `showAdaptiveSheet` : sur grand écran, le focus
    // à l'ouverture va sur « Date ».
    final wide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;
    final busy = _dayMeals?.isNotEmpty ?? false;

    // Parts du jour du groupe, quand elles diffèrent des parts choisies.
    String? groupLine;
    int? groupUsual;
    if (group != null) {
      final usual = groupMealPortions(
        dayConstraint: prefs.dailyConstraints[_date.weekday],
        groupPortions: prefs.groupPortions,
        group: group,
      );
      if (usual != _portions) {
        groupLine = groupUsualPortionsLine(group.name, usual);
        groupUsual = usual;
      }
    }
    // Recette du plat principal (liée ou brouillon), parts différentes.
    String? linkedLine;
    final mainPortions = _mainRecipe?.portions;
    if (mainPortions != null && mainPortions != _portions) {
      linkedLine = linkedPortionsLine(mainPortions);
    }

    final rowsEnabled = !_writing;
    final poseLabel = busy ? 'Ajouter quand même' : 'Poser';

    return PopScope(
      canPop: !_writing,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.only(
            left: 24,
            right: 24,
            top: 20,
            bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Semantics(
                header: true,
                child: Row(
                  children: [
                    Icon(
                      Icons.calendar_month_outlined,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Poser dans le planning',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Divider(color: theme.colorScheme.outlineVariant),
              const SizedBox(height: 8),
              ..._buildRecap(theme, small),
              const SizedBox(height: 8),
              Divider(color: theme.colorScheme.outlineVariant),
              const SizedBox(height: 4),
              if (ownedGroups.isNotEmpty) ...[
                PlanningTargetRow(
                  target: _target,
                  ownedGroups: ownedGroups,
                  onSelected: rowsEnabled ? _selectTarget : null,
                  minHeight: 48,
                ),
                const SizedBox(height: 4),
              ],
              SchedulePickerRow(
                icon: Icons.event_outlined,
                label: 'Date',
                value: formatShortDate(_date),
                onTap: rowsEnabled ? _pickDate : null,
                minHeight: 48,
                autofocus: wide,
              ),
              const SizedBox(height: 4),
              SchedulePickerRow(
                icon: Icons.schedule_outlined,
                label: 'Heure de début',
                value: _effectiveTime.format(context),
                onTap: rowsEnabled ? _pickTime : null,
                minHeight: 48,
              ),
              const SizedBox(height: 4),
              SchedulePickerRow(
                icon: Icons.people_outline,
                label: 'Parts',
                value: workshopPortionsLabel(_portions),
                onTap: rowsEnabled ? _pickPortions : null,
                minHeight: 48,
              ),
              if (groupLine != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                  child: Row(
                    children: [
                      Expanded(child: Text(groupLine, style: small)),
                      if (groupUsual case final usual?)
                        TextButton(
                          onPressed: rowsEnabled
                              ? () => _setPortions(usual)
                              : null,
                          child: Text(
                            usePortionsLabel(usual),
                            semanticsLabel:
                                '${usePortionsLabel(usual)} '
                                '${usual > 1 ? 'parts' : 'part'}',
                          ),
                        ),
                    ],
                  ),
                ),
              if (linkedLine != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
                  child: Text(linkedLine, style: small),
                ),
              if (busy) _buildBusyDay(theme),
              if (_dayError && !_dayLoading)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                  child: Text(
                    'Ce jour n\'a pas pu être vérifié.',
                    style: small,
                  ),
                ),
              if (_poseError case final error?)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      error,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              // À 200 % de texte, les boutons s'empilent : « Poser » en haut,
              // « Annuler » dessous.
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                overflowAlignment: OverflowBarAlignment.end,
                overflowDirection: VerticalDirection.up,
                children: [
                  TextButton(
                    onPressed: _writing
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Annuler'),
                  ),
                  FilledButton.icon(
                    onPressed: _canPose ? _pose : null,
                    icon: _writing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(AppIcons.calendarExport),
                    label: Text(poseLabel),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Le plat principal, relu, n'a pas de recette : posé par son titre.
  bool get _mainWithoutRecipe =>
      _mainRead && _mainError == null && _mainRecipe == null;

  /// « · brouillon », « · Le Grand Livre », « · sans recette » après le
  /// titre du service [index]. Le plat principal relu sans recette est
  /// « sans recette », quelle que soit sa ligne de figement.
  String _recapSuffix(int index, WorkshopCourse course) {
    if (index == _mainIndex && _mainWithoutRecipe) return '· sans recette';
    final lines = widget.lines;
    final recipeId = course.recipeId;
    return poseRecapSuffix(
      index < lines.length ? lines[index] : null,
      linkedBook: recipeId == null
          ? null
          : widget.workshop.recipesById[recipeId]?.bookTitre,
    );
  }

  /// « Menu · 4 services », une ligne par service, puis les phrases « sans
  /// recette » et « brouillons … validés ».
  List<Widget> _buildRecap(ThemeData theme, TextStyle? small) {
    final menu = _menu;
    final lines = widget.lines;
    final mainWithoutRecipe = _mainWithoutRecipe;
    final withoutRecipe = workshopCoursesWithoutRecipe(menu, lines);
    final hasDraft = lines.any((l) => l is FreezeDraftCreated);

    return [
      Text(poseRecapTitle(menu), style: theme.textTheme.bodyMedium),
      const SizedBox(height: 4),
      for (final (index, course) in menu.courses.indexed) ...[
        // Un seul texte : à 200 %, ou pour un « Autre » au libellé long, le
        // type ne se coupe pas dans une colonne fixe, la ligne continue
        // dessous.
        Padding(
          padding: const EdgeInsets.only(left: 8, top: 2),
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: course.typeLabel,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                TextSpan(
                  text: '  ${course.title} ${_recapSuffix(index, course)}',
                ),
              ],
            ),
            style: small,
          ),
        ),
        if (course.role == MealComponentRole.plat && course.sides.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 16),
            child: Text(
              '· ${course.sides.map((s) => s.label).join(', ')}',
              style: small,
            ),
          ),
      ],
      if (!_mainRead)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text('Lecture de la recette…', style: small),
            ],
          ),
        ),
      if (_mainError != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: AppErrorState(
            compact: true,
            title: 'La recette du plat n\'a pas pu être lue.',
            error: _mainError,
            onRetry: _readMain,
          ),
        ),
      if (mainWithoutRecipe)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Semantics(
            liveRegion: true,
            child: Text(kMainNoRecipeSentence, style: small),
          ),
        ),
      if (noRecipeSentence(withoutRecipe) case final sentence?)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Semantics(
            liveRegion: true,
            child: Text(sentence, style: small),
          ),
        ),
      if (_target.isGroup && hasDraft)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(kDraftsForMembersSentence, style: small),
        ),
    ];
  }

  /// « Mar. 12 nov. a déjà un repas : Blanquette de veau, 19:30. » et
  /// « Choisir une autre date ».
  Widget _buildBusyDay(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: AppIconSize.small,
                  color: scheme.onSecondaryContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    busyDayLine(_date, _dayMeals ?? const []),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _writing ? null : _pickDate,
                child: const Text('Choisir une autre date'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
