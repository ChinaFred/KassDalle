import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/billing_repository.dart';
import '../data/gcp_billing_repository.dart';
import 'admin_providers.dart';
import 'billing_providers.dart';

class AdminBackfillsScreen extends ConsumerStatefulWidget {
  const AdminBackfillsScreen({super.key});

  @override
  ConsumerState<AdminBackfillsScreen> createState() =>
      _AdminBackfillsScreenState();
}

class _AdminBackfillsScreenState extends ConsumerState<AdminBackfillsScreen> {
  bool _busy = false;
  String _busyLabel = '';
  String? _resultMessage;
  String? _errorMessage;
  bool _resultIsError = false;

  Future<void> _runBackfill<T>({
    required String label,
    required String feature,
    required Future<T> Function() run,
    required String Function(T) format,
    Map<String, dynamic> context = const {},
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _busyLabel = label;
      _resultMessage = null;
      _errorMessage = null;
      _resultIsError = false;
    });
    try {
      final result = await run();
      if (!mounted) return;
      ref.invalidate(billingReportProvider);
      ref.invalidate(gcpCostsReportProvider);
      setState(() {
        _busy = false;
        _resultMessage = format(result);
        _resultIsError = false;
      });
    } catch (e, st) {
      try {
        await ref.read(errorReportServiceProvider).reportError(
          feature: feature,
          error: e,
          stackTrace: st,
          context: {
            'label': label,
            ...context,
          },
        );
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorMessage = '$e';
        _resultIsError = true;
      });
    }
  }

  Future<void> _runEnhanceBackfill() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reconstruire les donnees images'),
        content: const Text(
          'Cette operation scanne Firebase Storage pour retrouver '
          'toutes les ameliorations de photos passees et cree les '
          'entrees manquantes dans ai_usage.\n\n'
          'L\'operation est idempotente (sans doublons). '
          'Continuer ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Reconstruire'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _runBackfill<Map<String, int>>(
      label: 'Reconstruction des donnees images en cours...',
      feature: 'admin_backfill_enhance_usage',
      run: () => ref.read(gcpBillingRepositoryProvider).backfillEnhanceUsage(),
      format: (r) =>
          '${r['created']} entrees creees, ${r['skipped']} ignorees (${r['total']} images au total)',
    );
  }

  Future<void> _runLogBackfill(BillingPeriod period) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tracer les appels non attribues'),
        content: Text(
          'Cette operation scanne les logs Gemini de la periode selectionnee '
          'et cree les entrees ai_usage manquantes.\n\n'
          'Periode : ${period.label}\n\n'
          'Continuer ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Tracer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _runBackfill<Map<String, int>>(
      label: 'Tracage des appels non attribues en cours...',
      feature: 'admin_backfill_ai_usage_from_logs',
      run: () => ref.read(gcpBillingRepositoryProvider).backfillAiUsageFromLogs(
            start: period.start,
            end: period.end,
          ),
      format: (r) {
        final created = r['created'] ?? 0;
        final skipped = r['skipped'] ?? 0;
        final scanned = r['scanned'] ?? 0;
        final skippedAlreadyExists = r['skippedAlreadyExists'] ?? 0;
        final skippedMissingFeatureOrUsage =
            r['skippedMissingFeatureOrUsage'] ?? 0;
        final skippedNotGeminiSuccess = r['skippedNotGeminiSuccess'] ?? 0;

        return '$created entrees creees, $skipped ignorees ($scanned logs scannes)\n'
            'Details ignores: '
            'deja existants=$skippedAlreadyExists, '
            'feature/usage manquant=$skippedMissingFeatureOrUsage, '
            'hors succes Gemini=$skippedNotGeminiSuccess';
      },
      context: {
        'period_start': period.start.toIso8601String(),
        'period_end': period.end.toIso8601String(),
      },
    );
  }

  Future<void> _runShoppingBackfill() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backfill produits de courses'),
        content: const Text(
          'Cette operation calcule les champs shopping_products '
          'sur les recettes existantes (historique).\n\n'
          'Le traitement se fait par lot (50 recettes par lancement).\n\n'
          'Continuer ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Lancer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _runBackfill<Map<String, int>>(
      label: 'Backfill shopping_products en cours...',
      feature: 'admin_backfill_shopping_products',
      run: () => ref.read(gcpBillingRepositoryProvider).backfillShoppingProducts(),
      format: (r) =>
          '${r['updated']} mises a jour, ${r['skipped']} ignorees, ${r['failed']} erreurs '
          '(${r['scanned']} scannees) - ${r['remaining']} recette(s) restante(s)'
          '${(r['stoppedByDeadline'] ?? 0) == 1 ? ' - arret preventif (timeout evite), relancer pour continuer' : ''}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final period = ref.watch(billingPeriodProvider);
    final presets = BillingPeriod.buildPresets();

    return Scaffold(
      appBar: AppBar(title: const Text('Backfills')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_resultMessage != null || _errorMessage != null)
                _OperationBanner(
                  isError: _resultIsError,
                  message: _errorMessage ?? _resultMessage ?? '',
                  onClose: () => setState(() {
                    _resultMessage = null;
                    _errorMessage = null;
                  }),
                ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Backfills Comptabilite', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text(
                        'Ces operations reconstruisent des donnees historiques pour '
                        'ameliorer la coherence des couts et des statistiques.',
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonHideUnderline(
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
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _BackfillTile(
                icon: Icons.auto_fix_high_outlined,
                title: 'Reconstruire donnees images',
                subtitle:
                    'Regenerate ai_usage pour les ameliorations d\'images historiques.',
                onTap: _busy ? null : _runEnhanceBackfill,
              ),
              const SizedBox(height: 8),
              _BackfillTile(
                icon: Icons.playlist_add_check_circle_outlined,
                title: 'Tracer les appels non attribues',
                subtitle:
                    'Rejoue les logs Gemini de la periode selectionnee pour combler ai_usage.',
                onTap: _busy ? null : () => _runLogBackfill(period),
              ),
              const SizedBox(height: 8),
              _BackfillTile(
                icon: Icons.shopping_bag_outlined,
                title: 'Backfill produits de courses',
                subtitle:
                    'Calcule shopping_products sur les recettes existantes (batch de 50).',
                onTap: _busy ? null : _runShoppingBackfill,
              ),
            ],
          ),
          if (_busy)
            Positioned.fill(
              child: AbsorbPointer(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.45),
                  child: Center(
                    child: Card(
                      margin: const EdgeInsets.all(24),
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const CircularProgressIndicator(),
                            const SizedBox(height: 16),
                            Text(
                              _busyLabel,
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodyLarge,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _BackfillTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const _BackfillTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.play_arrow_outlined),
        onTap: onTap,
      ),
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
        : theme.colorScheme.secondaryContainer;
    final fg = isError
        ? theme.colorScheme.onErrorContainer
        : theme.colorScheme.onSecondaryContainer;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                isError ? Icons.error_outline : Icons.check_circle_outline,
                color: fg,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                ),
              ),
              IconButton(
                tooltip: 'Fermer',
                onPressed: onClose,
                icon: Icon(Icons.close, color: fg, size: 18),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
