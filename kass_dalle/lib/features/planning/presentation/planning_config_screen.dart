import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/planning_history.dart';
import '../domain/planning_preferences.dart';
import '../services/calendar_service.dart';
import 'planning_providers.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/theme/app_icon_size.dart';

/// Écran de configuration du planning de repas (Axe C).
///
/// Accessible depuis le bouton paramètres de [PlanningScreen].
class PlanningConfigScreen extends ConsumerStatefulWidget {
  const PlanningConfigScreen({super.key});

  @override
  ConsumerState<PlanningConfigScreen> createState() =>
      _PlanningConfigScreenState();
}

class _PlanningConfigScreenState extends ConsumerState<PlanningConfigScreen> {
  PlanningPreferences? _prefs;
  bool _loaded = false;
  bool _saving = false;
  bool _calendarLoading = false;
  final _globalConstraintsCtrl = TextEditingController();
  final Map<int, TextEditingController> _notesControllers = {};
  final Map<int, TextEditingController> _maxPrepControllers = {};
  final Map<int, TextEditingController> _targetPortionsControllers = {};

  @override
  void initState() {
    super.initState();
    // Initialiser les controllers pour les 7 jours
    for (int d = 1; d <= 7; d++) {
      _notesControllers[d] = TextEditingController();
      _maxPrepControllers[d] = TextEditingController();
      _targetPortionsControllers[d] = TextEditingController();
    }
  }

  @override
  void dispose() {
    _globalConstraintsCtrl.dispose();
    for (final c in _notesControllers.values) {
      c.dispose();
    }
    for (final c in _maxPrepControllers.values) {
      c.dispose();
    }
    for (final c in _targetPortionsControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _loadPrefs(PlanningPreferences prefs) {
    if (_loaded) return;
    _loaded = true;
    _prefs = prefs;
    _globalConstraintsCtrl.text = prefs.globalConstraints;
    for (int d = 1; d <= 7; d++) {
      final c = prefs.dailyConstraints[d];
      if (c != null) {
        _maxPrepControllers[d]!.text = c.maxPrepMinutes > 0
            ? c.maxPrepMinutes.toString()
            : '';
        _targetPortionsControllers[d]!.text = c.targetPortions > 0
            ? c.targetPortions.toString()
            : '';
        _notesControllers[d]!.text = c.notes;
      }
    }
  }

  DayConstraint _buildConstraint(int weekday) {
    final maxPrep =
        int.tryParse(_maxPrepControllers[weekday]!.text.trim()) ?? 0;
    final targetPortions =
        int.tryParse(_targetPortionsControllers[weekday]!.text.trim()) ?? 0;
    final notes = _notesControllers[weekday]!.text.trim();
    final existing = _prefs?.dailyConstraints[weekday];
    // Les trois champs de texte sont relus depuis leurs contrôleurs ; tout le
    // reste vient de l'état. Reconstruire sans le reporter effacerait, à
    // l'enregistrement, ce qui ne se saisit pas au clavier — le réchauffage
    // hier, l'heure du jour aujourd'hui.
    return DayConstraint(
      maxPrepMinutes: maxPrep,
      targetPortions: targetPortions,
      isBatchCooking: existing?.isBatchCooking ?? false,
      notes: notes,
      mealHour: existing?.mealHour,
      mealMinute: existing?.mealMinute,
    );
  }

  PlanningPreferences _buildPrefs() {
    final constraints = <int, DayConstraint>{};
    for (int d = 1; d <= 7; d++) {
      final c = _buildConstraint(d);
      if (!c.isEmpty) constraints[d] = c;
    }
    return (_prefs ?? const PlanningPreferences()).copyWith(
      dailyConstraints: constraints,
      globalConstraints: _globalConstraintsCtrl.text.trim(),
    );
  }

  Future<void> _pickCalendar() async {
    setState(() => _calendarLoading = true);
    try {
      final calendars = await CalendarService.listCalendars();
      if (!mounted) return;
      final picked = await showDialog<Map<String, dynamic>>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Choisir un calendrier'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: calendars.length,
              itemBuilder: (_, i) {
                final cal = calendars[i];
                final isPrimary = cal['primary'] as bool? ?? false;
                return ListTile(
                  leading: Icon(
                    isPrimary
                        ? Icons.star_outline_rounded
                        : Icons.calendar_today_outlined,
                    color: isPrimary ? Theme.of(ctx).colorScheme.primary : null,
                  ),
                  title: Text(cal['name'] as String),
                  subtitle: isPrimary
                      ? const Text('Calendrier principal')
                      : null,
                  onTap: () => Navigator.pop(ctx, cal),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Annuler'),
            ),
          ],
        ),
      );
      if (picked != null && mounted) {
        setState(() {
          _prefs = _prefs!.copyWith(
            calendarId: picked['id'] as String,
            calendarName: picked['name'] as String,
          );
        });
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningConfigScreen.pickCalendar',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showErrorSnackBar('Erreur chargement calendriers : $e');
      }
    } finally {
      if (mounted) setState(() => _calendarLoading = false);
    }
  }

  /// Modifie la contrainte d'un jour, en la créant si elle n'existait pas.
  ///
  /// Trois boutons de la tuile faisaient la même gymnastique — lire, copier la
  /// map, écrire, reposer les préférences ; la recopier une fois de plus était
  /// l'occasion d'oublier une étape sur l'un des trois.
  void _updateDay(int weekday, DayConstraint Function(DayConstraint) change) {
    setState(() {
      final existing =
          _prefs!.dailyConstraints[weekday] ?? const DayConstraint();
      final updated = Map<int, DayConstraint>.from(_prefs!.dailyConstraints);
      updated[weekday] = change(existing);
      _prefs = _prefs!.copyWith(dailyConstraints: updated);
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final repo = ref.read(planningRepositoryProvider);
      await repo?.savePreferences(_buildPrefs());
      if (mounted) {
        context.showSuccessSnackBar('Préférences enregistrées');
        Navigator.pop(context);
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'planningConfigScreen.save',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showErrorSnackBar('Erreur : $e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final prefsAsync = ref.watch(planningPreferencesOnceProvider);

    return prefsAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Configuration du planning')),
        body: AppErrorState(
          error: e,
          onRetry: () => ref.invalidate(planningPreferencesOnceProvider),
        ),
      ),
      data: (prefs) {
        _loadPrefs(prefs);
        return _buildScaffold();
      },
    );
  }

  Widget _buildScaffold() {
    if (_prefs == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuration du planning'),
        centerTitle: false,
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            TextButton(onPressed: _save, child: const Text('Enregistrer')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          // 1. Contraintes globales
          _CollapsibleSection(
            icon: Icons.comment_outlined,
            title: 'Contraintes globales',
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Instructions en langage naturel transmises à l\'IA '
                    '(ex\u202f: "Pas de poisson deux fois dans la semaine").',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _globalConstraintsCtrl,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText:
                          'Ex\u202f: Pas de viande rouge le lundi, repas végétarien '
                          'au moins une fois par semaine…',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // 2. Paramètres du cycle
          _CollapsibleSection(
            icon: Icons.tune_outlined,
            title: 'Paramètres du cycle',
            child: _GeneralSection(
              prefs: _prefs!,
              onChanged: (p) => setState(() => _prefs = p),
            ),
          ),
          const SizedBox(height: 8),
          // 3. Google Calendar
          _CollapsibleSection(
            icon: Icons.calendar_month_outlined,
            title: 'Google Calendar',
            initiallyExpanded: false,
            child: _CalendarSection(
              prefs: _prefs!,
              loading: _calendarLoading,
              onChanged: (p) => setState(() => _prefs = p),
              onPickCalendar: _pickCalendar,
            ),
          ),
          const SizedBox(height: 8),
          // 4. Contraintes quotidiennes
          _CollapsibleSection(
            icon: Icons.rule_outlined,
            title: 'Contraintes quotidiennes',
            initiallyExpanded: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                    child: Text(
                      'Définissez les contraintes spécifiques pour chaque jour de la semaine.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  for (final d in List.generate(
                    7,
                    (i) => ((_prefs!.cycleStartDay - 1 + i) % 7) + 1,
                  ))
                    _DayConstraintTile(
                      key: ValueKey(d),
                      weekday: d,
                      constraint:
                          _prefs!.dailyConstraints[d] ?? const DayConstraint(),
                      notesCtrl: _notesControllers[d]!,
                      maxPrepCtrl: _maxPrepControllers[d]!,
                      targetPortionsCtrl: _targetPortionsControllers[d]!,
                      onBatchCookingChanged: (v) =>
                          _updateDay(d, (c) => c.copyWith(isBatchCooking: v)),
                      effectiveTime: () {
                        final t = _prefs!.mealTimeFor(d);
                        return TimeOfDay(hour: t.hour, minute: t.minute);
                      }(),
                      onTimeChanged: (t) => _updateDay(
                        d,
                        (c) =>
                            c.copyWith(mealHour: t.hour, mealMinute: t.minute),
                      ),
                      onClearTime: () =>
                          _updateDay(d, (c) => c.copyWith(clearMealTime: true)),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Enregistrer les préférences'),
          ),
        ],
      ),
    );
  }
}

// ── Widgets locaux ──────────────────────────────────────────────────────────────

/// Section repliable générique utilisée dans PlanningConfigScreen.
class _CollapsibleSection extends StatefulWidget {
  final IconData icon;
  final String title;
  final bool initiallyExpanded;
  final Widget child;

  const _CollapsibleSection({
    required this.icon,
    required this.title,
    this.initiallyExpanded = true,
    required this.child,
  });

  @override
  State<_CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<_CollapsibleSection> {
  late bool _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(
                    widget.icon,
                    size: AppIconSize.small,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.expand_more,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeInOut,
            child: _expanded
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [const Divider(height: 1), widget.child],
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _CalendarSection extends StatelessWidget {
  final PlanningPreferences prefs;
  final bool loading;
  final ValueChanged<PlanningPreferences> onChanged;
  final VoidCallback onPickCalendar;

  const _CalendarSection({
    required this.prefs,
    required this.loading,
    required this.onChanged,
    required this.onPickCalendar,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          title: const Text('Durée par défaut'),
          subtitle: Text('${prefs.defaultCalendarDurationMinutes} minutes'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.remove),
                tooltip: 'Quinze minutes de moins',
                onPressed: prefs.defaultCalendarDurationMinutes <= 15
                    ? null
                    : () => onChanged(
                        prefs.copyWith(
                          defaultCalendarDurationMinutes:
                              prefs.defaultCalendarDurationMinutes - 15,
                        ),
                      ),
              ),
              Text(
                '${prefs.defaultCalendarDurationMinutes}',
                style: const TextStyle(fontSize: 18),
              ),
              IconButton(
                icon: const Icon(Icons.add),
                tooltip: 'Quinze minutes de plus',
                onPressed: prefs.defaultCalendarDurationMinutes >= 480
                    ? null
                    : () => onChanged(
                        prefs.copyWith(
                          defaultCalendarDurationMinutes:
                              prefs.defaultCalendarDurationMinutes + 15,
                        ),
                      ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        ListTile(
          title: const Text('Calendrier cible'),
          subtitle: Text(
            prefs.calendarId == 'primary'
                ? 'Calendrier principal'
                : prefs.calendarName,
          ),
          trailing: loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right),
          onTap: loading ? null : onPickCalendar,
        ),
      ],
    );
  }
}

class _GeneralSection extends StatelessWidget {
  final PlanningPreferences prefs;
  final ValueChanged<PlanningPreferences> onChanged;

  const _GeneralSection({required this.prefs, required this.onChanged});

  /// Combien de jours portent leur propre heure — c'est ce que la remise à
  /// l'heure par défaut va effacer, et le dire avant vaut mieux que de le
  /// faire découvrir après.
  static int _daysWithOwnTime(PlanningPreferences prefs) =>
      prefs.dailyConstraints.values.where((c) => c.hasOwnTime).length;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          title: const Text('Durée du cycle'),
          subtitle: Text('${prefs.mealsPerCycle} repas'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Un repas de moins par cycle',
                icon: const Icon(Icons.remove),
                onPressed: prefs.mealsPerCycle <= 1
                    ? null
                    : () => onChanged(
                        prefs.copyWith(mealsPerCycle: prefs.mealsPerCycle - 1),
                      ),
              ),
              Text(
                '${prefs.mealsPerCycle}',
                style: const TextStyle(fontSize: 18),
              ),
              IconButton(
                tooltip: 'Un repas de plus par cycle',
                icon: const Icon(Icons.add),
                onPressed: prefs.mealsPerCycle >= 21
                    ? null
                    : () => onChanged(
                        prefs.copyWith(mealsPerCycle: prefs.mealsPerCycle + 1),
                      ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        // La fenêtre de variété : un plat servi dans les N semaines qui
        // précèdent le cycle n'est pas reproposé. Zéro la coupe. Le sous-titre
        // dit ce que la valeur fait, pas seulement ce qu'elle vaut.
        ListTile(
          title: const Text('Ne pas reproposer un plat récent'),
          subtitle: Text(
            prefs.varietyWindowWeeks == 0
                ? 'Désactivé : l\'historique n\'est pas regardé'
                : 'Un plat servi dans les ${prefs.varietyWindowWeeks} '
                      'dernière${prefs.varietyWindowWeeks > 1 ? 's' : ''} '
                      'semaine${prefs.varietyWindowWeeks > 1 ? 's' : ''} '
                      'avant le cycle n\'est pas reproposé',
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Une semaine de moins',
                icon: const Icon(Icons.remove),
                onPressed: prefs.varietyWindowWeeks <= kVarietyWindowMinWeeks
                    ? null
                    : () => onChanged(
                        prefs.copyWith(
                          varietyWindowWeeks: prefs.varietyWindowWeeks - 1,
                        ),
                      ),
              ),
              Text(
                '${prefs.varietyWindowWeeks} sem.',
                style: const TextStyle(fontSize: 18),
              ),
              IconButton(
                tooltip: 'Une semaine de plus',
                icon: const Icon(Icons.add),
                onPressed: prefs.varietyWindowWeeks >= kVarietyWindowMaxWeeks
                    ? null
                    : () => onChanged(
                        prefs.copyWith(
                          varietyWindowWeeks: prefs.varietyWindowWeeks + 1,
                        ),
                      ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        ListTile(
          title: const Text('Début du cycle'),
          subtitle: Text(weekdayLabel(prefs.cycleStartDay)),
          trailing: DropdownButton<int>(
            value: prefs.cycleStartDay,
            underline: const SizedBox.shrink(),
            items: [
              for (int d = 1; d <= 7; d++)
                DropdownMenuItem(value: d, child: Text(weekdayLabel(d))),
            ],
            onChanged: (v) {
              if (v != null) onChanged(prefs.copyWith(cycleStartDay: v));
            },
          ),
        ),
        const Divider(height: 1),
        ListTile(
          title: const Text('Jour batch cooking'),
          subtitle: Text(
            prefs.batchCookingDay != null
                ? weekdayLabel(prefs.batchCookingDay!)
                : 'Aucun',
          ),
          trailing: DropdownButton<int?>(
            value: prefs.batchCookingDay,
            underline: const SizedBox.shrink(),
            items: [
              const DropdownMenuItem<int?>(value: null, child: Text('Aucun')),
              for (int d = 1; d <= 7; d++)
                DropdownMenuItem(value: d, child: Text(weekdayLabel(d))),
            ],
            onChanged: (v) {
              onChanged(
                v == null
                    ? prefs.copyWith(clearBatchCookingDay: true)
                    : prefs.copyWith(batchCookingDay: v),
              );
            },
          ),
        ),
        const Divider(height: 1),
        ListTile(
          title: const Text('Heure des repas par défaut'),
          subtitle: Text(
            '${prefs.defaultMealHour.toString().padLeft(2, '0')}:'
            '${prefs.defaultMealMinute.toString().padLeft(2, '0')}'
            '${_daysWithOwnTime(prefs) > 0 ? ' · remet les ${_daysWithOwnTime(prefs)} jour(s) personnalisé(s) à cette heure' : ''}',
          ),
          trailing: const Icon(Icons.access_time_outlined),
          onTap: () async {
            final t = await showTimePicker(
              context: context,
              initialTime: TimeOfDay(
                hour: prefs.defaultMealHour,
                minute: prefs.defaultMealMinute,
              ),
              helpText: 'Heure des repas par défaut',
            );
            if (context.mounted && t != null) {
              // Change l'heure par défaut ET ramène tous les jours à elle.
              // Sans cette remise à zéro, régler l'heure globale n'aurait plus
              // d'effet visible dès qu'un seul jour aurait été personnalisé, et
              // il faudrait deviner lesquels des sept résistent.
              onChanged(prefs.withDefaultMealTime(t.hour, t.minute));
            }
          },
        ),
      ],
    );
  }
}

class _DayConstraintTile extends StatelessWidget {
  final int weekday;
  final DayConstraint constraint;
  final TextEditingController notesCtrl;
  final TextEditingController maxPrepCtrl;
  final TextEditingController targetPortionsCtrl;
  final ValueChanged<bool> onBatchCookingChanged;

  /// Heure appliquée ce jour-là : la sienne, ou celle par défaut.
  final TimeOfDay effectiveTime;
  final ValueChanged<TimeOfDay> onTimeChanged;
  final VoidCallback onClearTime;

  const _DayConstraintTile({
    super.key,
    required this.weekday,
    required this.constraint,
    required this.notesCtrl,
    required this.maxPrepCtrl,
    required this.targetPortionsCtrl,
    required this.onBatchCookingChanged,
    required this.effectiveTime,
    required this.onTimeChanged,
    required this.onClearTime,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 4),
      child: ExpansionTile(
        leading: CircleAvatar(
          radius: 16,
          child: Text(
            weekdayLabel(weekday).substring(0, 2),
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ),
        title: Text(weekdayLabel(weekday)),
        subtitle: constraint.isEmpty
            ? null
            : Text(
                _summaryText(),
                style: Theme.of(context).textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
        children: [
          Padding(
            // Douze pixels en haut, et non zéro : le libellé flottant d'un
            // champ bordé déborde au-dessus de sa bordure, et se faisait
            // couper net par l'en-tête du jour.
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: maxPrepCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: InputDecoration(
                          labelText: 'Temps de préparation max (min)',
                          hintText: '0 = pas de limite',
                          isDense: true,
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                          filled: true,
                          fillColor: Theme.of(context).colorScheme.surface,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        controller: targetPortionsCtrl,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: InputDecoration(
                          labelText: 'Parts à préparer',
                          hintText: '0 = portions recette',
                          isDense: true,
                          floatingLabelBehavior: FloatingLabelBehavior.always,
                          filled: true,
                          fillColor: Theme.of(context).colorScheme.surface,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.access_time_outlined),
                  title: const Text('Heure du repas'),
                  subtitle: Text(
                    constraint.hasOwnTime
                        ? 'Propre à ce jour'
                        : 'Suit l’heure par défaut',
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '${effectiveTime.hour.toString().padLeft(2, '0')}:'
                        '${effectiveTime.minute.toString().padLeft(2, '0')}',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      // Le retour au défaut n'existe que si l'on s'en est
                      // écarté : proposer d'annuler ce qu'on n'a pas fait
                      // n'apprend rien.
                      if (constraint.hasOwnTime)
                        IconButton(
                          icon: const Icon(Icons.settings_backup_restore),
                          tooltip: 'Revenir à l’heure par défaut',
                          onPressed: onClearTime,
                        ),
                    ],
                  ),
                  onTap: () async {
                    final t = await showTimePicker(
                      context: context,
                      initialTime: effectiveTime,
                      helpText: 'Heure du repas — ${weekdayLabel(weekday)}',
                    );
                    if (t != null) onTimeChanged(t);
                  },
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Jour de réchauffage'),
                  subtitle: const Text(
                    'Repas préparé avant et réchauffé ce jour (pas le jour de préparation batch)',
                  ),
                  value: constraint.isBatchCooking,
                  onChanged: onBatchCookingChanged,
                ),
                const SizedBox(height: 4),
                TextFormField(
                  controller: notesCtrl,
                  maxLines: 2,
                  decoration: InputDecoration(
                    labelText: 'Contrainte spécifique',
                    hintText: 'Ex: Repas léger, sport le soir',
                    isDense: true,
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    filled: true,
                    fillColor: Theme.of(context).colorScheme.surface,
                    border: const OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _summaryText() {
    final parts = <String>[];
    // L'heure n'apparaît au résumé que si elle est propre à ce jour : répéter
    // l'heure par défaut sur les sept lignes n'apprendrait rien.
    if (constraint.hasOwnTime) {
      parts.add(
        '${effectiveTime.hour.toString().padLeft(2, '0')}:'
        '${effectiveTime.minute.toString().padLeft(2, '0')}',
      );
    }
    if (constraint.maxPrepMinutes > 0) {
      parts.add('max ${constraint.maxPrepMinutes}min');
    }
    if (constraint.targetPortions > 0) {
      parts.add('${constraint.targetPortions} parts');
    }
    if (constraint.isBatchCooking) parts.add('réchauffage');
    if (constraint.notes.trim().isNotEmpty) parts.add(constraint.notes.trim());
    return parts.join(' · ');
  }
}
