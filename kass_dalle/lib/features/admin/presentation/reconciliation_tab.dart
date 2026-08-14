import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/error_reporting.dart';
import '../../../core/utils/context_extensions.dart';
import '../data/ai_reconciliation_repository.dart';
import '../data/currency_rate_repository.dart';
import '../domain/ai_reconciliation_report.dart';
import 'billing_providers.dart';
import 'costs_format.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/widgets/error_message.dart';

/// Onglet « Réconciliation » de l'écran Comptabilité.
///
/// Répond à une question qu'on ne se pose pas spontanément : *est-ce que mon
/// suivi de coûts dit la vérité ?* Une erreur de tarification ne produit pas
/// d'erreur, elle produit un chiffre plausible — seule la confrontation à la
/// facture Google la révèle.
///
/// Le rapport est produit automatiquement le 4 de chaque mois pour le mois
/// écoulé (`scheduledAiReconciliation`). Le bouton sert à regarder tout de
/// suite, ou à rejouer une période après correction.
class ReconciliationTab extends ConsumerStatefulWidget {
  const ReconciliationTab({super.key});

  @override
  ConsumerState<ReconciliationTab> createState() => _ReconciliationTabState();
}

class _ReconciliationTabState extends ConsumerState<ReconciliationTab> {
  bool _running = false;

  /// Douze derniers mois, du plus récent au plus ancien, en excluant le mois
  /// en cours : sa facturation n'est pas consolidée et l'écart ne dirait rien.
  List<String> _selectablePeriods() {
    final now = DateTime.now().toUtc();
    return List.generate(12, (i) {
      return AiReconciliationRepository.periodId(
        DateTime.utc(now.year, now.month - 1 - i, 1),
      );
    });
  }

  /// Dit quel taux convertit les montants de l'écran, et d'où il sort. Un taux
  /// de repli annoncé comme tel se corrige ; un taux périmé qui se tait, non.
  String _rateLabel(CurrencyRate rate) {
    final value = formatRate(rate.usdToEur);
    if (rate.isFallback) {
      return 'Taux de conversion : valeur de repli (1 \$ = $value €). Aucune '
          'réconciliation n\'a encore relevé le taux réel — lancez-en une.';
    }
    final origin = rate.sourcePeriod == null
        ? 'la facturation'
        : 'la facturation de ${rate.sourcePeriod}';
    return 'Taux de conversion : 1 \$ = $value €, relevé sur $origin.';
  }

  Future<void> _generate(String period) async {
    setState(() => _running = true);
    try {
      await ref
          .read(gcpBillingRepositoryProvider)
          .generateAiReconciliation(period: period);
      ref.invalidate(recentReconciliationsProvider);
      // Le calcul vient aussi de relever le taux de change : sans cette
      // invalidation, l'écran continuerait de convertir avec l'ancien.
      ref.invalidate(currencyRateProvider);
      if (mounted) {
        context.showSuccessSnackBar('Rapport $period recalculé.');
      }
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'admin.generateAiReconciliation',
        error: error,
        stackTrace: stackTrace,
        context: {'period': period},
      );
      if (mounted) {
        context.showErrorSnackBar('Échec du calcul : $error');
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final period = ref.watch(reconciliationPeriodProvider);
    final reportAsync = ref.watch(aiReconciliationProvider(period));
    final periods = _selectablePeriods();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.fact_check_outlined,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Contrôle mensuel de la part Gemini',
                        style: theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                // Dire le périmètre plutôt que de laisser le lecteur le
                // déduire d'une absence : cet écran ne compare que ce que
                // Google facture. Claude est facturé par Anthropic, et
                // l'infrastructure n'est imputable à aucun poste — les deux
                // vivent dans l'onglet « Mois par mois ».
                Text(
                  'Ce contrôle porte sur la seule part que Google facture : '
                  'les appels Gemini. Claude, facturé par Anthropic, et '
                  'l\'infrastructure se lisent dans l\'onglet « Mois par mois », '
                  'qui les confronte eux aussi à leur facture.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                Text(
                  'Le rapport est calculé automatiquement le 4 de chaque mois '
                  'pour le mois écoulé. Relancez-le ici pour regarder tout de '
                  'suite, ou pour rejouer une période.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                // Le même calcul relève le taux de change : l'afficher ici, et
                // non dans un coin de réglages, c'est dire d'où il vient.
                ref
                    .watch(currencyRateProvider)
                    .when(
                      loading: () => const SizedBox.shrink(),
                      error: (e, _) => Text(
                        'Taux de change indisponible — ${shortErrorMessage(e)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                      data: (rate) => Text(
                        _rateLabel(rate),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: rate.isFallback
                              ? theme.colorScheme.error
                              : theme.colorScheme.outline,
                        ),
                      ),
                    ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Mois',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        child: DropdownButtonHideUnderline(
                          // `value` et non `initialValue` : le champ doit
                          // refléter l'état courant à chaque reconstruction,
                          // pas seulement celui de sa première.
                          child: DropdownButton<String>(
                            value: periods.contains(period)
                                ? period
                                : periods.first,
                            isDense: true,
                            isExpanded: true,
                            items: periods
                                .map(
                                  (p) => DropdownMenuItem(
                                    value: p,
                                    child: Text(p),
                                  ),
                                )
                                .toList(),
                            onChanged: _running
                                ? null
                                : (value) {
                                    if (value == null) return;
                                    ref
                                        .read(
                                          reconciliationPeriodProvider.notifier,
                                        )
                                        .set(value);
                                  },
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: _running ? null : () => _generate(period),
                      icon: _running
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.play_arrow),
                      label: Text(_running ? 'Calcul…' : 'Recalculer'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        reportAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 32),
            child: AppLoadingState(),
          ),
          error: (e, _) => AppErrorState(
            error: e,
            title: 'Lecture impossible',
            onRetry: () => ref.invalidate(aiReconciliationProvider(period)),
          ),
          data: (report) => report == null
              ? _Message(
                  icon: Icons.hourglass_empty_outlined,
                  color: theme.colorScheme.outline,
                  title: 'Aucun rapport pour $period',
                  body:
                      'La tâche planifiée ne l\'a pas encore produit, ou la '
                      'période est antérieure à sa mise en place. '
                      'Utilisez « Recalculer » pour le générer.',
                )
              : _ReportView(
                  report: report,
                  // Le taux relevé par la réconciliation elle-même : les
                  // montants de cet onglet sont convertis avec celui-là, pas
                  // avec un cours du jour sans rapport avec la période.
                  usdToEur: ref.watch(currencyRateProvider).value?.usdToEur ?? 0,
                ),
        ),
      ],
    );
  }
}

// ── Affichage d'un rapport ────────────────────────────────────────────────────

class _ReportView extends StatelessWidget {
  final AiReconciliationReport report;
  final double usdToEur;

  const _ReportView({required this.report, required this.usdToEur});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final features = report.byFeature.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (report.billingQueryFailed)
          _Message(
            icon: Icons.report_problem_outlined,
            color: Colors.orange,
            title: 'Facturation Google illisible',
            body:
                'L\'export BigQuery n\'a pas pu être interrogé pour cette '
                'période. Le montant facturé affiché ci-dessous ne veut rien '
                'dire, et l\'écart non plus.',
          ),
        if (report.billingQueryFailed) const SizedBox(height: 12),

        // Un rapport d'avant la prise en compte de la devise affiche un montant
        // facturé en euros sous un signe dollar : son écart n'est pas une
        // grandeur, c'est une soustraction entre deux monnaies.
        if (report.currencyUnknown) ...[
          _Message(
            icon: Icons.currency_exchange_outlined,
            color: Colors.orange,
            title: 'Rapport à recalculer',
            body:
                'Ce rapport date d\'avant la prise en compte de la devise de '
                'facturation. Son montant « facturé » est libellé dans la '
                'devise du compte (euros) alors qu\'il s\'affiche en dollars : '
                'l\'écart n\'est donc pas exploitable. Relancez « Recalculer ».',
          ),
          const SizedBox(height: 12),
        ],

        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _AmountRow(
                  label: 'Estimé par le suivi interne',
                  help: 'Somme des coûts calculés appel par appel (ai_usage)',
                  value: report.estimatedTraceableUsd,
                  usdToEur: usdToEur,
                ),
                const Divider(height: 20),
                _AmountRow(
                  label: 'Facturé par Google',
                  help: _billedHelp(report),
                  value: report.billedIaUsd,
                  usdToEur: usdToEur,
                  muted: report.billingQueryFailed,
                ),
                const Divider(height: 20),
                _AmountRow(
                  label: 'Écart',
                  help: report.deltaUsd >= 0
                      ? 'Facturé au-delà de ce que le suivi explique'
                      : 'Le suivi surestime : il compte plus que la facture',
                  value: report.deltaUsd,
                  usdToEur: usdToEur,
                  emphasize: true,
                  muted: report.billingQueryFailed,
                ),
              ],
            ),
          ),
        ),

        if (report.hasAnomaly) ...[
          const SizedBox(height: 12),
          Card(
            color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.warning_amber_outlined,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Text('Anomalies', style: theme.textTheme.titleSmall),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ...report.anomalies.map(
                    (a) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('• $a', style: theme.textTheme.bodySmall),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],

        if (features.isNotEmpty) ...[
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Estimé par fonctionnalité',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  ...features.map(
                    (e) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              e.key,
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                          Text(
                            formatMoney(e.value, usdToEur),
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],

        const SizedBox(height: 12),
        Text(
          _provenance(report),
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }

  /// Rappelle le montant de la facture dans sa devise d'origine : c'est celui
  /// qu'on retrouve dans le Tableau des coûts de la console Google, et sans lui
  /// le rapprochement est impossible à faire de tête.
  String _billedHelp(AiReconciliationReport report) {
    const base = 'Export de facturation GCP, services Gemini / Vertex AI';
    final currency = report.billingCurrency;
    if (currency == null || currency == 'USD') return base;
    final native = formatEur(report.billedIaNative);
    return '$base — facture : $native, convertie au taux de l\'export '
        '($currency)';
  }

  String _provenance(AiReconciliationReport report) {
    final source = report.generatedSource == 'scheduler'
        ? 'calcul automatique mensuel'
        : 'relance manuelle';
    final at = report.generatedAt;
    if (at == null) return 'Origine : $source.';
    final d = at.toLocal();
    final date =
        '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    final time =
        '${d.hour.toString().padLeft(2, '0')}h${d.minute.toString().padLeft(2, '0')}';
    return 'Origine : $source, le $date à $time.';
  }
}

class _AmountRow extends StatelessWidget {
  final String label;
  final String help;
  final double value;
  final double usdToEur;
  final bool emphasize;
  final bool muted;

  const _AmountRow({
    required this.label,
    required this.help,
    required this.value,
    required this.usdToEur,
    this.emphasize = false,
    this.muted = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = muted
        ? theme.colorScheme.outline
        : (emphasize
              ? (value.abs() < 0.005
                    ? Colors.green
                    : (value > 0 ? theme.colorScheme.error : Colors.orange))
              : null);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: theme.textTheme.bodyMedium),
              Text(
                help,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Text(
          muted ? '—' : formatMoney(value, usdToEur),
          style:
              (emphasize
                      ? theme.textTheme.titleMedium
                      : theme.textTheme.titleSmall)
                  ?.copyWith(color: color),
        ),
      ],
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String body;

  const _Message({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text(body, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
