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
  return ref
      .watch(gcpBillingRepositoryProvider)
      .fetchCosts(start: period.start, end: period.end);
});

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

// �"?�"? �?cran principal �"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?

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
          title: const Text('Comptabilité'),
          actions: [
            IconButton(
              tooltip: 'Rafraîchir',
              icon: const Icon(Icons.refresh),
              onPressed: () {
                ref.invalidate(billingReportProvider);
                ref.invalidate(gcpCostsReportProvider);
              },
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.cloud_outlined), text: 'Synthèse GCP'),
              Tab(icon: Icon(Icons.token_outlined), text: 'Coûts Gemini'),
            ],
          ),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Bannière stats (style identique à TokenUsageScreen)
            _BillingBanner(reportAsync: reportAsync, gcpAsync: gcpAsync),
            // Sélecteur de période (filtre léger, même style que FiltersRow)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: period.id,
                  isDense: true,
                  items: presets
                      .map(
                        (p) => DropdownMenuItem(
                          value: p.id,
                          child: Text(p.label),
                        ),
                      )
                      .toList(),
                  onChanged: (id) {
                    if (id == null) return;
                    final next = presets.firstWhere((p) => p.id == id);
                    ref.read(billingPeriodProvider.notifier).set(next);
                  },
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                children: [
                  _GcpTab(gcpAsync: gcpAsync),
                  reportAsync.when(
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
                    data: (report) =>
                        _GeminiTab(report: report, userLabel: userLabel),
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

// ── Bannière récapitulative ────────────────────────────────────────────────────

class _BillingBanner extends StatelessWidget {
  final AsyncValue<BillingReport> reportAsync;
  final AsyncValue<GcpCostsReport> gcpAsync;

  const _BillingBanner({
    required this.reportAsync,
    required this.gcpAsync,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final gcpEur = gcpAsync.whenOrNull(
      data: (gcp) => gcp.hasData ? _fmtEur(gcp.totalEur) : '\u2014',
    ) ?? '\u2014';

    final geminiEur = reportAsync.whenOrNull(
      data: (r) => _fmtEur(r.totals.costEur),
    ) ?? '\u2014';

    final calls = reportAsync.whenOrNull(
      data: (r) => _fmtInt(r.totals.callCount),
    ) ?? '\u2014';

    final isLoading =
        reportAsync is AsyncLoading || gcpAsync is AsyncLoading;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: theme.colorScheme.secondaryContainer,
      child: isLoading
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(8),
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          : Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _BillingStatChip(
                  icon: Icons.cloud_outlined,
                  label: gcpEur,
                  sublabel: 'GCP factur\u00e9',
                  bold: true,
                ),
                _BillingStatChip(
                  icon: Icons.auto_awesome_outlined,
                  label: geminiEur,
                  sublabel: 'Gemini estim\u00e9',
                ),
                _BillingStatChip(
                  icon: Icons.call_outlined,
                  label: calls,
                  sublabel: 'appels IA',
                ),
              ],
            ),
    );
  }
}

class _BillingStatChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final String sublabel;
  final bool bold;

  const _BillingStatChip({
    required this.icon,
    required this.label,
    required this.sublabel,
    this.bold = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: theme.colorScheme.onSecondaryContainer,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: bold ? FontWeight.bold : FontWeight.normal,
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ],
        ),
        Text(
          sublabel,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
      ],
    );
  }
}

// ── Onglet 1 : Synthèse GCP ───────────────────────────────────────────────────

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
        child: Text(
          'Erreur GCP : $e',
          style: TextStyle(color: theme.colorScheme.error),
        ),
      ),
      data: (r) {
        if (!r.ready) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                "L'export BigQuery du Cloud Billing vient d'être activé.\n"
                "Les premières données apparaîtront dans les 24 h.",
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          );
        }
        if (!r.hasData) {
          return const Center(
            child: Text('Aucune consommation GCP sur cette période.'),
          );
        }

        final services = _selectedService == null
            ? r.services
            : r.services.where((s) => s.service == _selectedService).toList();

        final filteredTotal = services.fold(0.0, (s, e) => s + e.costEur);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Filtre service
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
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
                          value: null,
                          child: Text('Tous les services'),
                        ),
                        ...r.services.map(
                          (s) => DropdownMenuItem<String?>(
                            value: s.service,
                            child: Text(s.service),
                          ),
                        ),
                      ],
                      onChanged: (v) => setState(() => _selectedService = v),
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
                        theme.colorScheme.surfaceContainerHighest,
                      ),
                      columns: const [
                        DataColumn(label: Text('Service GCP')),
                        DataColumn(label: Text('Coût (€)'), numeric: true),
                        DataColumn(label: Text('Coût (\$)'), numeric: true),
                        DataColumn(label: Text('% total'), numeric: true),
                      ],
                      rows: [
                        ...services.map(
                          (s) => DataRow(
                            cells: [
                              DataCell(Text(s.service)),
                              DataCell(Text(_fmtEur(s.costEur))),
                              DataCell(Text(_fmtUsd(s.costUsd))),
                              DataCell(
                                Text(
                                  r.totalEur > 0
                                      ? '${(s.costEur / r.totalEur * 100).toStringAsFixed(1)} %'
                                      : '—',
                                ),
                              ),
                            ],
                          ),
                        ),
                        // Ligne totale
                        DataRow(
                          color: WidgetStatePropertyAll(
                            theme.colorScheme.surfaceContainerHighest,
                          ),
                          cells: [
                            DataCell(
                              Text(
                                'TOTAL',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            DataCell(
                              Text(
                                _fmtEur(filteredTotal),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            DataCell(
                              Text(
                                _fmtUsd(
                                  services.fold(0.0, (s, e) => s + e.costUsd),
                                ),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            DataCell(
                              Text(
                                _selectedService == null ? '100 %' : '—',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
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

// �"?�"? Onglet 2 : Coûts Gemini �"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?�"?

class _GeminiTab extends StatefulWidget {
  final BillingReport report;
  final String Function(String uid) userLabel;

  const _GeminiTab({required this.report, required this.userLabel});

  @override
  State<_GeminiTab> createState() => _GeminiTabState();
}

class _GeminiTabState extends State<_GeminiTab> {
  String? _selectedUser;
  String? _selectedFeature;
  int _sortColumnIndex = 6; // coût par défaut
  bool _sortAscending = false;

  List<BillingRow> _sortRows(List<BillingRow> rows) {
    final sorted = List<BillingRow>.from(rows);
    sorted.sort((a, b) {
      int cmp;
      switch (_sortColumnIndex) {
        case 3:
          cmp = a.callCount.compareTo(b.callCount);
        case 4:
          cmp = a.inputTokens.compareTo(b.inputTokens);
        case 5:
          cmp = a.outputTokens.compareTo(b.outputTokens);
        case 6:
          cmp = a.costEur.compareTo(b.costEur);
        case 7:
          final aRate = a.callCount > 0 ? a.costEur / a.callCount : 0.0;
          final bRate = b.callCount > 0 ? b.costEur / b.callCount : 0.0;
          cmp = aRate.compareTo(bRate);
        default:
          cmp = 0;
      }
      return _sortAscending ? cmp : -cmp;
    });
    return sorted;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allRows = widget.report.rows;

    if (allRows.isEmpty) {
      return const Center(
        child: Text('Aucune consommation Gemini sur cette période.'),
      );
    }

    final allUids = allRows.map((r) => r.uid).toSet().toList();
    final allFeatures = allRows.map((r) => r.feature).toSet().toList()..sort();

    // Filtrage
    var filtered = allRows;
    if (_selectedUser != null) {
      filtered = filtered.where((r) => r.uid == _selectedUser).toList();
    }
    if (_selectedFeature != null) {
      filtered = filtered.where((r) => r.feature == _selectedFeature).toList();
    }
    final rows = _sortRows(filtered);

    // Totaux adaptés aux filtres
    final totalCalls = rows.fold(0, (s, r) => s + r.callCount);
    final totalIn = rows.fold(0, (s, r) => s + r.inputTokens);
    final totalOut = rows.fold(0, (s, r) => s + r.outputTokens);
    final totalCost = rows.fold(0.0, (s, r) => s + r.costEur);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Filtres
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Wrap(
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
                      value: null,
                      child: Text('Tous'),
                    ),
                    ...allUids.map(
                      (uid) => DropdownMenuItem<String?>(
                        value: uid,
                        child: Text(
                          widget.userLabel(uid),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
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
                      value: null,
                      child: Text('Toutes'),
                    ),
                    ...allFeatures.map(
                      (f) => DropdownMenuItem<String?>(
                        value: f,
                        child: Text(_featureLabel(f)),
                      ),
                    ),
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
                  label: const Text('Réinitialiser'),
                ),
            ],
          ),
        ),
        // Tableau avec tri et ligne total
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: Card(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  sortColumnIndex: _sortColumnIndex,
                  sortAscending: _sortAscending,
                  columnSpacing: 16,
                  dataRowMinHeight: 32,
                  dataRowMaxHeight: 36,
                  headingRowColor: WidgetStatePropertyAll(
                    theme.colorScheme.surfaceContainerHighest,
                  ),
                  columns: [
                    const DataColumn(label: Text('Utilisateur')),
                    const DataColumn(label: Text('Feature')),
                    const DataColumn(label: Text('Modèle')),
                    DataColumn(
                      label: const Text('Appels'),
                      numeric: true,
                      onSort: (i, asc) => setState(() {
                        _sortColumnIndex = i;
                        _sortAscending = asc;
                      }),
                    ),
                    DataColumn(
                      label: const Text('In tok'),
                      numeric: true,
                      onSort: (i, asc) => setState(() {
                        _sortColumnIndex = i;
                        _sortAscending = asc;
                      }),
                    ),
                    DataColumn(
                      label: const Text('Out tok'),
                      numeric: true,
                      onSort: (i, asc) => setState(() {
                        _sortColumnIndex = i;
                        _sortAscending = asc;
                      }),
                    ),
                    DataColumn(
                      label: const Text('Coût \u20ac'),
                      numeric: true,
                      onSort: (i, asc) => setState(() {
                        _sortColumnIndex = i;
                        _sortAscending = asc;
                      }),
                    ),
                    DataColumn(
                      label: const Text('\u20ac/appel'),
                      numeric: true,
                      onSort: (i, asc) => setState(() {
                        _sortColumnIndex = i;
                        _sortAscending = asc;
                      }),
                    ),
                  ],
                  rows: [
                    ...rows.map(
                      (r) => DataRow(
                        cells: [
                          DataCell(Text(widget.userLabel(r.uid))),
                          DataCell(Text(_featureLabel(r.feature))),
                          DataCell(Text(r.model)),
                          DataCell(Text(_fmtInt(r.callCount))),
                          DataCell(Text(_fmtInt(r.inputTokens))),
                          DataCell(Text(_fmtInt(r.outputTokens))),
                          DataCell(
                            Text(
                              _fmtEur(r.costEur),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          DataCell(
                            Text(
                              r.callCount > 0
                                  ? _fmtEur(r.costEur / r.callCount)
                                  : '—',
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Ligne total adaptée aux filtres
                    DataRow(
                      color: WidgetStatePropertyAll(
                        theme.colorScheme.surfaceContainerHighest,
                      ),
                      cells: [
                        DataCell(
                          Text(
                            'TOTAL — ${rows.length} lignes',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        const DataCell(Text('')),
                        const DataCell(Text('')),
                        DataCell(
                          Text(
                            _fmtInt(totalCalls),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        DataCell(
                          Text(
                            _fmtInt(totalIn),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        DataCell(
                          Text(
                            _fmtInt(totalOut),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        DataCell(
                          Text(
                            _fmtEur(totalCost),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        DataCell(
                          Text(
                            totalCalls > 0
                                ? _fmtEur(totalCost / totalCalls)
                                : '—',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
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
  }
}

