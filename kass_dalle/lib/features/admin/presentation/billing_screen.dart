import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/domain/app_user.dart';
import '../data/billing_repository.dart';
import '../data/gcp_billing_repository.dart';
import 'admin_providers.dart';
import 'billing_providers.dart';
import 'billing_tab_widgets.dart';
import '../../../core/utils/context_extensions.dart';


// ï¿½"?ï¿½"? ï¿½?cran principal ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?ï¿½"?

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
              tooltip: 'Comprendre les coÃ»ts',
              icon: const Icon(Icons.info_outline),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => AlertDialog(
                  title: const Text('GCP facturÃ© vs Gemini estimÃ©'),
                  content: const SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _InfoSection(
                          icon: Icons.cloud_outlined,
                          title: 'GCP facturÃ©',
                          body:
                              'Facture rÃ©elle Google Cloud Platform : Firestore, '
                              'Storage, Cloud Functions, Firebase Hosting et '
                              "l'API Gemini. C'est le montant prÃ©levÃ© sur ta carte.",
                        ),
                        SizedBox(height: 12),
                        _InfoSection(
                          icon: Icons.auto_awesome_outlined,
                          title: 'Gemini estimÃ©',
                          body:
                              "Estimation calculÃ©e depuis les logs d'usage IA "
                              '(collection ai_usage). Deux composantes :\n\n'
                              'â€¢ Appels texte : tokens Ã— tarif officiel\n'
                              'â€¢ AmÃ©liorations photos : 0,04 \$ par image\n\n'
                              'Permet la ventilation par utilisateur et feature.',
                        ),
                        SizedBox(height: 12),
                        _InfoSection(
                          icon: Icons.lightbulb_outline,
                          title: 'Relation entre les deux',
                          body:
                              'Le coÃ»t Gemini estimÃ© est inclus dans le total GCP '
                              '(ne pas additionner). '
                              "Un Ã©cart rÃ©siduel peut subsister si des appels n'ont "
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
              tooltip: 'Reconstruire donnÃ©es images',
              icon: const Icon(Icons.auto_fix_high_outlined),
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Reconstruire les donnÃ©es images'),
                    content: const Text(
                      'Cette opÃ©ration scanne Firebase Storage pour retrouver '
                      'toutes les amÃ©liorations de photos passÃ©es et crÃ©e les '
                      'entrÃ©es manquantes dans ai_usage.\n\n'
                      'L\'opÃ©ration est idempotente (sans doublons). '
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
                final repo = ref.read(gcpBillingRepositoryProvider);
                try {
                  final result = await repo.backfillEnhanceUsage();
                  if (!context.mounted) return;
                  context.showSuccessSnackBar(
                    '${result['created']} entrées créées, '
                    '${result['skipped']} ignorées '
                    '(${result['total']} images au total)',
                  );
                  ref.invalidate(billingReportProvider);
                } catch (e) {
                  if (!context.mounted) return;
                  context.showErrorSnackBar('Erreur : $e');
                }
              },
            ),
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
            // BanniÃ¨re stats (style identique Ã  TokenUsageScreen)
            _BillingBanner(reportAsync: reportAsync, gcpAsync: gcpAsync),
            // SÃ©lecteur de pÃ©riode (filtre lÃ©ger, mÃªme style que FiltersRow)
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
                    data: (report) =>
                        BillingGeminiTab(report: report, userLabel: userLabel),
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
              Text(
                title,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 2),
              Text(body, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ],
    );
  }
}

// â”€â”€ BanniÃ¨re rÃ©capitulative â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

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
      data: (gcp) => gcp.hasData ? billingFmtEur(gcp.totalEur) : '\u2014',
    ) ?? '\u2014';

    final geminiEur = reportAsync.whenOrNull(
      data: (r) => billingFmtEur(r.totals.costEur),
    ) ?? '\u2014';

    final calls = reportAsync.whenOrNull(
      data: (r) => billingFmtInt(r.totals.callCount),
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

