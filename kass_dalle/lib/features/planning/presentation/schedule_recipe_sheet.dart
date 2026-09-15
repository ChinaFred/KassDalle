import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../recipes/domain/recipe.dart';
import '../domain/calendar_event_description.dart';
import '../domain/meal_recipe_location.dart';
import '../domain/planned_meal.dart';
import '../domain/planning_preferences.dart';
import '../services/calendar_service.dart';
import 'planning_providers.dart';
import '../../../core/utils/context_extensions.dart';
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

  const _ScheduleSheet({
    required this.titre,
    this.recipeId,
    required this.prepTimeMin,
    required this.cookTimeMin,
    required this.ingredients,
  });

  @override
  ConsumerState<_ScheduleSheet> createState() => _ScheduleSheetState();
}

class _ScheduleSheetState extends ConsumerState<_ScheduleSheet> {
  late DateTime _selectedDate;
  TimeOfDay? _selectedTime;
  late TextEditingController _reminderCtrl;
  bool _loading = false;

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

  Future<void> _addToCalendar() async {
    setState(() => _loading = true);
    try {
      final prefs = _prefs;
      final time = _effectiveTime;
      final start = DateTime(
        _selectedDate.year,
        _selectedDate.month,
        _selectedDate.day,
        time.hour,
        time.minute,
      );
      final reminder =
          int.tryParse(_reminderCtrl.text.trim()) ?? (widget.prepTimeMin ?? 30);

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

      // Sauvegarde locale dans Firestore pour l'écran Planning.
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        final repo = ref.read(planningRepositoryProvider);
        await repo?.addMeal(
          PlannedMeal(
            id: '',
            uid: uid,
            recipeId: widget.recipeId,
            recipeTitre: widget.titre,
            plannedAt: start,
            durationMinutes: _totalDurationMin,
            prepMinutes: widget.prepTimeMin,
            cookMinutes: widget.cookTimeMin,
            createdAt: DateTime.now(),
          ),
        );
      }

      if (mounted) {
        Navigator.of(context).pop();
        context.showSuccessSnackBar('Événement ajouté à Google Calendar ✓');
      }
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'scheduleRecipeSheet.addToCalendar',
        error: e,
        stackTrace: stackTrace,
      );
      if (mounted) {
        context.showErrorSnackBar('Erreur : $e');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────────────────

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

  String _formatDuration(int totalMin) {
    if (totalMin >= 60) {
      final h = totalMin ~/ 60;
      final m = totalMin % 60;
      return m > 0 ? '${h}h${m}min' : '${h}h';
    }
    return '$totalMin min';
  }

  // ── Build ────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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

          // Durée (informative)
          if (_totalDurationMin > 0) ...[
            _InfoRow(
              icon: Icons.timer_outlined,
              label: 'Durée estimée',
              value: _formatDuration(_totalDurationMin),
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
              label: const Text('Ajouter à Google Calendar'),
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
  final VoidCallback onTap;

  const _PickerRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
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
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right,
              size: AppIconSize.small,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
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
