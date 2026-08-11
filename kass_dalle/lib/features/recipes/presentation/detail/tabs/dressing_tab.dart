import 'package:flutter/material.dart';

import '../../../domain/recipe.dart';
import '../dressing_coach_screen.dart';

/// Onglet « Dressage » : accès au coach de dressage.
///
/// Extrait de recipe_detail_screen.dart.

class DressingTab extends StatelessWidget {
  final Recipe recipe;
  final int? basePortions;
  final int? selectedPortions;

  const DressingTab({
    super.key,
    required this.recipe,
    required this.basePortions,
    required this.selectedPortions,
  });

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: DressingGuidanceSection(
        recipe: recipe,
        basePortions: basePortions,
        selectedPortions: selectedPortions,
      ),
    );
  }
}
