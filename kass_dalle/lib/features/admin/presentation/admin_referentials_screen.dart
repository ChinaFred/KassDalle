import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';

/// Point d'entrée unique vers les outils référentiels.
///
/// Regroupe les vues de visualisation et CRUD pour nutrition + unités.
class AdminReferentialsScreen extends StatelessWidget {
  const AdminReferentialsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Référentiels')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Card(
              child: ListTile(
                leading: Icon(
                  Icons.food_bank_outlined,
                  color: theme.colorScheme.secondary,
                ),
                title: const Text('Nutrition Ingredients'),
                subtitle: const Text(
                  'Visualisation de nutrition_ingredients et valeurs per100g.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppRoutes.adminNutritionIngredients),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Card(
              child: ListTile(
                leading: Icon(
                  Icons.straighten,
                  color: theme.colorScheme.secondary,
                ),
                title: const Text('Nutrition Units'),
                subtitle: const Text(
                  'CRUD du référentiel nutrition_units (unités, alias, statuts, conversions).',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppRoutes.adminNutritionUnits),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
