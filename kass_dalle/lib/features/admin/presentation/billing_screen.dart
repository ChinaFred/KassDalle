import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/domain/app_user.dart';
import '../data/billing_repository.dart';
import 'admin_providers.dart';

final billingRepositoryProvider = Provider<BillingRepository>(
  (ref) => BillingRepository(),
);

class BillingPeriodNotifier extends Notifier<BillingPeriod> {
  @override
  BillingPeriod build() => BillingPeriod.buildPresets().first;

  void set(BillingPeriod period) => state = period;
}

final billingPeriodProvider =
    NotifierProvider<BillingPeriodNotifier, BillingPeriod>(
  BillingPeriodNotifier.new,
);

final billingReportProvider = FutureProvider.autoDispose<BillingReport>((
  ref,
) async {
  final period = ref.watch(billingPeriodProvider);
  return ref.watch(billingRepositoryProvider).fetchReport(period);
});

/// Libellés lisibles pour chaque feature Gemini (réutilisés depuis token_usage_screen).
const _featureLabels = <String, String>{
  'scan_extraction': 'Extraction de recettes',
  'text_extraction': 'Saisie texte libre',
  'detect_illustrations': 'Détection illustrations',
  'detect_main_photo': 'Détection photo principale',
  'detect_grid_dims': 'Détection grille',
  'search': 'Recherche IA',
  'book_cover': 'Couverture de livre',
  'generate': 'Génération de recette',
  'refine': 'Amélioration IA',
  'web_search_query': 'Requête web',
  'classify_dish_types': 'Classification plats',
  'add_sections': 'Ajout de sections',
  'planning': 'Planification repas',
};

String _featureLabel(String f) => _featureLabels[f] ?? f;

String _fmtInt(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write('\u202f');
    buf.write(s[i]);
  }
  return buf.toString();
}

String _fmtEur(double v) => '${v.toStringAsFixed(v < 1 ? 4 : 2)} €';
String _fmtUsd(double v) => '\$${v.toStringAsFixed(v < 1 ? 4 : 2)}';

class BillingScreen extends ConsumerWidget {
  const BillingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final period = ref.watch(billingPeriodProvider);
    final reportAsync = ref.watch(billingReportProvider);
    final usersAsync = ref.watch(allUsersProvider);
    final presets = BillingPeriod.buildPresets();

    final usersById = <String, AppUser>{
      for (final u in usersAsync.value ?? const <AppUser>[]) u.uid: u,
    };

    String userLabel(String uid) {
      final u = usersById[uid];
      if (u == null) return uid.substring(0, uid.length.clamp(0, 8));
      if (u.displayName.isNotEmpty) return u.displayName;
      if (u.email.isNotEmpty) return u.email;
      return uid;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Comptabilité'),
        actions: [
          IconButton(
            tooltip: 'Rafraîchir',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(billingReportProvider),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: DropdownButtonFormField<String>(
              initialValue: period.id,
              decoration: const InputDecoration(
                labelText: 'Période',
                border: OutlineInputBorder(),
              ),
              items: presets
                  .map(
                    (p) => DropdownMenuItem(value: p.id, child: Text(p.label)),
                  )
                  .toList(),
              onChanged: (id) {
                if (id == null) return;
                final next = presets.firstWhere((p) => p.id == id);
                ref.read(billingPeriodProvider.notifier).set(next);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Card(
              color: theme.colorScheme.surfaceContainerHigh,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Phase 1 — Coûts Gemini estimés depuis `ai_usage`. '
                  'Les autres services GCP (Functions, Firestore, Storage…) '
                  'seront ajoutés en Phase 2 via l\'export BigQuery du billing.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ),
          ),
          Expanded(
            child: reportAsync.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Erreur : $e',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ),
              data: (report) => _BillingContent(
                report: report,
                userLabel: userLabel,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BillingContent extends StatelessWidget {
  final BillingReport report;
  final String Function(String uid) userLabel;

  const _BillingContent({required this.report, required this.userLabel});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final totals = report.totals;

    if (report.rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Aucune consommation Gemini sur cette période.',
            style: theme.textTheme.bodyMedium,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      children: [
        Card(
          color: theme.colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Total estimé : ${_fmtEur(totals.costEur)}  '
                  '(${_fmtUsd(totals.costUsd)})',
                  style: theme.textTheme.titleLarge,
                ),
                const SizedBox(height: 6),
                Text(
                  '${_fmtInt(totals.callCount)} appels · '
                  '${_fmtInt(totals.totalTokens)} tokens · '
                  '${totals.userCount} utilisateurs actifs',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  'Input : ${_fmtInt(totals.inputTokens)}  ·  '
                  'Output : ${_fmtInt(totals.outputTokens)}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _PerUserBreakdown(report: report, userLabel: userLabel),
        const SizedBox(height: 16),
        _PerFeatureBreakdown(report: report),
        const SizedBox(height: 16),
        Text(
          'Détail (utilisateur × feature × modèle)',
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Card(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 16,
              columns: const [
                DataColumn(label: Text('Utilisateur')),
                DataColumn(label: Text('Feature')),
                DataColumn(label: Text('Modèle')),
                DataColumn(label: Text('Appels'), numeric: true),
                DataColumn(label: Text('In tokens'), numeric: true),
                DataColumn(label: Text('Out tokens'), numeric: true),
                DataColumn(label: Text('Coût €'), numeric: true),
              ],
              rows: report.rows
                  .map(
                    (r) => DataRow(
                      cells: [
                        DataCell(Text(userLabel(r.uid))),
                        DataCell(Text(_featureLabel(r.feature))),
                        DataCell(Text(r.model)),
                        DataCell(Text(_fmtInt(r.callCount))),
                        DataCell(Text(_fmtInt(r.inputTokens))),
                        DataCell(Text(_fmtInt(r.outputTokens))),
                        DataCell(Text(_fmtEur(r.costEur))),
                      ],
                    ),
                  )
                  .toList(),
            ),
          ),
        ),
      ],
    );
  }
}

class _PerUserBreakdown extends StatelessWidget {
  final BillingReport report;
  final String Function(String uid) userLabel;

  const _PerUserBreakdown({required this.report, required this.userLabel});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final byUser = <String, double>{};
    final tokensByUser = <String, int>{};
    final callsByUser = <String, int>{};
    for (final r in report.rows) {
      byUser.update(r.uid, (v) => v + r.costEur, ifAbsent: () => r.costEur);
      tokensByUser.update(r.uid, (v) => v + r.totalTokens,
          ifAbsent: () => r.totalTokens);
      callsByUser.update(r.uid, (v) => v + r.callCount,
          ifAbsent: () => r.callCount);
    }
    final sorted = byUser.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Par utilisateur', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            ...sorted.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Text(
                        userLabel(e.key),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '${_fmtInt(callsByUser[e.key] ?? 0)} appels',
                        textAlign: TextAlign.end,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '${_fmtInt(tokensByUser[e.key] ?? 0)} tok',
                        textAlign: TextAlign.end,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    SizedBox(
                      width: 90,
                      child: Text(
                        _fmtEur(e.value),
                        textAlign: TextAlign.end,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PerFeatureBreakdown extends StatelessWidget {
  final BillingReport report;

  const _PerFeatureBreakdown({required this.report});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final byFeature = <String, double>{};
    final tokensByFeature = <String, int>{};
    final callsByFeature = <String, int>{};
    for (final r in report.rows) {
      byFeature.update(r.feature, (v) => v + r.costEur,
          ifAbsent: () => r.costEur);
      tokensByFeature.update(r.feature, (v) => v + r.totalTokens,
          ifAbsent: () => r.totalTokens);
      callsByFeature.update(r.feature, (v) => v + r.callCount,
          ifAbsent: () => r.callCount);
    }
    final sorted = byFeature.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Par feature', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            ...sorted.map(
              (e) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: Text(_featureLabel(e.key)),
                    ),
                    Expanded(
                      child: Text(
                        '${_fmtInt(callsByFeature[e.key] ?? 0)} appels',
                        textAlign: TextAlign.end,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    Expanded(
                      child: Text(
                        '${_fmtInt(tokensByFeature[e.key] ?? 0)} tok',
                        textAlign: TextAlign.end,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                    SizedBox(
                      width: 90,
                      child: Text(
                        _fmtEur(e.value),
                        textAlign: TextAlign.end,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
