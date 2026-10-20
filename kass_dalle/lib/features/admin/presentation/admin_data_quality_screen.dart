import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'admin_server_message.dart';
import 'billing_providers.dart';
import '../domain/data_quality_report.dart';
import '../../../core/router/app_router.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/theme/app_icon_size.dart';

/// Dashboard de qualité des données (Admin → Monitoring).
///
/// Diagnostic en lecture seule : contrairement à `AdminBackfillsScreen`, rien
/// ici n'écrit dans Firestore. Le scan se relance à la demande — bouton
/// Actualiser — plutôt qu'à chaque ouverture, parce qu'il lit l'intégralité
/// des deux référentiels nutrition.
class AdminDataQualityScreen extends ConsumerWidget {
  const AdminDataQualityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reportAsync = ref.watch(dataQualityReportProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Qualité des données'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Relancer le scan',
            onPressed: () => ref.invalidate(dataQualityReportProvider),
          ),
        ],
      ),
      // `when` plutôt que `render` : l'erreur est une `CallableFailure`,
      // ramenée au code de la callable pour que le conseil et « Réessayer »
      // (absent pour un refus de droits) en dépendent.
      body: reportAsync.when(
        skipLoadingOnRefresh: false,
        loading: () =>
            const AppLoadingState(label: 'Scan des référentiels en cours...'),
        error: (error, _) => AppErrorState(
          error: readableError(error),
          onRetry: () => ref.invalidate(dataQualityReportProvider),
        ),
        data: (report) => _DataQualityBody(report: report),
      ),
    );
  }
}

class _DataQualityBody extends StatelessWidget {
  final DataQualityReport report;

  const _DataQualityBody({required this.report});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (!report.scanComplete)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Icon(
                      Icons.hourglass_bottom_outlined,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Le scan s\'est arrêté avant la fin des référentiels '
                        '(délai de sécurité). Les comptes ci-dessous sont des '
                        'minimums : relancez pour les compléter.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        _CategoryCard(
          icon: Icons.shopping_cart_outlined,
          title: 'Produit d\'achat manquant',
          description:
              'Ingrédients jamais examinés pour le regroupement des listes '
              'de courses.',
          check: report.missingShoppingProduct,
          targetRoute: AppRoutes.adminNutritionIngredients,
        ),
        _CategoryCard(
          icon: Icons.no_food_outlined,
          title: 'Nutrition incomplète ou échouée',
          description:
              'Ingrédients sans valeur exploitable, ou dont la dernière '
              'estimation a échoué.',
          check: report.incompleteNutrition,
          targetRoute: AppRoutes.adminNutritionIngredients,
        ),
        _CategoryCard(
          icon: Icons.warning_amber_outlined,
          title: 'Sel implausible',
          description:
              'Plus de 100 g de sel pour 100 g de produit — physiquement '
              'impossible.',
          check: report.implausibleSalt,
          targetRoute: AppRoutes.adminNutritionIngredients,
        ),
        _CategoryCard(
          icon: Icons.straighten_outlined,
          title: 'Unités non confirmées',
          description:
              'Unités estimées par l\'IA ou jamais résolues, triées par '
              'nombre de rencontres.',
          check: report.unconfirmedUnits,
          targetRoute: AppRoutes.adminNutritionUnits,
        ),
      ],
    );
  }
}

class _CategoryCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final DataQualityCheck check;

  /// Écran du référentiel où ouvrir un exemple, recherche prérempli sur son
  /// identifiant.
  final String targetRoute;

  const _CategoryCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.check,
    required this.targetRoute,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasIssues = check.count > 0;
    final badgeColor = hasIssues
        ? theme.colorScheme.error
        : theme.colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Card(
        child: ExpansionTile(
          leading: Icon(
            icon,
            color: hasIssues
                ? theme.colorScheme.error
                : theme.colorScheme.outline,
          ),
          title: Text(title),
          subtitle: Text(description),
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '${check.count}',
              style: theme.textTheme.labelLarge?.copyWith(
                color: badgeColor,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          children: _buildChildren(context, theme),
        ),
      ),
    );
  }

  List<Widget> _buildChildren(BuildContext context, ThemeData theme) {
    if (check.examples.isEmpty) {
      return const [
        Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('Aucun élément.'),
          ),
        ),
      ];
    }
    return [
      for (final example in check.examples)
        ListTile(
          dense: true,
          title: Text(example.label),
          subtitle: Text(example.detail),
          trailing: const Icon(Icons.chevron_right, size: AppIconSize.small),
          onTap: () => context.push(targetRoute, extra: example.id),
        ),
      if (check.truncatedExamples)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Text(
            '${check.examples.length} affichés sur ${check.count}.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
    ];
  }
}
