import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/widgets/app_states.dart';
import '../../../core/widgets/error_message.dart';
import '../data/feature_catalog.dart';
import '../data/monthly_costs_repository.dart';
import 'reconciliation_tab.dart';

/// Ce que coûte l'application, mois par mois.
///
/// Un seul écran pour deux natures de coûts : l'inférence, que l'application
/// mesure elle-même et sait rattacher à un poste fonctionnel, et
/// l'infrastructure, que seule la facturation Google connaît et qui ne se
/// ventile que par service. Les présenter séparément dans deux écrans laissait
/// la question « combien coûte tout ça » sans réponse.
///
/// Aucun montant n'est calculé ici. Ils viennent des agrégats mensuels, où le
/// coût a été figé au moment de l'appel.

final monthlyCostsRepositoryProvider = Provider<MonthlyCostsRepository>(
  (ref) => MonthlyCostsRepository(),
);

/// Profondeur d'historique demandée, en mois.
class CostsDepthNotifier extends Notifier<int> {
  @override
  int build() => 12;

  void set(int months) => state = months;
}

final costsDepthProvider = NotifierProvider<CostsDepthNotifier, int>(
  CostsDepthNotifier.new,
);

final monthlyCostsProvider = FutureProvider.autoDispose<MonthlyCostsReport>((
  ref,
) async {
  final months = ref.watch(costsDepthProvider);
  return ref.watch(monthlyCostsRepositoryProvider).fetch(months: months);
});

class MonthlyCostsScreen extends ConsumerWidget {
  const MonthlyCostsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Coûts de l\'application'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Mois par mois'),
              Tab(text: 'Réconciliation'),
            ],
          ),
          actions: [
            IconButton(
              tooltip: 'Rafraîchir',
              icon: const Icon(Icons.refresh),
              onPressed: () => ref.invalidate(monthlyCostsProvider),
            ),
          ],
        ),
        body: const TabBarView(
          children: [_MonthlyTab(), ReconciliationTab()],
        ),
      ),
    );
  }
}

class _MonthlyTab extends ConsumerWidget {
  const _MonthlyTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reportAsync = ref.watch(monthlyCostsProvider);
    final depth = ref.watch(costsDepthProvider);

    return reportAsync.render(
      loadingLabel: 'Lecture des coûts…',
      onRetry: () => ref.invalidate(monthlyCostsProvider),
      data: (report) {
        final months = report.months.reversed.toList(growable: false);
        final maxTotal = months.fold<double>(
          0,
          (max, m) => m.totalCostUsd > max ? m.totalCostUsd : max,
        );

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _Header(report: report, depth: depth),
            if (report.gcpQueryFailed) ...[
              const SizedBox(height: 12),
              _Warning(
                text:
                    'La facturation Google n\'a pas pu être lue : les montants '
                    'd\'infrastructure de cet écran sont incomplets.',
              ),
            ],
            const SizedBox(height: 16),
            for (final month in months) ...[
              _MonthCard(
                month: month,
                usdToEur: report.usdToEur,
                maxTotal: maxTotal,
              ),
              const SizedBox(height: 12),
            ],
            if (months.isEmpty)
              const AppEmptyState(
                icon: Icons.euro_outlined,
                title: 'Aucun coût enregistré',
                message:
                    'Aucun appel n\'a encore été comptabilisé sur la période. '
                    'Si l\'historique existe mais n\'apparaît pas, '
                    'reconstruisez les agrégats.',
              ),
          ],
        );
      },
    );
  }
}

class _Header extends ConsumerStatefulWidget {
  final MonthlyCostsReport report;
  final int depth;

  const _Header({required this.report, required this.depth});

  @override
  ConsumerState<_Header> createState() => _HeaderState();
}

class _HeaderState extends ConsumerState<_Header> {
  bool _rebuilding = false;

  Future<void> _rebuild() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reconstruire les agrégats'),
        content: Text(
          'Les ${widget.depth} derniers mois seront recalculés depuis les '
          'lignes d\'appel. Sert à rattraper un historique antérieur au suivi '
          'mensuel, ou à réparer un mois dont les compteurs ont dérivé. '
          'Aucun coût d\'IA n\'est engagé.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reconstruire'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _rebuilding = true);
    try {
      final count = await ref
          .read(monthlyCostsRepositoryProvider)
          .rebuild(months: widget.depth);
      if (!mounted) return;
      ref.invalidate(monthlyCostsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$count mois reconstruits ✓')),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(shortErrorMessage(error))));
    } finally {
      if (mounted) setState(() => _rebuilding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final report = widget.report;
    final total = report.totalCostUsd;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Total sur la période',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _money(total, report.usdToEur),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final months in const [3, 6, 12])
                  ChoiceChip(
                    label: Text('$months mois'),
                    selected: widget.depth == months,
                    onSelected: (_) =>
                        ref.read(costsDepthProvider.notifier).set(months),
                  ),
                const SizedBox(width: 8),
                if (_rebuilding)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  OutlinedButton.icon(
                    onPressed: _rebuild,
                    icon: const Icon(Icons.build_outlined, size: 18),
                    label: const Text('Reconstruire les agrégats'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthCard extends StatelessWidget {
  final MonthlyCost month;
  final double usdToEur;
  final double maxTotal;

  const _MonthCard({
    required this.month,
    required this.usdToEur,
    required this.maxTotal,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ratio = maxTotal > 0 ? (month.totalCostUsd / maxTotal) : 0.0;

    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        shape: const Border(),
        title: Row(
          children: [
            Expanded(
              child: Text(
                month.label,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              _money(month.totalCostUsd, usdToEur),
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Barre proportionnelle au mois le plus cher : la comparaison
              // d'un mois à l'autre se fait d'un coup d'œil, sans lire les
              // chiffres.
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: ratio.clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'IA ${_money(month.aiCostUsd, usdToEur)} · '
                'Infrastructure ${_money(month.gcpCostUsd, usdToEur)} · '
                '${month.aiCalls} appels',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          if (month.costByProvider.isNotEmpty) ...[
            _SectionTitle(title: 'Par moteur'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final entry in month.costByProvider.entries)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      '${_providerLabel(entry.key)} · '
                      '${_money(entry.value, usdToEur)}',
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          if (month.features.isNotEmpty) ...[
            _SectionTitle(title: 'Par poste fonctionnel'),
            for (final feature in month.features)
              _FeatureRow(feature: feature, usdToEur: usdToEur),
            const SizedBox(height: 16),
          ],
          if (month.services.isNotEmpty) ...[
            _SectionTitle(title: 'Infrastructure, par service'),
            for (final service in month.services)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(child: Text(service.service)),
                    Text(_money(service.costUsd, usdToEur)),
                  ],
                ),
              ),
          ],
          if (month.features.isEmpty && month.services.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Aucun détail enregistré pour ce mois.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _FeatureRow extends StatelessWidget {
  final FeatureCost feature;
  final double usdToEur;

  const _FeatureRow({required this.feature, required this.usdToEur});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Le catalogue traduit la clé technique en libellé ; une clé inconnue
    // s'affiche telle quelle plutôt que de disparaître.
    final label = featureLabel(feature.feature);
    final providers = feature.costByProvider.entries
        .where((e) => e.value > 0)
        .map((e) => _providerLabel(e.key))
        .join(', ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label),
                Text(
                  '${feature.calls} appels'
                  '${providers.isEmpty ? '' : ' · $providers'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _money(feature.costUsd, usdToEur),
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;

  const _SectionTitle({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _Warning extends StatelessWidget {
  final String text;

  const _Warning({required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_outlined, color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: theme.colorScheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

/// Montant en euros, avec le dollar en second — la facture arrive en euros,
/// la grille tarifaire est en dollars.
String _money(double usd, double usdToEur) {
  final eur = usd * usdToEur;
  final eurText = eur < 1 ? eur.toStringAsFixed(4) : eur.toStringAsFixed(2);
  final usdText = usd < 1 ? usd.toStringAsFixed(4) : usd.toStringAsFixed(2);
  return usdToEur > 0 ? '$eurText € ($usdText \$)' : '$usdText \$';
}

String _providerLabel(String provider) => switch (provider) {
  'anthropic' => 'Claude',
  'gemini' => 'Gemini',
  'internal' => 'Interne',
  _ => provider,
};
