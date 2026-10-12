import 'package:flutter/material.dart';

import '../data/gcp_billing_repository.dart';
import '../domain/backfill_registry.dart';
import '../domain/backfill_status.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/app_shortcuts.dart';

/// Ce que l'éditeur rend à l'enregistrement.
class BackfillScheduleChoice {
  final bool enabled;
  final List<int> days;
  final int hour;

  const BackfillScheduleChoice({
    required this.enabled,
    required this.days,
    required this.hour,
  });
}

/// Ouvre le contrôle de programmation d'un backfill récurrent : feuille du
/// bas sur téléphone, dialogue au-delà de `PlatformUtils.wideBreakpoint`.
/// Même contenu dans les deux cas.
///
/// [onSave] enregistre ; s'il lève, l'éditeur reste ouvert et dit pourquoi.
/// Rend `true` quand la programmation a été enregistrée.
Future<bool> showBackfillScheduleEditor(
  BuildContext context, {
  required BackfillDefinition def,
  required BackfillSchedule? current,
  required Future<void> Function(BackfillScheduleChoice choice) onSave,
  required VoidCallback onOpenSpendCap,
}) async {
  final editor = BackfillScheduleEditor(
    def: def,
    current: current,
    onSave: onSave,
    onOpenSpendCap: onOpenSpendCap,
  );
  final wide = MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;
  final saved = wide
      ? await showDialog<bool>(
          context: context,
          builder: (_) => Dialog(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: editor,
            ),
          ),
        )
      : await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          // Le glisser fermerait la feuille sans passer par `PopScope` : la
          // fermeture passe par « Annuler », le fond ou Échap, refusés tant
          // qu'un enregistrement est en cours.
          enableDrag: false,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          builder: (_) => editor,
        );
  return saved == true;
}

class BackfillScheduleEditor extends StatefulWidget {
  final BackfillDefinition def;
  final BackfillSchedule? current;
  final Future<void> Function(BackfillScheduleChoice choice) onSave;
  final VoidCallback onOpenSpendCap;

  const BackfillScheduleEditor({
    super.key,
    required this.def,
    required this.current,
    required this.onSave,
    required this.onOpenSpendCap,
  });

  @override
  State<BackfillScheduleEditor> createState() => _BackfillScheduleEditorState();
}

class _BackfillScheduleEditorState extends State<BackfillScheduleEditor> {
  late bool _enabled;
  late Set<int> _days;
  late int _hour;
  bool _saving = false;

  /// Raison du dernier échec d'enregistrement, affichée au-dessus des boutons.
  String? _error;

  /// Heure proposée pour une première programmation : la nuit, quand
  /// personne n'importe.
  static const _defaultHour = 3;

  static const _dayLabels = [
    'lun.',
    'mar.',
    'mer.',
    'jeu.',
    'ven.',
    'sam.',
    'dim.',
  ];

  @override
  void initState() {
    super.initState();
    final current = widget.current;
    _enabled = current?.isActive ?? false;
    _days = {...?current?.days};
    _hour = current?.hour ?? _defaultHour;
  }

  bool get _canSave => !_saving && (!_enabled || _days.isNotEmpty);

  BackfillSchedule get _draft => BackfillSchedule(
    enabled: _enabled,
    days: (_days.toList()..sort()),
    hour: _hour,
  );

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(
        BackfillScheduleChoice(
          enabled: _enabled,
          days: _days.toList()..sort(),
          hour: _hour,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      // L'erreur est déjà remontée par [onSave] (ErrorReportService) ;
      // l'éditeur reste ouvert et la cite.
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Programmation non enregistrée : ${callableFailureReason(e)}.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final allDays = _days.length == 7;

    return PopScope(
      // Ni fond, ni Échap, ni retour pendant l'enregistrement.
      canPop: !_saving,
      child: AppShortcuts(
        onSave: _save,
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            24,
            20,
            24,
            16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Programmer — ${widget.def.title}',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Passage programmé'),
                value: _enabled,
                onChanged: _saving
                    ? null
                    : (v) => setState(() {
                        _enabled = v;
                        if (v && _days.isEmpty) _days = {...kAllBackfillDays};
                      }),
              ),
              if (_enabled) ...[
                const SizedBox(height: 8),
                Text('Jours', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilterChip(
                      label: const Text('Tous les jours'),
                      selected: allDays,
                      onSelected: _saving
                          ? null
                          : (v) => setState(
                              () => _days = v ? {...kAllBackfillDays} : <int>{},
                            ),
                    ),
                    for (var d = 1; d <= 7; d++)
                      FilterChip(
                        label: Text(_dayLabels[d - 1]),
                        selected: _days.contains(d),
                        onSelected: _saving
                            ? null
                            : (v) => setState(() {
                                final next = {..._days};
                                v ? next.add(d) : next.remove(d);
                                _days = next;
                              }),
                      ),
                  ],
                ),
                if (_days.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Choisissez au moins un jour.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int>(
                  initialValue: _hour,
                  decoration: const InputDecoration(
                    labelText: 'Heure',
                    helperText: 'Heure de Paris',
                  ),
                  items: [
                    for (var h = 0; h < 24; h++)
                      DropdownMenuItem(value: h, child: Text(formatHour(h))),
                  ],
                  onChanged: _saving
                      ? null
                      : (v) => setState(() => _hour = v ?? _hour),
                ),
                const SizedBox(height: 16),
                if (_days.isNotEmpty)
                  Text(
                    backfillScheduleSummary(_draft, DateTime.now()),
                    style: theme.textTheme.bodyMedium,
                  ),
                const SizedBox(height: 12),
                _CostNotice(
                  def: widget.def,
                  saving: _saving,
                  onOpenSpendCap: widget.onOpenSpendCap,
                ),
              ],
              const SizedBox(height: 16),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.error,
                      ),
                    ),
                  ),
                ),
              OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: _saving
                        ? null
                        : () => Navigator.of(context).pop(false),
                    child: const Text('Annuler'),
                  ),
                  FilledButton(
                    onPressed: _canSave ? _save : null,
                    child: _saving
                        ? const SizedBox.square(
                            dimension: AppIconSize.small,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Enregistrer'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Encadré de coût : ce qu'un passage programmé appelle et ce qui le borne.
class _CostNotice extends StatelessWidget {
  final BackfillDefinition def;
  final VoidCallback onOpenSpendCap;

  /// Enregistrement en cours : le lien vers le plafond est inactif.
  final bool saving;

  const _CostNotice({
    required this.def,
    required this.saving,
    required this.onOpenSpendCap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textStyle = Theme.of(
      context,
    ).textTheme.bodyMedium?.copyWith(color: scheme.onTertiaryContainer);
    final budgetOwner = def.key == BackfillKeys.nutrition
        ? 'Le plafond est celui du propriétaire de chaque recette.'
        : 'Le plafond est celui de votre compte : la programmation vous est '
              'imputée.';
    return Material(
      color: scheme.tertiaryContainer,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              def.usesAi ? Icons.payments_outlined : Icons.money_off_outlined,
              color: scheme.onTertiaryContainer,
              size: AppIconSize.small,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: def.usesAi
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Ce passage appelle l\'IA et est facturé. '
                          '${def.passLimit} S\'il reste du travail, il '
                          'reprend l\'heure suivante, jusqu\'à la fin ou '
                          'jusqu\'au plafond de dépense quotidien. '
                          '$budgetOwner',
                          style: textStyle,
                        ),
                        TextButton(
                          style: TextButton.styleFrom(
                            foregroundColor: scheme.onTertiaryContainer,
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 48),
                            alignment: Alignment.centerLeft,
                          ),
                          onPressed: saving
                              ? null
                              : () {
                                  // Ferme l'éditeur sans enregistrer, puis ouvre
                                  // Dépense par utilisateur.
                                  Navigator.of(context).pop(false);
                                  onOpenSpendCap();
                                },
                          child: const Text(
                            'Régler le plafond (sans enregistrer)',
                          ),
                        ),
                      ],
                    )
                  : Text(
                      'Aucun appel d\'IA : ce passage n\'est pas facturé. '
                      '${def.passLimit}',
                      style: textStyle,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
