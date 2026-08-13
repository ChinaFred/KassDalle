import 'package:flutter/material.dart';

import '../../../domain/recipe.dart';
import '../dressing_coach_section.dart';

/// Onglet « Dressage » : accès au coach de dressage.

class DressingTab extends StatelessWidget {
  final Recipe recipe;
  final bool canEdit;

  const DressingTab({super.key, required this.recipe, this.canEdit = false});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: DressingCoachSection(recipe: recipe, canEdit: canEdit),
    );
  }
}
