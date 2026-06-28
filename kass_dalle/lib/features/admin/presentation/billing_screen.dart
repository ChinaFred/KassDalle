import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/domain/app_user.dart';
import '../data/billing_repository.dart';
import '../data/gcp_billing_repository.dart';
import 'admin_providers.dart';
import 'billing_providers.dart';
import 'billing_tab_widgets.dart';

// ��½"?��½"? ��½?cran principal ��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?��½"?

class BillingScreen extends ConsumerStatefulWidget {
  const BillingScreen({super.key});

  @override
  ConsumerState<BillingScreen> createState() => _BillingScreenState();
}

class _BillingScreenState extends ConsumerState<BillingScreen> {
  double? _geminiBilledEurFromGcp(GcpCostsReport report) {
    final geminiServices = report.services.where(
      (s) => s.service.toLowerCase().contains('gemini'),
    );
    if (geminiServices.isEmpty) return null;
    return geminiServices.fold<double>(0.0, (sum, s) => sum + s.costEur);
  }

  @override
  Widget build(BuildContext context) {
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
                builder: (ctx) => AlertDialog(
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
                      onPressed: () => Navigator.of(ctx).pop(),
                      child: const Text('OK'),
                    ),
                  ],
                ),
              ),
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
              padding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 4,
              ),
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

class _OperationBanner extends StatelessWidget {
  final bool isError;
  final String message;
  final VoidCallback onClose;

  const _OperationBanner({
    required this.isError,
    required this.message,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = isError
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.primaryContainer;
    final fg = isError
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onPrimaryContainer;
    return Material(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.check_circle_outline,
              color: fg,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                message,
                style: TextStyle(
                  color: fg,
                  fontFamily: isError ? 'monospace' : null,
                  fontSize: isError ? 12 : 14,
                ),
              ),
            ),
            IconButton(
              icon: Icon(Icons.close, color: fg),
              tooltip: 'Fermer',
              onPressed: onClose,
            ),
          ],
        ),
      ),
    );
  }
}
