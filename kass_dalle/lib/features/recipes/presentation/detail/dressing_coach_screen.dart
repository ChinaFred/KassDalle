import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/recipe.dart';

Future<void> openDressingCoach(
  BuildContext context, {
  required Recipe recipe,
  int? basePortions,
  int? selectedPortions,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => DressingCoachScreen(
        recipe: recipe,
        basePortions: basePortions,
        selectedPortions: selectedPortions,
      ),
    ),
  );
}

class DressingCoachEntryCard extends StatelessWidget {
  final Recipe recipe;
  final int? basePortions;
  final int? selectedPortions;

  const DressingCoachEntryCard({
    super.key,
    required this.recipe,
    this.basePortions,
    this.selectedPortions,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.style_outlined),
        title: const Text('Aide au dressage'),
        subtitle: const Text('Mode guide pas a pas + score'),
        trailing: FilledButton.icon(
          onPressed: () => openDressingCoach(
            context,
            recipe: recipe,
            basePortions: basePortions,
            selectedPortions: selectedPortions,
          ),
          icon: const Icon(Icons.play_arrow),
          label: const Text('Demarrer'),
        ),
      ),
    );
  }
}

class DressingCoachScreen extends StatefulWidget {
  final Recipe recipe;
  final int? basePortions;
  final int? selectedPortions;

  const DressingCoachScreen({
    super.key,
    required this.recipe,
    this.basePortions,
    this.selectedPortions,
  });

  @override
  State<DressingCoachScreen> createState() => _DressingCoachScreenState();
}

class _DressingCoachScreenState extends State<DressingCoachScreen> {
  late final List<String> _steps;
  late final List<bool> _done;
  late final Stopwatch _stopwatch;
  Timer? _ticker;

  int _currentStep = 0;
  double _selfRating = 7;
  final Set<String> _missingDecorations = <String>{};

  @override
  void initState() {
    super.initState();
    _steps = _extractPreparationSteps(widget.recipe.rawCooklang);
    _done = List<bool>.filled(_steps.length, false);
    _stopwatch = Stopwatch()..start();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _stopwatch.stop();
    super.dispose();
  }

  List<RecipeIngredient> get _decoCandidates {
    return _extractDecorationCandidates(widget.recipe.ingredients);
  }

  int get _elapsedSeconds => _stopwatch.elapsed.inSeconds;

  String _formatDuration(int totalSeconds) {
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    final mm = minutes.toString().padLeft(2, '0');
    final ss = seconds.toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  int _targetMinutes() {
    final prep = widget.recipe.tags.prepTime;
    if (prep != null && prep > 0) {
      return math.max(5, math.min(20, prep ~/ 3));
    }
    return math.max(5, math.min(15, _steps.length + 4));
  }

  void _markCurrentDone() {
    if (_steps.isEmpty) return;
    setState(() {
      _done[_currentStep] = true;
      if (_currentStep < _steps.length - 1) {
        _currentStep += 1;
      }
    });
  }

  void _goPrevious() {
    if (_steps.isEmpty) return;
    if (_currentStep == 0) return;
    setState(() => _currentStep -= 1);
  }

  void _goNext() {
    if (_steps.isEmpty) return;
    if (_currentStep >= _steps.length - 1) return;
    setState(() => _currentStep += 1);
  }

  int _computeScore() {
    final stepsCount = _steps.length;
    final doneCount = _done.where((v) => v).length;
    final sequenceScore = stepsCount == 0
        ? 0.0
        : (doneCount / stepsCount).clamp(0, 1) * 30;

    final hasPortions =
        widget.basePortions != null && widget.selectedPortions != null;
    final portionsScore = hasPortions ? 25.0 : 15.0;

    final decorations = _decoCandidates;
    final decoScore = decorations.isEmpty
        ? 20.0
        : _missingDecorations.isEmpty
        ? 20.0
        : 16.0;

    final targetMinutes = _targetMinutes().toDouble();
    final elapsedMinutes = (_elapsedSeconds / 60).clamp(0.1, 999.0);
    final timingScore = elapsedMinutes <= targetMinutes
        ? 15.0
        : (15.0 * (targetMinutes / elapsedMinutes)).clamp(0.0, 15.0);

    final selfScore = _selfRating.clamp(0, 10);

    final total =
        sequenceScore + portionsScore + decoScore + timingScore + selfScore;
    return total.round().clamp(0, 100);
  }

  List<String> _buildTips() {
    final tips = <String>[];
    final doneCount = _done.where((v) => v).length;
    if (_steps.isNotEmpty && doneCount < _steps.length) {
      tips.add(
        'Terminer toutes les etapes ameliore la regularite du dressage.',
      );
    }
    if (_missingDecorations.isNotEmpty) {
      tips.add('Utiliser une alternative deco apporte du contraste visuel.');
    }
    if (_elapsedSeconds > _targetMinutes() * 60) {
      tips.add(
        'Preparer les elements de finition en avance reduit le temps de service.',
      );
    }
    if (_selfRating < 7) {
      tips.add(
        'Accentuer la hauteur et le contraste des couleurs renforce le rendu.',
      );
    }
    if (tips.isEmpty) {
      tips.add(
        'Tres bon dressage: conserver la meme sequence pour standardiser le resultat.',
      );
    }
    return tips.take(2).toList();
  }

  Future<void> _finishAndShowScore() async {
    _stopwatch.stop();
    final score = _computeScore();
    final tips = _buildTips();
    final stateLabel = score >= 75
        ? 'Service pret'
        : score >= 50
        ? 'Correct'
        : 'A retravailler';

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Score de dressage'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Resultat: $score / 100 - $stateLabel'),
            const SizedBox(height: 8),
            Text('Temps: ${_formatDuration(_elapsedSeconds)}'),
            const SizedBox(height: 12),
            for (final tip in tips) Text('• $tip'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Fermer'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).pop();
            },
            child: const Text('Terminer'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (!_stopwatch.isRunning) {
      _stopwatch.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final target = _targetMinutes();
    final portionsText =
        widget.basePortions != null && widget.selectedPortions != null
        ? '${widget.basePortions} -> ${widget.selectedPortions} portions'
        : 'Portions recette';
    final decoCandidates = _decoCandidates;

    return Scaffold(
      appBar: AppBar(title: const Text('Coach dressage')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.recipe.titre,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text('Portions: $portionsText'),
                      const SizedBox(height: 4),
                      Text(
                        'Temps: ${_formatDuration(_elapsedSeconds)} / cible ${target} min',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              if (_steps.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text('Aucune etape detectee pour le dressage.'),
                  ),
                )
              else
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Etape ${_currentStep + 1} / ${_steps.length}',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(_steps[_currentStep]),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            OutlinedButton.icon(
                              onPressed: _goPrevious,
                              icon: const Icon(Icons.arrow_back),
                              label: const Text('Prec'),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: _goNext,
                              icon: const Icon(Icons.arrow_forward),
                              label: const Text('Suiv'),
                            ),
                            const Spacer(),
                            FilledButton.icon(
                              onPressed: _markCurrentDone,
                              icon: const Icon(Icons.check),
                              label: const Text('Etape faite'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Deco manquante',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 8),
                      if (decoCandidates.isEmpty)
                        const Text('Aucune deco detectee dans les ingredients.')
                      else
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final ingredient in decoCandidates)
                              FilterChip(
                                label: Text(ingredient.name),
                                selected: _missingDecorations.contains(
                                  ingredient.name,
                                ),
                                onSelected: (selected) {
                                  setState(() {
                                    if (selected) {
                                      _missingDecorations.add(ingredient.name);
                                    } else {
                                      _missingDecorations.remove(
                                        ingredient.name,
                                      );
                                    }
                                  });
                                },
                              ),
                          ],
                        ),
                      if (_missingDecorations.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        for (final name in _missingDecorations)
                          Text(
                            'Alternative pour $name: ${_decorationAlternative(name)}',
                          ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Auto-evaluation',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Slider(
                        value: _selfRating,
                        min: 0,
                        max: 10,
                        divisions: 10,
                        label: _selfRating.round().toString(),
                        onChanged: (v) => setState(() => _selfRating = v),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _finishAndShowScore,
                  icon: const Icon(Icons.emoji_events_outlined),
                  label: const Text('Calculer le score dressage'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

List<String> _extractPreparationSteps(String rawCooklang) {
  final steps = <String>[];
  for (final line in rawCooklang.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    if (trimmed.startsWith('>>')) continue;
    if (trimmed.startsWith('--')) continue;
    if (trimmed.startsWith('==')) continue;
    if (trimmed.startsWith('#')) continue;
    if (trimmed.startsWith('>')) {
      final text = trimmed.substring(1).trim();
      if (text.isNotEmpty) {
        steps.add(text);
      }
      continue;
    }
    if (trimmed.contains('@') ||
        trimmed.contains('#') ||
        trimmed.contains('~')) {
      steps.add(trimmed);
    }
  }
  if (steps.isEmpty) {
    return const [
      'Deposer la base du plat.',
      'Positionner l\'element principal au centre.',
      'Ajouter garniture et finition avec contraste.',
    ];
  }
  return steps;
}

List<RecipeIngredient> _extractDecorationCandidates(
  List<RecipeIngredient> ingredients,
) {
  const decoKeywords = <String>[
    'persil',
    'coriandre',
    'basilic',
    'menthe',
    'ciboulette',
    'sesame',
    'graines',
    'zeste',
    'citron',
    'herbe',
    'poivre',
    'piment',
  ];
  return ingredients
      .where((ingredient) {
        final name = ingredient.name.toLowerCase();
        return decoKeywords.any(name.contains);
      })
      .toList(growable: false);
}

String _decorationAlternative(String missingName) {
  final value = missingName.toLowerCase();
  if (value.contains('persil') || value.contains('coriandre')) {
    return 'Utiliser ciboulette ou herbes seches.';
  }
  if (value.contains('citron') || value.contains('zeste')) {
    return 'Ajouter une pointe d\'acide (vinaigre doux) et une herbe fraiche.';
  }
  if (value.contains('sesame') || value.contains('graines')) {
    return 'Remplacer par fruits secs concasses ou chapelure toastee.';
  }
  if (value.contains('piment') || value.contains('poivre')) {
    return 'Apporter le contraste avec paprika doux ou herbes.';
  }
  return 'Version epuree: accentuer la hauteur et le contraste des sauces.';
}
