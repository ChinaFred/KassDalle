import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/billing_repository.dart';
import '../data/feature_catalog.dart';
import '../data/gcp_billing_repository.dart';
import 'billing_providers.dart';

// ── Onglet 1 : Synthèse GCP ───────────────────────────────────────────────────

class BillingGcpTab extends StatefulWidget {
  final AsyncValue<GcpCostsReport> gcpAsync;

  const BillingGcpTab({super.key, required this.gcpAsync});

  @override
  State<BillingGcpTab> createState() => _BillingGcpTabState();
}

class _BillingGcpTabState extends State<BillingGcpTab> {
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
            // Sans taux de change, la ligne manque au total en dollars. Le
            // total reste plausible : seul ce bandeau signale qu'il est amputé.
            if (r.unconvertedRows > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${r.unconvertedRows} ligne(s) de facturation sans taux de '
                    'change : la colonne « Coût (\$) » est sous-estimée. '
                    'La colonne « Coût (€) » reste, elle, le montant facturé.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ),
            // Filtre service
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      initialValue: _selectedService,
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
                    'Total : ${billingFmtEur(filteredTotal)}',
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
                              DataCell(Text(billingFmtEur(s.costEur))),
                              DataCell(Text(billingFmtUsd(s.costUsd))),
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
                                billingFmtEur(filteredTotal),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            DataCell(
                              Text(
                                billingFmtUsd(
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

// ── Onglet 2 : Coûts Gemini ───────────────────────────────────────────────────

class BillingGeminiTab extends StatefulWidget {
  final BillingReport report;
  final String Function(String uid) userLabel;
  final double? billedGeminiEur;

  const BillingGeminiTab({
    super.key,
    required this.report,
    required this.userLabel,
    this.billedGeminiEur,
  });

  @override
  State<BillingGeminiTab> createState() => _BillingGeminiTabState();
}

class _BillingGeminiTabState extends State<BillingGeminiTab> {
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

    final billedGeminiEur = widget.billedGeminiEur;
    final hasAnyFilter = _selectedUser != null || _selectedFeature != null;

    // Réconciliation pro-rata : si on a le total BigQuery global et qu'aucun
    // filtre n'est appliqué, on distribue l'écart de valorisation sur les
    // lignes existantes pour aligner la somme affichée avec le coût facturé.
    final canApplyProRataReconciliation =
      billedGeminiEur != null && !hasAnyFilter && totalCost > 0;
    final valuationRatio = canApplyProRataReconciliation
      ? billedGeminiEur / totalCost
      : 1.0;

    final unassignedGeminiCost = billedGeminiEur == null
      ? 0.0
      : (billedGeminiEur - totalCost).clamp(0.0, double.infinity);
    final hasUnassignedGeminiCost =
      billedGeminiEur != null && unassignedGeminiCost >= 0.0001;
    final showUnassignedRow =
      hasUnassignedGeminiCost && !canApplyProRataReconciliation;
    final reconciledCost = canApplyProRataReconciliation
      ? billedGeminiEur
      : (totalCost + (showUnassignedRow ? unassignedGeminiCost : 0.0));

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
                  initialValue: _selectedUser,
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
                  initialValue: _selectedFeature,
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
                        child: Text(featureLabel(f)),
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
        if (canApplyProRataReconciliation && (valuationRatio - 1.0).abs() >= 0.01)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Réconciliation pro-rata appliquée : les coûts par ligne sont '
                'ajustés d\'un facteur ${valuationRatio.toStringAsFixed(2)} '
                'pour aligner le total sur la facturation Gemini BigQuery.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSecondaryContainer,
                ),
              ),
            ),
          ),
        if (showUnassignedRow)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Écart détecté: ${billingFmtEur(unassignedGeminiCost)} de coût Gemini '
                'facturé n\'est pas attribué aux lignes ai_usage sur ce filtre/période. '
                'Causes possibles : appels Gemini antérieurs au suivi ai_usage, '
                'tentatives en erreur (toujours facturées par Google), latence '
                'BigQuery (~24 h). Utilise le bouton "Tracer les appels non attribués" '
                'en haut pour rattraper depuis les logs Cloud Logging.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onTertiaryContainer,
                ),
              ),
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
                      (r) {
                        final displayedCostEur = r.costEur * valuationRatio;
                        return DataRow(
                        cells: [
                          DataCell(Text(widget.userLabel(r.uid))),
                          DataCell(
                            Tooltip(
                              message: featureDescription(r.feature),
                              child: Text(featureLabel(r.feature)),
                            ),
                          ),
                          DataCell(Text(r.model)),
                          DataCell(Text(billingFmtInt(r.callCount))),
                          DataCell(Text(billingFmtInt(r.inputTokens))),
                          DataCell(Text(billingFmtInt(r.outputTokens))),
                          DataCell(
                            Text(
                              billingFmtEur(displayedCostEur),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          DataCell(
                            Text(
                              r.callCount > 0
                                  ? billingFmtEur(displayedCostEur / r.callCount)
                                  : '—',
                            ),
                          ),
                        ],
                      );
                      },
                    ),
                    if (showUnassignedRow)
                      DataRow(
                        cells: [
                          const DataCell(Text('Non attribué')),
                          const DataCell(Text('Requêtes non tracées')),
                          const DataCell(Text('Gemini API (BigQuery)')),
                          const DataCell(Text('—')),
                          const DataCell(Text('—')),
                          const DataCell(Text('—')),
                          DataCell(
                            Text(
                              billingFmtEur(unassignedGeminiCost),
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const DataCell(Text('—')),
                        ],
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
                            billingFmtInt(totalCalls),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        DataCell(
                          Text(
                            billingFmtInt(totalIn),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        DataCell(
                          Text(
                            billingFmtInt(totalOut),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        DataCell(
                          Text(
                            billingFmtEur(reconciledCost),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        DataCell(
                          Text(
                            totalCalls > 0
                                ? billingFmtEur(reconciledCost / totalCalls)
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
