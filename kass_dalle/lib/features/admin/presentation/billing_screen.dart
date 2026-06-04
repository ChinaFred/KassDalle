import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/domain/app_user.dart';
import '../data/billing_repository.dart';
import '../data/gcp_billing_repository.dart';
import 'admin_providers.dart';
import 'billing_providers.dart';
import 'billing_tab_widgets.dart';

// ��½"?��½"? ��½?cran principal ��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?

class BillingScreen extends ConsumerWidget {
  const BillingScreen({super.key});

  double? _geminiBilledEurFromGcp(GcpCostsReport report) {
    final geminiServices = report.services.where(
      (s) => s.service.toLowerCase().contains('gemini'),
    );
    if (geminiServices.isEmpty) return null;
    return geminiServices.fold<double>(0.0, (sum, s) => sum + s.costEur);
  }

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
    final geminiBilledEur = gcpAsync.whenOrNull(data: _geminiBilledEurFromGcp);

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
              tooltip: 'Comprendre les coûts',
              icon: const Icon(Icons.info_outline),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('GCP facturé vs Gemini estimé'),
                  content: const SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _InfoSection(
                          icon: Icons.cloud_outlined,
                          title: 'GCP facturé',
                          body:
                              'Facture réelle Google Cloud Platform : Firestore, '
                              'Storage, Cloud Functions, Firebase Hosting et '
                              "l'API Gemini. C'est le montant prélevé sur ta carte.",
                        ),
                        SizedBox(height: 12),
                        _InfoSection(
                          icon: Icons.auto_awesome_outlined,
                          title: 'Gemini estimé',
                          body:
                              "Estimation calculée depuis les logs d'usage IA "
                              '(collection ai_usage). Deux composantes :\n\n'
                              '• Appels texte : tokens × tarif officiel\n'
                              '• Améliorations photos : 0,04 \$ par image\n\n'
                              'Permet la ventilation par utilisateur et feature.',
                        ),
                        SizedBox(height: 12),
                        _InfoSection(
                          icon: Icons.lightbulb_outline,
                          title: 'Relation entre les deux',
                          body:
                              'Le coût Gemini estimé est inclus dans le total GCP '
                              '(ne pas additionner). '
                              "Un écart résiduel peut subsister si des appels n'ont "
                              "pas encore de log (ex : anciens appels avant le "
                              'suivi) ou en cas de variation du taux de change.',
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              tooltip: 'Reconstruire données images',
              icon: const Icon(Icons.auto_fix_high_outlined),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Reconstruire les données images'),
                    content: const Text(
                      'Cette opération scanne Firebase Storage pour retrouver '
                      'toutes les améliorations de photos passées et crée les '
                      'entrées manquantes dans ai_usage.\n\n'
                      'L\'opération est idempotente (sans doublons). '
                      'Continuer ?',
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
                if (!context.mounted) return;
                await _runBackfillWithDialog<Map<String, int>>(
                  context: context,
                  ref: ref,
                  title: 'Reconstruction des données images',
                  run: () => ref
                      .read(gcpBillingRepositoryProvider)
                      .backfillEnhanceUsage(),
                  successFormatter: (r) =>
                      '${r['created']} entrées créées, '
                      '${r['skipped']} ignorées '
                      '(${r['total']} images au total)',
                );
              },
            ),
            IconButton(
              tooltip: 'Tracer les appels non attribués',
              icon: const Icon(Icons.playlist_add_check_circle_outlined),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Tracer les appels non attribués'),
                    content: Text(
                      'Cette opération scanne les logs Gemini de la période '
                      'sélectionnée et crée les entrées ai_usage manquantes.\n\n'
                      'Période : ${period.label}\n\n'
                      'Continuer ?',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Annuler'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        child: const Text('Tracer'),
                      ),
                    ],
                  ),
                );
                if (confirmed != true) return;
                if (!context.mounted) return;
                await _runBackfillWithDialog<Map<String, int>>(
                  context: context,
                  ref: ref,
                  title: 'Traçage des appels non attribués',
                  run: () => ref
                      .read(gcpBillingRepositoryProvider)
                      .backfillAiUsageFromLogs(
                        start: period.start,
                        end: period.end,
                      ),
                  successFormatter: (r) =>
                      '${r['created']} entrées créées, '
                      '${r['skipped']} ignorées '
                      '(${r['scanned']} logs scannés)',
                );
              },
            ),
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
                        (p) =>
                            DropdownMenuItem(value: p.id, child: Text(p.label)),
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
                  BillingGcpTab(gcpAsync: gcpAsync),
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
                    data: (report) => BillingGeminiTab(
                      report: report,
                      userLabel: userLabel,
                      billedGeminiEur: geminiBilledEur,
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

// â”€â”€ Widget aide contextuelle â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _InfoSection extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _InfoSection({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(body, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

// â”€â”€ Bannière récapitulative â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _BillingBanner extends StatelessWidget {
  final AsyncValue<BillingReport> reportAsync;
  final AsyncValue<GcpCostsReport> gcpAsync;

  const _BillingBanner({required this.reportAsync, required this.gcpAsync});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final gcpGeminiEur = gcpAsync.whenOrNull(
      data: (gcp) {
        final geminiServices = gcp.services.where(
          (s) => s.service.toLowerCase().contains('gemini'),
        );
        if (geminiServices.isEmpty) return null;
        return geminiServices.fold<double>(0.0, (sum, s) => sum + s.costEur);
      },
    );

    final gcpEur =
        gcpAsync.whenOrNull(
          data: (gcp) => gcp.hasData ? billingFmtEur(gcp.totalEur) : '\u2014',
        ) ??
        '\u2014';

    final geminiEstimatedEur = reportAsync.whenOrNull(
      data: (r) => r.totals.costEur,
    );
    final geminiReconciledEur = gcpGeminiEur ?? geminiEstimatedEur;
    final geminiEur = geminiReconciledEur == null
        ? '\u2014'
        : billingFmtEur(geminiReconciledEur);

    final calls =
        reportAsync.whenOrNull(
          data: (r) => billingFmtInt(r.totals.callCount),
        ) ??
        '\u2014';

    final isLoading = reportAsync is AsyncLoading || gcpAsync is AsyncLoading;

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
            Icon(icon, size: 16, color: theme.colorScheme.onSecondaryContainer),
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


// ── Helper backfill : dialogue de progression + dialogue de résultat ─────────
Future<void> _runBackfillWithDialog<T>({
  required BuildContext context,
  required WidgetRef ref,
  required String title,
  required Future<T> Function() run,
  required String Function(T result) successFormatter,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  // 1. Affiche un dialogue de progression non dismissible.
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(title),
        content: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            SizedBox(width: 16),
            Expanded(child: Text('Opération en cours…')),
          ],
        ),
      ),
    ),
  );

  Object? error;
  StackTrace? stack;
  T? result;
  try {
    result = await run();
  } catch (e, st) {
    error = e;
    stack = st;
  }

  // 2. Ferme le dialogue de progression.
  if (navigator.canPop()) navigator.pop();

  // 3. Invalide les providers et affiche le résultat.
  if (error == null) {
    ref.invalidate(billingReportProvider);
    ref.invalidate(gcpCostsReportProvider);
  }

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(error == null ? 'Terminé' : 'Erreur'),
      content: SingleChildScrollView(
        child: SelectableText(
          error == null
              ? successFormatter(result as T)
              : 'Détail technique :\n\n$error'
                    '${stack != null ? '\n\n$stack' : ''}',
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
