import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import 'billing_providers.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/theme/app_icon_size.dart';

/// Point d'entrée unique vers les outils référentiels.
///
/// Regroupe les vues de visualisation et CRUD pour nutrition + unités,
/// et affiche les KPIs courants de normalisation.
class AdminReferentialsScreen extends ConsumerWidget {
  const AdminReferentialsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final kpisAsync = ref.watch(referentialKpisProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Référentiels'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Rafraîchir les KPIs',
            onPressed: () => ref.invalidate(referentialKpisProvider),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          // ── KPIs normalisation ──────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.bar_chart_outlined,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'État de la normalisation',
                          style: theme.textTheme.titleMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    kpisAsync.when(
                      loading: () => const Center(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: CircularProgressIndicator(),
                        ),
                      ),
                      error: (e, _) => AppErrorState(
                        error: e,
                        title: 'Indicateurs indisponibles',
                        compact: true,
                        onRetry: () => ref.invalidate(referentialKpisProvider),
                      ),
                      data: (kpis) => _KpiGrid(kpis: kpis),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // ── Navigation référentiels ─────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Card(
              child: ListTile(
                leading: Icon(
                  Icons.food_bank_outlined,
                  color: theme.colorScheme.secondary,
                ),
                title: const Text('Ingrédients nutrition'),
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
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Card(
              child: ListTile(
                leading: Icon(
                  Icons.tune_outlined,
                  color: theme.colorScheme.secondary,
                ),
                title: const Text('Politique nutrition'),
                subtitle: const Text(
                  'Seuils qui décident de ce que l\'app affiche ou masque sur '
                  'l\'onglet Nutrition d\'une recette.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppRoutes.adminNutritionPolicy),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Card(
              child: ListTile(
                leading: Icon(
                  Icons.rice_bowl_outlined,
                  color: theme.colorScheme.secondary,
                ),
                title: const Text('Garnitures simples'),
                subtitle: const Text(
                  'Riz, pâtes, salade, yaourt : ce qui accompagne un plat sans '
                  'recette, avec la part par personne. Chacun peut retoucher '
                  'sa copie depuis ses préférences.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppRoutes.adminMealStaples),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _KpiGrid extends StatelessWidget {
  final Map<String, int> kpis;

  const _KpiGrid({required this.kpis});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = kpis['nutritionIngredientsTotal'] ?? 0;
    final enriched = kpis['nutritionIngredientsEnriched'] ?? 0;
    final pending = kpis['nutritionIngredientsPending'] ?? 0;
    final recipes = kpis['recipesTotal'] ?? 0;
    final enrichedPct = total > 0 ? (enriched / total * 100).round() : 0;

    return Column(
      children: [
        Row(
          children: [
            _KpiChip(
              label: 'Recettes',
              value: '$recipes',
              icon: Icons.menu_book_outlined,
            ),
            const SizedBox(width: 8),
            _KpiChip(
              label: 'Ingrédients référentiel',
              value: '$total',
              icon: Icons.food_bank_outlined,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _KpiChip(
              label: 'Enrichis (per100g)',
              value: '$enriched ($enrichedPct\u202f%)',
              icon: Icons.check_circle_outline,
            ),
            const SizedBox(width: 8),
            _KpiChip(
              label: 'En attente',
              value: '$pending',
              icon: Icons.hourglass_empty_outlined,
              color: pending > 0
                  ? theme.colorScheme.tertiary
                  : theme.colorScheme.primary,
            ),
          ],
        ),
        if (total > 0) ...[
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: total > 0 ? enriched / total : 0,
              minHeight: 6,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ],
    );
  }
}

class _KpiChip extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? color;

  const _KpiChip({
    required this.label,
    required this.value,
    required this.icon,
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final effectiveColor = color ?? theme.colorScheme.primary;

    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: effectiveColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: AppIconSize.small, color: effectiveColor),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    value,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: effectiveColor,
                    ),
                  ),
                  Text(label, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
