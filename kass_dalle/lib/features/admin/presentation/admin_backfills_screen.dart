import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'admin_providers.dart';
import 'billing_providers.dart';

/// Écran d'administration : backfill unique d'enrichissement des référentiels.
///
/// Estime par IA les poids d'unités manquants et les valeurs nutritionnelles
/// (per100g) des ingrédients manquants. Idempotent, avec reprise sur checkpoint.
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

  Future<T?> _runBackfill<T>({
    required String label,
    required String feature,
    required Future<T> Function() run,
    required String Function(T) format,
    Map<String, dynamic> context = const {},
  }) async {
    if (_busy) return null;
    setState(() {
      _busy = true;
      _busyLabel = label;
      _resultMessage = null;
      _errorMessage = null;
      _resultIsError = false;
    });
    try {
      final result = await run();
      if (!mounted) return null;
      ref.invalidate(referentialKpisProvider);
      setState(() {
        _busy = false;
        _resultMessage = format(result);
        _resultIsError = false;
      });
      return result;
    } catch (e, st) {
      try {
        await ref
            .read(errorReportServiceProvider)
            .reportError(
              feature: feature,
              error: e,
              stackTrace: st,
              context: {'label': label, ...context},
            );
      } catch (_) {}
      if (!mounted) return null;
      setState(() {
        _busy = false;
        _errorMessage = '$e';
        _resultIsError = true;
      });
      return null;
    }
  }

  Future<void> _runBackfillEnrichReferentials() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Enrichir les référentiels'),
        content: const Text(
          'Cette opération estime par IA :\n'
          '• le poids des unités sans conversion (poignée, brin, petit…) ;\n'
          '• les valeurs nutritionnelles (per100g) des ingrédients manquants.\n\n'
          'Le traitement est idempotent et reprend depuis le checkpoint serveur. '
          'Relancez si le résultat indique « incomplet ». Continuer ?',
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
      label: 'Enrichissement des référentiels en cours...',
      feature: 'admin_backfill_enrich_referentials',
      run: () =>
          ref.read(gcpBillingRepositoryProvider).backfillEnrichReferentials(),
      format: (r) =>
          'Unités: scannées=${r['scannedUnits']}, enrichies=${r['enrichedUnits']}, '
          'restantes=${r['remainingUnitsWithoutWeight']} | '
          'Ingrédients: scannés=${r['scannedIngredients']}, '
          'enrichis=${r['enrichedIngredients']}, échecs=${r['failedIngredients']}'
          '${(r['completed'] ?? 0) == 1 ? ' — terminé' : ' — incomplet'}'
          '${(r['stoppedByDeadline'] ?? 0) == 1 ? ' (arrêt préventif, relancer pour continuer)' : ''}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

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
                      Text(
                        'Enrichissement des référentiels',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Complète automatiquement, via IA, les données manquantes '
                        'des référentiels : poids des unités et valeurs '
                        'nutritionnelles (per100g) des ingrédients.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _BackfillTile(
                icon: Icons.auto_fix_high_outlined,
                title: 'Enrichir unités + ingrédients',
                subtitle:
                    'Estime les poids d\'unités manquants et les per100g des '
                    'ingrédients. Idempotent, reprise sur checkpoint.',
                onTap: _busy ? null : _runBackfillEnrichReferentials,
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
  final bool danger;

  const _BackfillTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? Theme.of(context).colorScheme.error : null;
    return Card(
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(
          title,
          style: color != null ? TextStyle(color: color) : null,
        ),
        subtitle: Text(subtitle),
        trailing: Icon(Icons.play_arrow_outlined, color: color),
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
