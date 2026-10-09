import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../domain/recipe.dart';
import '../../recipe_providers.dart';
import '../nutrition_details_section.dart';

/// Onglet « Nutrition » : métriques par portion et détail par ingrédient.
///
/// Extrait de recipe_detail_screen.dart.

class NutritionTab extends ConsumerWidget {
  final String recipeId;
  final Recipe recipe;
  final int? basePortions;
  final int? selectedPortions;

  /// Créateur de la recette ou administrateur : seul à pouvoir relancer le
  /// calcul, qui s'écrit sur la recette.
  final bool canRecompute;

  const NutritionTab({
    super.key,
    required this.recipeId,
    required this.recipe,
    required this.basePortions,
    required this.selectedPortions,
    required this.canRecompute,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: NutritionDetailsSection(
        recipe: recipe,
        selectedPortions: selectedPortions,
        onRecompute: canRecompute
            ? () async {
                await ref
                    .read(recipeRepositoryProvider)
                    .recomputeNutrition(recipeId: recipeId);
              }
            : null,
      ),
    );
  }
}
