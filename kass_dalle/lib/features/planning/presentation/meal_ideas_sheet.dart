import 'package:flutter/material.dart';

import '../../../core/presentation/stylus_pad_text_field.dart';
import '../../../core/services/error_report_service.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../recipes/domain/recipe.dart';
import '../domain/meal_idea.dart';

/// Ouvre la feuille « Générer avec l'IA » et rend la recette retenue, ou null.
///
/// Avec [conceive], l'idée choisie est rédigée et enregistrée avant de sortir :
/// la recette rendue a un identifiant. Sans lui, elle sort en repas libre.
Future<Recipe?> showMealIdeasSheet(
  BuildContext context, {
  required MealIdeasGenerator generate,
  MealIdeaConceiver? conceive,
  String initialPrompt = '',
  ErrorReportService? errorReportService,
}) {
  return showModalBottomSheet<Recipe>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    // Pendant la rédaction, un geste hors de la feuille ne doit pas la fermer :
    // la recette arriverait dans le vide.
    isDismissible: conceive == null,
    builder: (_) => MealIdeasSheet(
      generate: generate,
      conceive: conceive,
      initialPrompt: initialPrompt,
      errorReportService: errorReportService,
    ),
  );
}

/// Une consigne, trois idées, et la consigne qu'on retouche pour relancer.
///
/// La feuille ne connaît ni Riverpod ni le réseau : elle reçoit [generate] et
/// [conceive], et rend la recette choisie. Les titres déjà affichés repartent
/// avec chaque relance, pour que « trois autres » en rende trois autres.
class MealIdeasSheet extends StatefulWidget {
  final MealIdeasGenerator generate;
  final MealIdeaConceiver? conceive;
  final String initialPrompt;

  /// Injecté par les tests ; `ErrorReportService()` par défaut.
  final ErrorReportService? errorReportService;

  const MealIdeasSheet({
    super.key,
    required this.generate,
    this.conceive,
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

  /// L'idée en cours de rédaction, le temps que la recette soit écrite.
  MealIdea? _conceiving;
  String? _error;

  @override
  void dispose() {
    _promptCtrl.dispose();
    super.dispose();
  }

  bool get _busy => _loading || _conceiving != null;

  bool get _canGenerate => !_busy && _promptCtrl.text.trim().isNotEmpty;

  Future<void> _generate() async {
    final prompt = _promptCtrl.text.trim();
    if (prompt.isEmpty || _busy) return;
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

  /// Retient une idée : rédigée et enregistrée si [MealIdeasSheet.conceive]
  /// est fourni, sinon rendue en repas libre.
  Future<void> _pick(MealIdea idea) async {
    if (_busy) return;
    final conceive = widget.conceive;
    if (conceive == null) {
      Navigator.pop(context, idea.toFreeRecipe());
      return;
    }
    setState(() {
      _conceiving = idea;
      _error = null;
    });
    try {
      final recipe = await conceive(idea);
      if (!mounted) return;
      Navigator.pop(context, recipe);
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'mealIdeasSheet.conceive',
        error: e,
        stackTrace: stackTrace,
        context: {'titre': idea.titre},
        service: widget.errorReportService,
      );
      if (!mounted) return;
      setState(() {
        _conceiving = null;
        _error = 'La recette n\'a pas pu être rédigée : $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasIdeas = _ideas.isNotEmpty;
    final conceiving = _conceiving;
    return PopScope(
      canPop: conceiving == null,
      child: Padding(
        // Le clavier ne doit pas couvrir la consigne ni le bouton.
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
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
                  enabled: conceiving == null,
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
              if (conceiving != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: AppIconSize.small,
                        height: AppIconSize.small,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Rédaction de « ${conceiving.titre} »… '
                          'jusqu\'à une minute.',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
              if (hasIdeas) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    widget.conceive == null
                        ? 'Appuyez sur une idée pour la retenir, ou retouchez '
                              'la consigne et relancez.'
                        : 'Appuyez sur une idée : sa recette est rédigée et '
                              'rangée dans « Mes créations Kass\'Dalle ». '
                              'Ou retouchez la consigne et relancez.',
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
                        if (_ideas[i].timesLabel.isNotEmpty)
                          _ideas[i].timesLabel,
                      ].join('\n'),
                    ),
                    isThreeLine:
                        _ideas[i].description.isNotEmpty &&
                        _ideas[i].timesLabel.isNotEmpty,
                    enabled: !_busy,
                    onTap: () => _pick(_ideas[i]),
                  ),
              ],
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
