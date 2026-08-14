import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/feature_catalog.dart';
import '../data/monthly_costs_repository.dart';
import '../../../core/widgets/app_states.dart';
import 'costs_format.dart';
import 'monthly_costs_screen.dart';

/// Ce que coûte chaque appel d'IA, poste par poste.
///
/// L'écran mensuel répond à « combien ce mois a-t-il coûté ». Celui-ci répond à
/// « qu'est-ce qui coûte, et pourquoi ». Deux postes peuvent peser le même
/// montant pour des raisons opposées : l'un appelé mille fois pour trois fois
/// rien, l'autre trois fois pour un montant lourd. Le total seul ne les
/// distingue pas — le nombre d'appels et le coût unitaire, si. Le premier se
/// réduit en appelant moins, le second en changeant de modèle.
///
/// Claude et Gemini ont chacun leur colonne parce que la question posée est
/// souvent celle d'une bascule : facturés par des sociétés différentes, ils ne
/// se comparent que ventilés.

/// Axe de lecture : le poste technique, ou le processus qui le contient.
enum ServicesGrouping { feature, process }

class ServicesGroupingNotifier extends Notifier<ServicesGrouping> {
  @override
  ServicesGrouping build() => ServicesGrouping.feature;

  void set(ServicesGrouping grouping) => state = grouping;
}

final servicesGroupingProvider =
    NotifierProvider<ServicesGroupingNotifier, ServicesGrouping>(
      ServicesGroupingNotifier.new,
    );

/// Une ligne du tableau : un poste ou un processus, ventilé par moteur.
///
/// Les montants sont accumulés **en euros**, chaque mois converti à son propre
/// taux : additionner des dollars puis convertir au cours du jour donnerait un
/// total que personne n'a payé.
class _Line {
  final String label;
  double claudeEur = 0;
  int claudeCalls = 0;
  double geminiEur = 0;
  int geminiCalls = 0;
  double otherEur = 0;
  int otherCalls = 0;
  int tokens = 0;

  _Line(this.label);

  double get totalEur => claudeEur + geminiEur + otherEur;
  int get totalCalls => claudeCalls + geminiCalls + otherCalls;

  double get claudeUnit => claudeCalls > 0 ? claudeEur / claudeCalls : 0;
  double get geminiUnit => geminiCalls > 0 ? geminiEur / geminiCalls : 0;
  double get totalUnit => totalCalls > 0 ? totalEur / totalCalls : 0;
}

class AiServicesTab extends ConsumerWidget {
  const AiServicesTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reportAsync = ref.watch(monthlyCostsProvider);
    final grouping = ref.watch(servicesGroupingProvider);

    return reportAsync.render(
      loadingLabel: 'Lecture des coûts…',
      onRetry: () => ref.invalidate(monthlyCostsProvider),
      data: (report) {
        final lines = _aggregate(report, grouping);
        if (lines.isEmpty) {
          return const AppEmptyState(
            icon: Icons.calculate_outlined,
            title: 'Aucun appel comptabilisé',
            message:
                'Aucun appel d\'IA n\'a été enregistré sur la période choisie. '
                'Si l\'historique existe mais n\'apparaît pas, reconstruisez '
                'les agrégats depuis l\'onglet « Mois par mois ».',
          );
        }

        final totals = _Line('Total');
        for (final line in lines) {
          totals.claudeEur += line.claudeEur;
          totals.claudeCalls += line.claudeCalls;
          totals.geminiEur += line.geminiEur;
          totals.geminiCalls += line.geminiCalls;
          totals.otherEur += line.otherEur;
          totals.otherCalls += line.otherCalls;
          totals.tokens += line.tokens;
        }

        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _Intro(grouping: grouping, totals: totals),
            const SizedBox(height: 16),
            _CostsTable(lines: lines, totals: totals, grouping: grouping),
            const SizedBox(height: 16),
            _Footnote(hasOther: totals.otherCalls > 0),
          ],
        );
      },
    );
  }
}

/// Additionne les postes sur toute la période affichée.
List<_Line> _aggregate(MonthlyCostsReport report, ServicesGrouping grouping) {
  final lines = <String, _Line>{};

  for (final month in report.months) {
    final rate = rateFor(month, report);
    for (final feature in month.features) {
      final key = grouping == ServicesGrouping.process
          ? featureProcess(feature.feature)
          : feature.feature;
      final line = lines.putIfAbsent(
        key,
        () => _Line(
          grouping == ServicesGrouping.process ? key : featureLabel(key),
        ),
      );

      final claude = feature.provider('anthropic');
      final gemini = feature.provider('gemini');
      line.claudeEur += claude.costUsd * rate;
      line.claudeCalls += claude.calls;
      line.geminiEur += gemini.costUsd * rate;
      line.geminiCalls += gemini.calls;

      // Ce qui n'est ni Claude ni Gemini — scan de sécurité, traitements
      // internes — n'a pas de colonne mais compte dans le total : un poste
      // absent du total ferait mentir la somme.
      final otherEur = feature.costUsd * rate - claude.costUsd * rate -
          gemini.costUsd * rate;
      final otherCalls = feature.calls - claude.calls - gemini.calls;
      line.otherEur += otherEur;
      line.otherCalls += otherCalls > 0 ? otherCalls : 0;
      line.tokens += feature.inputTokens + feature.outputTokens;
    }
  }

  final sorted = lines.values.toList()
    ..sort((a, b) => b.totalEur.compareTo(a.totalEur));
  return sorted;
}

class _Intro extends ConsumerWidget {
  final ServicesGrouping grouping;
  final _Line totals;

  const _Intro({required this.grouping, required this.totals});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Coût des appels d\'IA',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              formatEur(totals.totalEur),
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${formatCount(totals.totalCalls)} appels · '
              'coût moyen ${formatEur(totals.totalUnit, forceDecimals: false)} '
              'par appel · ${formatCount(totals.tokens)} jetons · '
              '${formatEnergy(totals.tokens)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'La période affichée est celle choisie dans l\'onglet '
              '« Mois par mois ».',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<ServicesGrouping>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: ServicesGrouping.feature,
                  label: Text('Par poste'),
                ),
                ButtonSegment(
                  value: ServicesGrouping.process,
                  label: Text('Par processus'),
                ),
              ],
              selected: {grouping},
              onSelectionChanged: (values) =>
                  ref.read(servicesGroupingProvider.notifier).set(values.first),
            ),
          ],
        ),
      ),
    );
  }
}

class _CostsTable extends StatelessWidget {
  final List<_Line> lines;
  final _Line totals;
  final ServicesGrouping grouping;

  const _CostsTable({
    required this.lines,
    required this.totals,
    required this.grouping,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    DataColumn column(String title, {bool numeric = true}) => DataColumn(
      numeric: numeric,
      label: Text(title, style: theme.textTheme.labelMedium),
    );

    DataCell amount(String text, {bool bold = false, bool muted = false}) =>
        DataCell(
          Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: bold ? FontWeight.w600 : null,
              color: muted ? theme.colorScheme.onSurfaceVariant : null,
            ),
          ),
        );

    List<DataCell> cells(_Line line, {bool bold = false}) => [
      DataCell(
        Text(
          line.label,
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: bold ? FontWeight.w600 : null,
          ),
        ),
      ),
      amount(
        line.claudeCalls == 0 ? '—' : formatCount(line.claudeCalls),
        bold: bold,
        muted: line.claudeCalls == 0,
      ),
      amount(
        line.claudeCalls == 0 ? '—' : formatEur(line.claudeUnit),
        bold: bold,
        muted: line.claudeCalls == 0,
      ),
      amount(
        line.claudeCalls == 0 ? '—' : formatEur(line.claudeEur),
        bold: bold,
        muted: line.claudeCalls == 0,
      ),
      amount(
        line.geminiCalls == 0 ? '—' : formatCount(line.geminiCalls),
        bold: bold,
        muted: line.geminiCalls == 0,
      ),
      amount(
        line.geminiCalls == 0 ? '—' : formatEur(line.geminiUnit),
        bold: bold,
        muted: line.geminiCalls == 0,
      ),
      amount(
        line.geminiCalls == 0 ? '—' : formatEur(line.geminiEur),
        bold: bold,
        muted: line.geminiCalls == 0,
      ),
      amount(formatCount(line.totalCalls), bold: bold),
      amount(formatEur(line.totalUnit), bold: bold),
      amount(formatEur(line.totalEur), bold: true),
    ];

    return Card(
      margin: EdgeInsets.zero,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: 44,
          dataRowMinHeight: 40,
          dataRowMaxHeight: 52,
          columnSpacing: 20,
          columns: [
            column(
              grouping == ServicesGrouping.process ? 'Processus' : 'Poste',
              numeric: false,
            ),
            column('Claude\nappels'),
            column('Claude\n€ / appel'),
            column('Claude\ntotal'),
            column('Gemini\nappels'),
            column('Gemini\n€ / appel'),
            column('Gemini\ntotal'),
            column('Total\nappels'),
            column('Total\n€ / appel'),
            column('Total'),
          ],
          rows: [
            for (final line in lines) DataRow(cells: cells(line)),
            DataRow(
              color: WidgetStatePropertyAll(
                theme.colorScheme.surfaceContainerHighest,
              ),
              cells: cells(totals, bold: true),
            ),
          ],
        ),
      ),
    );
  }
}

class _Footnote extends StatelessWidget {
  final bool hasOther;

  const _Footnote({required this.hasOther});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      'Les montants sont convertis en euros au taux du mois concerné, celui '
      'que Google a appliqué à sa facture. Le coût d\'un appel est celui figé '
      'au moment où il a eu lieu : il n\'est jamais recalculé ici.'
      '${hasOther ? ' Les colonnes « Total » incluent les appels internes — '
                'scan de sécurité, traitements sans inférence — qui n\'ont ni '
                'colonne Claude ni colonne Gemini.' : ''}',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      ),
    );
  }
}
