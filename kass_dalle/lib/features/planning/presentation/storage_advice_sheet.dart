import 'package:flutter/material.dart';

import '../../recipes/domain/storage_advice.dart';
import '../domain/meal_storage_rules.dart';
import 'storage_advice_details.dart';
import '../../../core/theme/app_icon_size.dart';

/// Feuille de conservation et de réchauffage d'un plat.
///
/// Deux natures de contenu s'y côtoient, et la distinction est délibérément
/// visible : en tête, la consigne **calculée** depuis le délai réel — elle ne
/// dépend d'aucun modèle et ne peut pas être fantaisiste ; en dessous, le
/// conseil propre au plat, produit par l'IA.
Future<void> showStorageAdviceSheet(
  BuildContext context, {
  required String titre,
  required StorageAdvice advice,
  required int daysAhead,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) =>
        _StorageSheet(titre: titre, advice: advice, daysAhead: daysAhead),
  );
}

class _StorageSheet extends StatelessWidget {
  final String titre;
  final StorageAdvice advice;
  final int daysAhead;

  const _StorageSheet({
    required this.titre,
    required this.advice,
    required this.daysAhead,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mode = mealStorageMode(daysAhead);

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        children: [
          Center(
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
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(Icons.kitchen_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Conservation — $titre',
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Consigne calculée : elle ne dépend d'aucune génération.
          if (daysAhead > 0)
            Card(
              margin: EdgeInsets.zero,
              color: mode == MealStorageMode.freezer
                  ? theme.colorScheme.tertiaryContainer
                  : theme.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      mode == MealStorageMode.freezer
                          ? Icons.ac_unit_outlined
                          : Icons.kitchen_outlined,
                      size: AppIconSize.small,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        mealStorageInstruction(daysAhead),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (daysAhead > 0) const SizedBox(height: 16),

          StorageAdviceDetails(advice: advice),
        ],
      ),
    );
  }
}
