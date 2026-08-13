import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/app_states.dart';
import '../../../../core/widgets/error_message.dart';
import '../../domain/plating_advice.dart';
import '../../domain/plating_cooklang.dart';
import '../../domain/recipe.dart';
import '../recipe_providers.dart';
import 'dressing_coach_widgets.dart';

/// Coach de dressage d'une recette.
///
/// Ce que l'onglet affichait auparavant était produit sur place, à partir de
/// mots-clés cherchés dans les noms d'ingrédients : « persil détecté » donnait
/// « les herbes soulignent le mouvement du dressage ». C'était vrai de tous les
/// plats, donc utile pour aucun.
///
/// Le conseil vient désormais du moteur d'IA, à la demande, et reste stocké sur
/// la recette : un appel par recette, pas un par ouverture d'onglet.
class DressingCoachSection extends ConsumerStatefulWidget {
  final Recipe recipe;

  /// Autorise la génération de visuels et l'écriture dans la recette.
  final bool canEdit;

  const DressingCoachSection({
    super.key,
    required this.recipe,
    this.canEdit = false,
  });

  @override
  ConsumerState<DressingCoachSection> createState() =>
      _DressingCoachSectionState();
}

class _DressingCoachSectionState extends ConsumerState<DressingCoachSection> {
  final _instructionCtrl = TextEditingController();

  /// Conseil affiché après une action locale — prime sur la lecture Firestore
  /// tant que le provider n'a pas été rechargé.
  PlatingAdvice? _localAdvice;
  bool _generating = false;
  int? _generatingImageIndex;
  Object? _actionError;

  @override
  void dispose() {
    _instructionCtrl.dispose();
    super.dispose();
  }

  String get _recipeId => widget.recipe.id;

  Future<void> _generate() async {
    setState(() {
      _generating = true;
      _actionError = null;
    });
    try {
      final advice = await ref
          .read(platingRepositoryProvider)
          .generate(
            recipeId: _recipeId,
            userInstruction: _instructionCtrl.text.trim(),
          );
      if (!mounted) return;
      setState(() => _localAdvice = advice);
      ref.invalidate(platingAdviceProvider(_recipeId));
    } catch (error) {
      // Le repository a déjà rapporté l'erreur ; ici on la rend lisible.
      if (!mounted) return;
      setState(() => _actionError = error);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<void> _generateImage(PlatingAdvice advice, int index) async {
    setState(() {
      _generatingImageIndex = index;
      _actionError = null;
    });
    try {
      final url = await ref
          .read(platingRepositoryProvider)
          .generateStepImage(recipeId: _recipeId, stepIndex: index);
      if (!mounted) return;
      setState(() {
        _localAdvice = advice.copyWithStep(
          index,
          advice.etapes[index].copyWith(imageUrl: url),
        );
      });
      ref.invalidate(platingAdviceProvider(_recipeId));
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error);
    } finally {
      if (mounted) setState(() => _generatingImageIndex = null);
    }
  }

  /// Le visuel du dressage terminé, indexé après la dernière étape.
  Future<void> _generateFinalImage(PlatingAdvice advice) async {
    setState(() {
      _generatingImageIndex = advice.etapes.length;
      _actionError = null;
    });
    try {
      final url = await ref
          .read(platingRepositoryProvider)
          .generateFinalImage(recipeId: _recipeId);
      if (!mounted) return;
      setState(() => _localAdvice = advice.copyWith(finalImageUrl: url));
      ref.invalidate(platingAdviceProvider(_recipeId));
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error);
    } finally {
      if (mounted) setState(() => _generatingImageIndex = null);
    }
  }

  Future<void> _insertIntoRecipe(PlatingAdvice advice) async {
    final section = buildPlatingSection(advice);
    final replacesExisting =
        removePlatingSection(widget.recipe.rawCooklang).length <
        widget.recipe.rawCooklang.length;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Intégrer le dressage à la recette'),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  replacesExisting
                      ? 'Une section « $kPlatingSectionTitle » existe déjà dans cette '
                            'recette : elle sera remplacée par le texte ci-dessous.'
                      : 'Le texte ci-dessous sera ajouté à la fin de la recette.',
                ),
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: SelectableText(
                    section,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Intégrer'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ref
          .read(platingRepositoryProvider)
          .writeSectionToRecipe(
            recipeId: _recipeId,
            currentCooklang: widget.recipe.rawCooklang,
            advice: advice,
          );
      if (!mounted) return;
      ref.invalidate(recipeDetailProvider(_recipeId));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Dressage intégré à la recette ✓')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(shortErrorMessage(error))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final stored = ref.watch(platingAdviceProvider(_recipeId));
    final advice = _localAdvice ?? stored.value;

    if (_generating) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: AppLoadingState(
          label: 'Le moteur regarde cette recette et compose le dressage…',
        ),
      );
    }

    if (advice == null) {
      return stored.render(
        data: (_) => _EmptyState(
          controller: _instructionCtrl,
          onGenerate: _generate,
          error: _actionError,
        ),
        onRetry: () => ref.invalidate(platingAdviceProvider(_recipeId)),
        loadingLabel: 'Lecture du dressage…',
        compactError: true,
      );
    }

    return _AdviceView(
      advice: advice,
      canEdit: widget.canEdit,
      generatingImageIndex: _generatingImageIndex,
      error: _actionError,
      onGenerateImage: (index) => _generateImage(advice, index),
      onGenerateFinalImage: () => _generateFinalImage(advice),
      onRegenerate: () => _askInstructionThenGenerate(advice),
      onInsert: () => _insertIntoRecipe(advice),
    );
  }

  /// Regénérer sans pouvoir changer la consigne produirait deux fois le même
  /// conseil, au même prix.
  Future<void> _askInstructionThenGenerate(PlatingAdvice advice) async {
    _instructionCtrl.text = advice.userInstruction ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Nouveau conseil de dressage'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Précisez le contexte de service si besoin — le conseil sera '
              'recalculé pour cette recette.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _instructionCtrl,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Contexte (facultatif)',
                hintText: 'assiettes creuses, buffet froid, à emporter…',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Regénérer'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _generate();
  }
}

/// Aucun conseil encore demandé : on explique ce que le bouton va faire.
class _EmptyState extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onGenerate;
  final Object? error;

  const _EmptyState({
    required this.controller,
    required this.onGenerate,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ExcludeSemantics(
                      child: Icon(
                        Icons.restaurant_outlined,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Dressage sur mesure',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Le moteur lit cette recette et décrit son envoi : quel '
                  'contenant, dans quel ordre poser les éléments, et ce qui '
                  'rate si l\'ordre change. Sur les montages complexes, il '
                  'propose des visuels d\'étape.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    labelText: 'Contexte de service (facultatif)',
                    hintText: 'assiettes creuses, buffet froid, à emporter…',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: onGenerate,
                  icon: const Icon(Icons.auto_awesome_outlined),
                  label: const Text('Demander un dressage sur mesure'),
                ),
              ],
            ),
          ),
        ),
        if (error != null) ...[
          const SizedBox(height: 12),
          AppErrorState(error: error, compact: true),
        ],
      ],
    );
  }
}

class _AdviceView extends StatelessWidget {
  final PlatingAdvice advice;
  final bool canEdit;
  final int? generatingImageIndex;
  final Object? error;
  final void Function(int index) onGenerateImage;
  final VoidCallback onGenerateFinalImage;
  final VoidCallback onRegenerate;
  final VoidCallback onInsert;

  const _AdviceView({
    required this.advice,
    required this.canEdit,
    required this.generatingImageIndex,
    required this.error,
    required this.onGenerateImage,
    required this.onGenerateFinalImage,
    required this.onRegenerate,
    required this.onInsert,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PlatingHeaderCard(advice: advice),
        const SizedBox(height: 12),
        for (var i = 0; i < advice.etapes.length; i++) ...[
          PlatingStepCard(
            index: i,
            step: advice.etapes[i],
            generating: generatingImageIndex == i,
            onGenerateImage: canEdit && advice.etapes[i].canGenerateImage
                ? () => onGenerateImage(i)
                : null,
          ),
          const SizedBox(height: 12),
        ],
        if (advice.pieges.isNotEmpty) ...[
          PlatingListCard(
            title: 'Ce qui rate sur ce plat',
            icon: Icons.warning_amber_outlined,
            items: advice.pieges,
          ),
          const SizedBox(height: 12),
        ],
        if (advice.derniereMinute.isNotEmpty) ...[
          PlatingListCard(
            title: 'Au dernier moment',
            icon: Icons.timer_outlined,
            items: advice.derniereMinute,
          ),
          const SizedBox(height: 12),
        ],
        Card(
          margin: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    ExcludeSemantics(
                      child: Icon(Icons.photo_size_select_actual_outlined, size: 18),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Le résultat dressé',
                      style: theme.textTheme.titleSmall,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (advice.finalImageUrl != null)
                  Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: PlatingImage(url: advice.finalImageUrl!),
                    ),
                  )
                else if (canEdit)
                  PlatingImageAction(
                    generating: generatingImageIndex == advice.etapes.length,
                    onGenerate: onGenerateFinalImage,
                    label: 'Voir le résultat final',
                  )
                else
                  Text(
                    'Aucun visuel du dressage terminé n\'a encore été produit.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (error != null) ...[
          AppErrorState(error: error, compact: true),
          const SizedBox(height: 12),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: onRegenerate,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Regénérer'),
            ),
            if (canEdit)
              FilledButton.tonalIcon(
                onPressed: onInsert,
                icon: const Icon(Icons.playlist_add, size: 18),
                label: Text(
                  advice.hasImages
                      ? 'Intégrer texte et visuels'
                      : 'Intégrer à la recette',
                ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          _provenance(advice),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Le moteur est nommé en label, jamais fondu dans le conseil lui-même.
String _provenance(PlatingAdvice advice) {
  final engine = advice.provider == 'anthropic' ? 'Claude' : 'Gemini';
  final model = advice.model.isNotEmpty ? ' (${advice.model})' : '';
  final date = advice.generatedAt;
  final when = date == null
      ? ''
      : ' · ${date.day.toString().padLeft(2, '0')}/'
            '${date.month.toString().padLeft(2, '0')}/${date.year}';
  return 'Conseil produit par $engine$model$when';
}
