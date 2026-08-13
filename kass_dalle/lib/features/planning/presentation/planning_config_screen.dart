import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/planning_preferences.dart';
import '../services/calendar_service.dart';
import 'planning_providers.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/widgets/app_states.dart';

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
    return DayConstraint(
      maxPrepMinutes: maxPrep,
      targetPortions: targetPortions,
      isBatchCooking: existing?.isBatchCooking ?? false,
      notes: notes,
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
                        ? Icons.star_outlined
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
    final prefsAsync = ref.watch(planningPreferencesProvider);

    return prefsAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Configuration du planning')),
        body: AppErrorState(
          error: e,
          onRetry: () => ref.invalidate(planningPreferencesProvider),
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
            icon: Icons.auto_fix_high,
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
                      onBatchCookingChanged: (v) {
                        setState(() {
                          final existing =
                              _prefs!.dailyConstraints[d] ??
                              const DayConstraint();
                          final updated = Map<int, DayConstraint>.from(
                            _prefs!.dailyConstraints,
                          );
                          updated[d] = existing.copyWith(isBatchCooking: v);
                          _prefs = _prefs!.copyWith(dailyConstraints: updated);
                        });
                      },
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
                  Icon(widget.icon, size: 20, color: theme.colorScheme.primary),
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
            '${prefs.defaultMealMinute.toString().padLeft(2, '0')}',
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
              onChanged(
                prefs.copyWith(
                  defaultMealHour: t.hour,
                  defaultMealMinute: t.minute,
                ),
              );
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

  const _DayConstraintTile({
    super.key,
    required this.weekday,
    required this.constraint,
    required this.notesCtrl,
    required this.maxPrepCtrl,
    required this.targetPortionsCtrl,
    required this.onBatchCookingChanged,
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
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
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
