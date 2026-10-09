import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/services/error_reporting.dart';
import '../../recipes/domain/recipe_advice_access.dart';
import '../../recipes/domain/storage_advice.dart';
import '../../recipes/presentation/recipe_providers.dart';
import '../domain/meal_prep_context.dart';
import '../domain/meal_storage_rules.dart';
import 'storage_advice_details.dart';
import '../../../core/theme/app_icon_size.dart';

/// Bandeau de préparation à l'avance, en tête de la fiche recette.
///
/// Il n'apparaît que lorsque la recette est ouverte depuis un repas planifié
/// dont le jour de préparation précède le repas : la même recette lue depuis un
/// livre n'a aucune raison de parler de conservation.
///
/// Deux natures de contenu s'y côtoient, et la distinction reste visible comme
/// dans la feuille du planning : la consigne du haut est **calculée** depuis le
/// délai réel — elle ne dépend d'aucun modèle et ne peut pas être fantaisiste ;
/// le détail dépliable est le conseil propre au plat, produit par l'IA.
class MealPrepBanner extends ConsumerStatefulWidget {
  final String recipeId;

  final MealPrepContext prepContext;

  const MealPrepBanner({
    super.key,
    required this.recipeId,
    required this.prepContext,
  });

  @override
  ConsumerState<MealPrepBanner> createState() => _MealPrepBannerState();
}

class _MealPrepBannerState extends ConsumerState<MealPrepBanner> {
  StorageAdvice? _advice;
  bool _loading = false;
  bool _failed = false;
  bool _expanded = false;

  /// Pourquoi aucun conseil n'est affiché, quand ce n'est pas une panne :
  /// conseil réservé au créateur, ou recette introuvable.
  String? _notice;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadAdvice());
  }

  /// Charge le conseil, en le produisant s'il manque.
  ///
  /// Déclenché sans geste de l'utilisateur : il a ouvert une recette qu'il doit
  /// cuisiner plusieurs jours à l'avance, la question de la conservation est
  /// déjà posée. L'appel n'a lieu qu'une fois par recette — le conseil est
  /// ensuite stocké sur elle et relu. Il n'a lieu que pour le créateur de la
  /// recette ou un administrateur ; les autres lisent le conseil stocké.
  Future<void> _loadAdvice() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = false;
      _notice = null;
    });
    try {
      // Le droit attend le profil : décidé avant son chargement, il
      // annonçait « réservé » au créateur lui-même.
      final canGenerate = await ref.read(canWriteRecipeAdviceProvider.future);
      final lookup = await ref
          .read(storageRepositoryProvider)
          .ensure(recipeId: widget.recipeId, canGenerate: canGenerate);
      if (!mounted) return;
      setState(() {
        switch (lookup) {
          case StorageAdviceAvailable(:final advice):
            _advice = advice;
          case StorageAdviceReserved():
            _notice = kStorageAdviceReservedMessage;
          case StorageAdviceRecipeMissing():
            _notice = kRecipeNotFoundMessage;
        }
      });
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'mealPrepBanner.loadAdvice',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final prep = widget.prepContext;
    final isFreezer = prep.mode == MealStorageMode.freezer;
    final container = isFreezer
        ? theme.colorScheme.tertiaryContainer
        : theme.colorScheme.primaryContainer;
    final onContainer = isFreezer
        ? theme.colorScheme.onTertiaryContainer
        : theme.colorScheme.onPrimaryContainer;
    final jourPrep = DateFormat(
      'EEEE d MMMM',
      'fr',
    ).format(prep.prepDate.toLocal());
    final jourRepas = DateFormat(
      'EEEE d MMMM',
      'fr',
    ).format(prep.mealDate.toLocal());

    return Card(
      margin: EdgeInsets.zero,
      color: container,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  isFreezer ? Icons.ac_unit_outlined : Icons.kitchen_outlined,
                  size: AppIconSize.small,
                  color: onContainer,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'À préparer le $jourPrep · '
                        '${mealStorageLabel(prep.mode).toLowerCase()}',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: onContainer,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Repas prévu le $jourRepas. ${prep.instruction}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: onContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _adviceArea(theme, onContainer),
          ],
        ),
      ),
    );
  }

  /// La partie produite par l'IA : en cours, en panne, ou dépliable.
  Widget _adviceArea(ThemeData theme, Color onContainer) {
    if (_loading) {
      return Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: onContainer,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            'Conseils de conservation et de réchauffage…',
            style: theme.textTheme.bodySmall?.copyWith(color: onContainer),
          ),
        ],
      );
    }

    if (_failed) {
      return Row(
        children: [
          Expanded(
            child: Text(
              'Conseils de conservation indisponibles. '
              'La consigne ci-dessus, elle, est calculée.',
              style: theme.textTheme.bodySmall?.copyWith(color: onContainer),
            ),
          ),
          TextButton(onPressed: _loadAdvice, child: const Text('Réessayer')),
        ],
      );
    }

    final advice = _advice;
    if (advice == null) {
      final notice = _notice;
      if (notice == null) return const SizedBox.shrink();
      return Text(
        notice,
        style: theme.textTheme.bodySmall?.copyWith(color: onContainer),
      );
    }

    final resume = advice.resume.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (resume.isNotEmpty)
          Text(
            resume,
            style: theme.textTheme.bodyMedium?.copyWith(color: onContainer),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () => setState(() => _expanded = !_expanded),
            icon: Icon(_expanded ? Icons.expand_less : Icons.expand_more),
            label: Text(
              _expanded
                  ? 'Masquer conservation et réchauffage'
                  : 'Conservation, réchauffage et dernier moment',
            ),
            style: TextButton.styleFrom(foregroundColor: onContainer),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: StorageAdviceDetails(advice: advice, showResume: false),
          ),
      ],
    );
  }
}
