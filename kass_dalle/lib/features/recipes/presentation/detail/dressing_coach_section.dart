import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/widgets/app_states.dart';
import '../../../../core/widgets/error_message.dart';
import '../../../admin/data/ai_pricing.dart';
import '../../domain/plating_advice.dart';
import '../../domain/plating_text.dart';
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

  /// Illustre jusqu'à l'étape demandée, en partant de la première manquante.
  ///
  /// Chaque visuel se construit sur le précédent : illustrer l'étape 3 sans
  /// avoir les étapes 1 et 2 produirait une assiette née de rien, sans rapport
  /// avec celles qu'on générerait ensuite. La chaîne est séquentielle, la
  /// génération l'est donc aussi.
  Future<void> _generateUpTo(PlatingAdvice advice, int index) async {
    final missing = advice.missingImageIndexesUpTo(index);
    if (missing.isEmpty) return;

    if (missing.length > 1 && !await _confirmCascade(missing.length)) return;

    var current = advice;
    setState(() => _actionError = null);
    for (final step in missing) {
      setState(() => _generatingImageIndex = step);
      try {
        final url = await ref
            .read(platingRepositoryProvider)
            .generateStepImage(recipeId: _recipeId, stepIndex: step);
        if (!mounted) return;
        current = current.copyWithStep(
          step,
          current.etapes[step].copyWith(imageUrl: url),
        );
        setState(() => _localAdvice = current);
      } catch (error) {
        // Ce qui a été produit avant l'échec reste : la chaîne reprendra là
        // où elle s'est arrêtée.
        if (!mounted) return;
        setState(() => _actionError = error);
        break;
      }
    }
    if (!mounted) return;
    setState(() => _generatingImageIndex = null);
    ref.invalidate(platingAdviceProvider(_recipeId));
  }

  /// Refait le dernier visuel produit, à partir de celui qui le précède.
  Future<void> _redoLastImage(PlatingAdvice advice, int index) async {
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

  /// Le coût n'est pas une surprise à découvrir sur la facture.
  Future<bool> _confirmCascade(int count) async {
    final cost = AiPricing.costUsd(
      model: kPlatingImageModel,
      inputTokens: 0,
      outputTokens: 0,
      imageOutputCount: count,
    );
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Illustrer le montage'),
        content: Text(
          'Chaque visuel se construit sur le précédent : $count visuels seront '
          'créés dans l\'ordre, pour environ ${cost.toStringAsFixed(2)} \$.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Créer $count visuels'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  /// Efface tous les visuels pour repartir d'une assiette vide.
  ///
  /// C'est la seule façon de refaire une étape du milieu : la suivante en
  /// descend, la garder afficherait une assiette que son étape ne produit plus.
  Future<void> _resetImages(PlatingAdvice advice) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Réinitialiser les visuels'),
        content: const Text(
          'Seules les images de montage seront effacées : le conseil, ses '
          'étapes et son texte restent exactement tels quels. Vous pourrez '
          'illustrer à nouveau, étape par étape.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Effacer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ref.read(platingRepositoryProvider).clearImages(recipeId: _recipeId);
      if (!mounted) return;
      setState(() {
        _localAdvice = advice.copyWith(
          etapes: [
            for (final step in advice.etapes) step.withoutImage(),
          ],
        );
        _actionError = null;
      });
      ref.invalidate(platingAdviceProvider(_recipeId));
    } catch (error) {
      if (!mounted) return;
      setState(() => _actionError = error);
    }
  }

  Future<void> _copyText(PlatingAdvice advice) async {
    final text = buildPlatingText(advice, recipeTitle: widget.recipe.titre);
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Texte du dressage copié ✓')));
  }

  /// Défait l'insertion faite par les versions où le conseil était recopié
  /// dans la recette. Le dressage a son propre texte, il n'a rien à faire au
  /// milieu des étapes de cuisson.
  Future<void> _removeFromRecipe() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Retirer le dressage de la recette'),
        content: const Text(
          'La section « Dressage » sera supprimée du texte de la recette. '
          'Le conseil reste consultable dans cet onglet, avec ses visuels.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Retirer'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ref
          .read(platingRepositoryProvider)
          .removeSectionFromRecipe(
            recipeId: _recipeId,
            currentCooklang: widget.recipe.rawCooklang,
          );
      if (!mounted) return;
      ref.invalidate(recipeDetailProvider(_recipeId));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Dressage retiré de la recette ✓')),
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
      onGenerateImage: (index) => _generateUpTo(advice, index),
      onRedoImage: (index) => _redoLastImage(advice, index),
      onResetImages: advice.hasImages ? () => _resetImages(advice) : null,
      onRegenerate: () => _askInstructionThenGenerate(advice),
      onCopyText: () => _copyText(advice),
      onRemoveFromRecipe: hasPlatingSection(widget.recipe.rawCooklang)
          ? _removeFromRecipe
          : null,
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
  final void Function(int index) onRedoImage;

  /// Null quand aucun visuel n'existe encore.
  final VoidCallback? onResetImages;
  final VoidCallback onRegenerate;
  final VoidCallback onCopyText;

  /// Non nul seulement si la recette porte encore une section « Dressage »
  /// insérée par une version antérieure.
  final VoidCallback? onRemoveFromRecipe;

  const _AdviceView({
    required this.advice,
    required this.canEdit,
    required this.generatingImageIndex,
    required this.error,
    required this.onGenerateImage,
    required this.onRedoImage,
    required this.onResetImages,
    required this.onRegenerate,
    required this.onCopyText,
    required this.onRemoveFromRecipe,
  });

  /// Une génération est en cours : toute action qui modifierait la série est
  /// suspendue le temps qu'elle finisse.
  bool get busy => generatingImageIndex != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PlatingHeaderCard(advice: advice),
        const SizedBox(height: 12),
        // Les visuels forment une chaîne : seule la dernière image produite
        // peut être refaite. Reprendre une étape du milieu laisserait derrière
        // elle des images qui descendent d'une assiette qui n'existe plus.
        for (var i = 0; i < advice.etapes.length; i++) ...[
          PlatingStepCard(
            index: i,
            step: advice.etapes[i],
            generating: generatingImageIndex == i,
            busy: generatingImageIndex != null,
            onGenerateImage: canEdit && advice.etapes[i].imageUrl == null
                ? () => onGenerateImage(i)
                : null,
            onRedoImage: canEdit && i == advice.lastIllustratedIndex
                ? () => onRedoImage(i)
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
        if (error != null) ...[
          AppErrorState(error: error, compact: true),
          const SizedBox(height: 12),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            // Copier reste possible pendant une génération : c'est la seule
            // action qui ne touche à rien.
            OutlinedButton.icon(
              onPressed: busy ? null : onRegenerate,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Regénérer'),
            ),
            OutlinedButton.icon(
              onPressed: onCopyText,
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('Copier le texte'),
            ),
            if (canEdit && onResetImages != null)
              OutlinedButton.icon(
                onPressed: busy ? null : onResetImages,
                icon: const Icon(Icons.restart_alt, size: 18),
                label: const Text('Réinitialiser les visuels'),
              ),
            if (canEdit && onRemoveFromRecipe != null)
              TextButton.icon(
                onPressed: onRemoveFromRecipe,
                icon: const Icon(Icons.playlist_remove, size: 18),
                label: const Text('Retirer le dressage de la recette'),
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
