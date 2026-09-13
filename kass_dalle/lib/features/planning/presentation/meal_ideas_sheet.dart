import 'package:flutter/material.dart';

import '../../../core/presentation/stylus_pad_text_field.dart';
import '../../../core/services/error_report_service.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/theme/app_icon_size.dart';
import '../domain/meal_idea.dart';

/// Ouvre la feuille « Générer avec l'IA » et rend l'idée retenue, ou null.
Future<MealIdea?> showMealIdeasSheet(
  BuildContext context, {
  required MealIdeasGenerator generate,
  String initialPrompt = '',
  ErrorReportService? errorReportService,
}) {
  return showModalBottomSheet<MealIdea>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => MealIdeasSheet(
      generate: generate,
      initialPrompt: initialPrompt,
      errorReportService: errorReportService,
    ),
  );
}

/// Une consigne, trois idées, et la consigne qu'on retouche pour relancer.
///
/// La feuille ne connaît ni Riverpod ni le réseau : elle reçoit [generate] et
/// rend l'idée choisie. Les titres déjà affichés repartent avec chaque relance,
/// pour que « trois autres » en rende trois autres. Rien n'est enregistré ici.
class MealIdeasSheet extends StatefulWidget {
  final MealIdeasGenerator generate;
  final String initialPrompt;

  /// Injecté par les tests ; `ErrorReportService()` par défaut.
  final ErrorReportService? errorReportService;

  const MealIdeasSheet({
    super.key,
    required this.generate,
    this.initialPrompt = '',
    this.errorReportService,
  });

  @override
  State<MealIdeasSheet> createState() => _MealIdeasSheetState();
}

class _MealIdeasSheetState extends State<MealIdeasSheet> {
  late final _promptCtrl = TextEditingController(text: widget.initialPrompt);
  final _ideas = <MealIdea>[];

  /// Tout ce qui a été proposé depuis l'ouverture, pas seulement le dernier
  /// lot : relancer trois fois ne doit pas ramener le premier lot au quatrième.
  final _proposedTitles = <String>[];
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _promptCtrl.dispose();
    super.dispose();
  }

  bool get _canGenerate => !_loading && _promptCtrl.text.trim().isNotEmpty;

  Future<void> _generate() async {
    final prompt = _promptCtrl.text.trim();
    if (prompt.isEmpty || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ideas = await widget.generate(
        prompt: prompt,
        previousTitles: List.unmodifiable(_proposedTitles),
      );
      if (!mounted) return;
      setState(() {
        _ideas
          ..clear()
          ..addAll(ideas);
        _proposedTitles.addAll(ideas.map((i) => i.titre));
        if (ideas.isEmpty) _error = 'L\'IA n\'a rendu aucune idée.';
      });
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'mealIdeasSheet.generate',
        error: e,
        stackTrace: stackTrace,
        context: {'prompt_length': prompt.length},
        service: widget.errorReportService,
      );
      if (!mounted) return;
      setState(() => _error = 'L\'IA n\'a pas répondu : $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasIdeas = _ideas.isNotEmpty;
    return Padding(
      // Le clavier ne doit pas couvrir la consigne ni le bouton.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: 0.4,
                    ),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Row(
                children: [
                  const Icon(Icons.auto_awesome, size: AppIconSize.small),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Générer avec l\'IA',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: StylusPadTextField(
                controller: _promptCtrl,
                autofocus: !hasIdeas,
                minLines: 1,
                maxLines: 4,
                textInputAction: TextInputAction.done,
                padTitle: 'Consigne',
                errorReportService: widget.errorReportService,
                decoration: const InputDecoration(
                  labelText: 'Ce que vous voulez manger',
                  hintText: 'ex : un plat léger sans viande, prêt en 30 min',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _generate(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: FilledButton.icon(
                onPressed: _canGenerate ? _generate : null,
                icon: _loading
                    ? const SizedBox(
                        width: AppIconSize.small,
                        height: AppIconSize.small,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.auto_awesome),
                label: Text(
                  _loading
                      ? 'Génération…'
                      : hasIdeas
                      ? 'Proposer trois autres idées'
                      : 'Proposer trois idées',
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  _error!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            if (hasIdeas) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text(
                  _ideas.length == 1
                      ? 'Une idée — appuyez pour la retenir, ou retouchez '
                            'la consigne et relancez.'
                      : '${_ideas.length} idées — appuyez pour en retenir '
                            'une, ou retouchez la consigne et relancez.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              for (var i = 0; i < _ideas.length; i++)
                ListTile(
                  leading: CircleAvatar(child: Text('${i + 1}')),
                  title: Text(_ideas[i].titre),
                  subtitle: Text(
                    [
                      if (_ideas[i].description.isNotEmpty)
                        _ideas[i].description,
                      if (_ideas[i].timesLabel.isNotEmpty) _ideas[i].timesLabel,
                    ].join('\n'),
                  ),
                  isThreeLine:
                      _ideas[i].description.isNotEmpty &&
                      _ideas[i].timesLabel.isNotEmpty,
                  enabled: !_loading,
                  onTap: () => Navigator.pop(context, _ideas[i]),
                ),
            ],
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
