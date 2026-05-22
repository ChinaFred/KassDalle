import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/domain/app_user.dart';
import '../data/billing_repository.dart';
import '../data/gcp_billing_repository.dart';
import 'admin_providers.dart';

final billingRepositoryProvider = Provider<BillingRepository>(
  (ref) => BillingRepository(),
);

final gcpBillingRepositoryProvider = Provider<GcpBillingRepository>(
  (ref) => GcpBillingRepository(),
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

final gcpCostsReportProvider = FutureProvider.autoDispose<GcpCostsReport>((
  ref,
) async {
  final period = ref.watch(billingPeriodProvider);
  return ref.watch(gcpBillingRepositoryProvider).fetchCosts(
        start: period.start,
        end: period.end,
      );
});

const _featureLabels = <String, String>{
  'scan_extraction': 'Extraction de recettes',
  'text_extraction': 'Saisie texte libre',
  'detect_illustrations': 'DÃ©tection illustrations',
  'detect_main_photo': 'DÃ©tection photo principale',
  'detect_grid_dims': 'DÃ©tection grille',
  'search': 'Recherche IA',
  'book_cover': 'Couverture de livre',
  'generate': 'GÃ©nÃ©ration de recette',
  'refine': 'AmÃ©lioration IA',
  'web_search_query': 'RequÃªte web',
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

String _fmtEur(double v) => '${v.toStringAsFixed(v < 1 ? 4 : 2)} â‚¬';
String _fmtUsd(double v) => '\$${v.toStringAsFixed(v < 1 ? 4 : 2)}';

// â”€â”€ Ã‰cran principal â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class BillingScreen extends ConsumerWidget {
  const BillingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final period = ref.watch(billingPeriodProvider);
    final reportAsync = ref.watch(billingReportProvider);
    final gcpAsync = ref.watch(gcpCostsReportProvider);
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

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('ComptabilitÃ©'),
          actions: [
            IconButton(
              tooltip: 'RafraÃ®chir',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                ref.invalidate(billingReportProvider);
                ref.invalidate(gcpCostsReportProvider);
              },
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.cloud_outlined), text: 'SynthÃ¨se GCP'),
              Tab(icon: Icon(Icons.token_outlined), text: 'CoÃ»ts Gemini'),
            ],
          ),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // SÃ©lecteur de pÃ©riode (commun aux deux onglets)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: DropdownButtonFormField<String>(
                value: period.id,
                decoration: const InputDecoration(
                  labelText: 'PÃ©riode',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: presets
                    .map((p) =>
                        DropdownMenuItem(value: p.id, child: Text(p.label)))
                    .toList(),
                onChanged: (id) {
                  if (id == null) return;
                  final next = presets.firstWhere((p) => p.id == id);
                  ref.read(billingPeriodProvider.notifier).set(next);
                },
              ),
            ),
            // Bandeau total combinÃ©
            reportAsync.when(
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
              data: (report) => gcpAsync.when(
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
                data: (gcp) {
                  final total =
                      report.totals.costEur + (gcp.hasData ? gcp.totalEur : 0);
                  return Container(
                    color: theme.colorScheme.primaryContainer,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    child: Text(
                      'Total pÃ©riode : ${_fmtEur(total)}'
                      '  Â·  Gemini estimÃ© : ${_fmtEur(report.totals.costEur)}'
                      '  Â·  Autres GCP : ${gcp.hasData ? _fmtEur(gcp.totalEur) : 'â€”'}',
                      style: theme.textTheme.bodySmall?.copyWith(
                          color:
                              theme.colorScheme.onPrimaryContainer),
                    ),
                  );
                },
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  // â”€â”€ Onglet 1 : SynthÃ¨se GCP â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                  _GcpTab(gcpAsync: gcpAsync),
                  // â”€â”€ Onglet 2 : CoÃ»ts Gemini â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
                  reportAsync.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (e, _) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text('Erreur : $e',
                            style: TextStyle(
                                color: theme.colorScheme.error)),
                      ),
                    ),
                    data: (report) => _GeminiTab(
                      report: report,
                      userLabel: userLabel,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// â”€â”€ Onglet 1 : SynthÃ¨se GCP â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _GcpTab extends StatefulWidget {
  final AsyncValue<GcpCostsReport> gcpAsync;

  const _GcpTab({required this.gcpAsync});

  @override
  State<_GcpTab> createState() => _GcpTabState();
}

class _GcpTabState extends State<_GcpTab> {
  String? _selectedService;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return widget.gcpAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Text('Erreur GCP : $e',
            style: TextStyle(color: theme.colorScheme.error)),
      ),
      data: (r) {
        if (!r.ready) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                "L'export BigQuery du Cloud Billing vient d'Ãªtre activÃ©.\n"
                "Les premiÃ¨res donnÃ©es apparaÃ®tront dans les 24 h.",
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          );
        }
        if (!r.hasData) {
          return const Center(
              child:
                  Text('Aucune consommation GCP sur cette pÃ©riode.'));
        }

        final services = _selectedService == null
            ? r.services
            : r.services
                .where((s) => s.service == _selectedService)
                .toList();

        final filteredTotal =
            services.fold(0.0, (s, e) => s + e.costEur);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Filtre service
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      value: _selectedService,
                      decoration: const InputDecoration(
                        labelText: 'Filtrer par service',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      items: [
                        const DropdownMenuItem<String?>(
                            value: null, child: Text('Tous les services')),
                        ...r.services.map((s) => DropdownMenuItem<String?>(
                              value: s.service,
                              child: Text(s.service),
                            )),
                      ],
                      onChanged: (v) =>
                          setState(() => _selectedService = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Total : ${_fmtEur(filteredTotal)}',
                    style: theme.textTheme.titleSmall,
                  ),
                ],
              ),
            ),
            // Tableau
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Card(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: DataTable(
                      columnSpacing: 20,
                      headingRowColor: WidgetStatePropertyAll(
                          theme.colorScheme.surfaceContainerHighest),
                      columns: const [
                        DataColumn(label: Text('Service GCP')),
                        DataColumn(
                            label: Text('CoÃ»t (â‚¬)'), numeric: true),
                        DataColumn(
                            label: Text('CoÃ»t (\$)'), numeric: true),
                        DataColumn(
                            label: Text('% total'), numeric: true),
                      ],
                      rows: [
                        ...services.map(
                          (s) => DataRow(cells: [
                            DataCell(Text(s.service)),
                            DataCell(Text(_fmtEur(s.costEur))),
                            DataCell(Text(_fmtUsd(s.costUsd))),
                            DataCell(Text(
                              r.totalEur > 0
                                  ? '${(s.costEur / r.totalEur * 100).toStringAsFixed(1)} %'
                                  : 'â€”',
                            )),
                          ]),
                        ),
                        // Ligne totale
                        DataRow(
                          color: WidgetStatePropertyAll(
                              theme.colorScheme.surfaceContainerHighest),
                          cells: [
                            DataCell(Text('TOTAL',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold))),
                            DataCell(Text(_fmtEur(filteredTotal),
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold))),
                            DataCell(Text(
                                _fmtUsd(services.fold(
                                    0.0, (s, e) => s + e.costUsd)),
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold))),
                            DataCell(Text(
                                _selectedService == null ? '100 %' : 'â€”',
                                style: const TextStyle(
                                    fontWeight: FontWeight.bold))),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// â”€â”€ Onglet 2 : CoÃ»ts Gemini â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _GeminiTab extends StatefulWidget {
  final BillingReport report;
  final String Function(String uid) userLabel;

  const _GeminiTab(
      {required this.report, required this.userLabel});

  @override
  State<_GeminiTab> createState() => _GeminiTabState();
}

class _GeminiTabState extends State<_GeminiTab> {
  String? _selectedUser;
  String? _selectedFeature;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allRows = widget.report.rows;

    // Filtrage
    var rows = allRows;
    if (_selectedUser != null) {
      rows = rows.where((r) => r.uid == _selectedUser).toList();
    }
    if (_selectedFeature != null) {
      rows = rows.where((r) => r.feature == _selectedFeature).toList();
    }

    if (allRows.isEmpty) {
      return const Center(
          child: Text('Aucune consommation Gemini sur cette pÃ©riode.'));
    }

    // â”€â”€ Totaux croisÃ©s â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    final allUids = allRows.map((r) => r.uid).toSet().toList();
    final allFeatures = allRows.map((r) => r.feature).toSet().toList()
      ..sort();

    // total par user (sur rows filtrÃ©es)
    final costByUser = <String, double>{};
    final callsByUser = <String, int>{};
    for (final r in rows) {
      costByUser.update(r.uid, (v) => v + r.costEur,
          ifAbsent: () => r.costEur);
      callsByUser.update(r.uid, (v) => v + r.callCount,
          ifAbsent: () => r.callCount);
    }

    // total par feature (sur rows filtrÃ©es)
    final costByFeature = <String, double>{};
    final callsByFeature = <String, int>{};
    for (final r in rows) {
      costByFeature.update(r.feature, (v) => v + r.costEur,
          ifAbsent: () => r.costEur);
      callsByFeature.update(r.feature, (v) => v + r.callCount,
          ifAbsent: () => r.callCount);
    }

    final grandTotal = rows.fold(0.0, (s, r) => s + r.costEur);
    final grandCalls = rows.fold(0, (s, r) => s + r.callCount);
    final grandTokens = rows.fold(0, (s, r) => s + r.totalTokens);

    final sortedUsers = costByUser.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final sortedFeatures = costByFeature.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        // â”€â”€ Filtres â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String?>(
                value: _selectedUser,
                decoration: const InputDecoration(
                  labelText: 'Utilisateur',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<String?>(
                      value: null, child: Text('Tous')),
                  ...allUids.map((uid) => DropdownMenuItem<String?>(
                        value: uid,
                        child: Text(widget.userLabel(uid),
                            overflow: TextOverflow.ellipsis),
                      )),
                ],
                onChanged: (v) => setState(() => _selectedUser = v),
              ),
            ),
            SizedBox(
              width: 260,
              child: DropdownButtonFormField<String?>(
                value: _selectedFeature,
                decoration: const InputDecoration(
                  labelText: 'Feature',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: [
                  const DropdownMenuItem<String?>(
                      value: null, child: Text('Toutes')),
                  ...allFeatures.map((f) => DropdownMenuItem<String?>(
                        value: f,
                        child: Text(_featureLabel(f)),
                      )),
                ],
                onChanged: (v) => setState(() => _selectedFeature = v),
              ),
            ),
            if (_selectedUser != null || _selectedFeature != null)
              TextButton.icon(
                onPressed: () => setState(() {
                  _selectedUser = null;
                  _selectedFeature = null;
                }),
                icon: const Icon(Icons.clear),
                label: const Text('RÃ©initialiser'),
              ),
          ],
        ),
        const SizedBox(height: 16),

        // â”€â”€ RÃ©sumÃ© global â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        Card(
          color: theme.colorScheme.secondaryContainer,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _CrossCell(label: 'CoÃ»t total', value: _fmtEur(grandTotal), bold: true),
                _CrossCell(label: 'Appels', value: _fmtInt(grandCalls)),
                _CrossCell(label: 'Tokens', value: _fmtInt(grandTokens)),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // â”€â”€ Tableau croisÃ© : Totaux par utilisateur â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        Text('Totaux par utilisateur', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        Card(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 16,
              dataRowMinHeight: 32,
              dataRowMaxHeight: 36,
              headingRowColor: WidgetStatePropertyAll(
                  theme.colorScheme.surfaceContainerHighest),
              columns: const [
                DataColumn(label: Text('Utilisateur')),
                DataColumn(label: Text('Appels'), numeric: true),
                DataColumn(label: Text('CoÃ»t â‚¬'), numeric: true),
              ],
              rows: sortedUsers
                  .map((e) => DataRow(cells: [
                        DataCell(
                          InkWell(
                            onTap: () => setState(
                                () => _selectedUser = _selectedUser == e.key
                                    ? null
                                    : e.key),
                            child: Text(widget.userLabel(e.key),
                                style: TextStyle(
                                    color: _selectedUser == e.key
                                        ? theme.colorScheme.primary
                                        : null,
                                    fontWeight: _selectedUser == e.key
                                        ? FontWeight.bold
                                        : null)),
                          ),
                        ),
                        DataCell(Text(_fmtInt(callsByUser[e.key] ?? 0))),
                        DataCell(Text(_fmtEur(e.value),
                            style: const TextStyle(
                                fontWeight: FontWeight.bold))),
                      ]))
                  .toList(),
            ),
          ),
        ),
        const SizedBox(height: 16),

        // â”€â”€ Tableau croisÃ© : Totaux par feature â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        Text('Totaux par feature', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        Card(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 16,
              dataRowMinHeight: 32,
              dataRowMaxHeight: 36,
              headingRowColor: WidgetStatePropertyAll(
                  theme.colorScheme.surfaceContainerHighest),
              columns: const [
                DataColumn(label: Text('Feature')),
                DataColumn(label: Text('Appels'), numeric: true),
                DataColumn(label: Text('CoÃ»t â‚¬'), numeric: true),
              ],
              rows: sortedFeatures
                  .map((e) => DataRow(cells: [
                        DataCell(
                          InkWell(
                            onTap: () => setState(
                                () => _selectedFeature =
                                    _selectedFeature == e.key
                                        ? null
                                        : e.key),
                            child: Text(_featureLabel(e.key),
                                style: TextStyle(
                                    color: _selectedFeature == e.key
                                        ? theme.colorScheme.primary
                                        : null,
                                    fontWeight: _selectedFeature == e.key
                                        ? FontWeight.bold
                                        : null)),
                          ),
                        ),
                        DataCell(Text(_fmtInt(callsByFeature[e.key] ?? 0))),
                        DataCell(Text(_fmtEur(e.value),
                            style: const TextStyle(
                                fontWeight: FontWeight.bold))),
                      ]))
                  .toList(),
            ),
          ),
        ),
        const SizedBox(height: 16),

        // â”€â”€ DÃ©tail complet â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
        Text(
          'DÃ©tail (utilisateur Ã— feature Ã— modÃ¨le) â€” ${rows.length} lignes',
          style: theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 6),
        Card(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columnSpacing: 16,
              dataRowMinHeight: 32,
              dataRowMaxHeight: 36,
              headingRowColor: WidgetStatePropertyAll(
                  theme.colorScheme.surfaceContainerHighest),
              columns: const [
                DataColumn(label: Text('Utilisateur')),
                DataColumn(label: Text('Feature')),
                DataColumn(label: Text('ModÃ¨le')),
                DataColumn(label: Text('Appels'), numeric: true),
                DataColumn(label: Text('In tok'), numeric: true),
                DataColumn(label: Text('Out tok'), numeric: true),
                DataColumn(label: Text('CoÃ»t â‚¬'), numeric: true),
              ],
              rows: rows
                  .map(
                    (r) => DataRow(cells: [
                      DataCell(Text(widget.userLabel(r.uid))),
                      DataCell(Text(_featureLabel(r.feature))),
                      DataCell(Text(r.model)),
                      DataCell(Text(_fmtInt(r.callCount))),
                      DataCell(Text(_fmtInt(r.inputTokens))),
                      DataCell(Text(_fmtInt(r.outputTokens))),
                      DataCell(Text(_fmtEur(r.costEur),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold))),
                    ]),
                  )
                  .toList(),
            ),
          ),
        ),
      ],
    );
  }
}

// â”€â”€ Widget utilitaire â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _CrossCell extends StatelessWidget {
  final String label;
  final String value;
  final bool bold;

  const _CrossCell(
      {required this.label, required this.value, this.bold = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: bold ? FontWeight.bold : FontWeight.normal,
              color: theme.colorScheme.onSecondaryContainer,
            )),
        Text(label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSecondaryContainer,
            )),
      ],
    );
  }
}


final billingRepositoryProvider = Provider<BillingRepository>(
  (ref) => BillingRepository(),
);

final gcpBillingRepositoryProvider = Provider<GcpBillingRepository>(
  (ref) => GcpBillingRepository(),
);

