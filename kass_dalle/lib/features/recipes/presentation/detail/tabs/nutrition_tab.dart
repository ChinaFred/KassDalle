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

  const NutritionTab({
    super.key,
    required this.recipeId,
    required this.recipe,
    required this.basePortions,
    required this.selectedPortions,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: NutritionDetailsSection(
        recipe: recipe,
        selectedPortions: selectedPortions,
        onRecompute: () async {
          await ref
              .read(recipeRepositoryProvider)
              .recomputeNutrition(recipeId: recipeId);
        },
      ),
    );
  }
}
