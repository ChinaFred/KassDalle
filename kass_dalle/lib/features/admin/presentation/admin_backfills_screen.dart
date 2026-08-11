import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/gcp_billing_repository.dart';
import 'admin_providers.dart';
import 'billing_providers.dart';
import '../../../core/services/error_reporting.dart';

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
      } catch (error, stackTrace) {
        reportUnexpectedError(
          feature: 'adminBackfillsScreen.runBackfill',
          error: error,
          stackTrace: stackTrace,
        );
      }
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

  /// Amorce les custom claims des comptes existants.
  ///
  /// Tant que ce parcours n'a pas eu lieu, les règles Storage faillent ouvert :
  /// elles ne peuvent bloquer personne, faute de claim à lire.
  Future<void> _runBackfillUserClaims() async {
    await _runBackfill<Map<String, int>>(
      label: 'Amorçage des droits utilisateurs...',
      feature: 'admin_backfill_user_claims',
      run: () => ref.read(gcpBillingRepositoryProvider).backfillUserClaims(),
      format: (r) =>
          '${r['updated']} compte(s) amorcé(s) sur ${r['scanned']} scanné(s)'
          '${(r['failed'] ?? 0) > 0 ? ', ${r['failed']} en échec (voir les logs)' : ''}. '
          'Les droits deviennent effectifs au renouvellement du jeton.',
    );
  }

  /// Verse la table d'amorçage des poids à la pièce dans le référentiel.
  ///
  /// Sans confirmation : l'opération est non destructive et idempotente — un
  /// poids déjà connu, estimé par l'IA ou corrigé à la main, n'est pas touché.
  Future<void> _runSeedIngredientPieceWeights() async {
    await _runBackfill<Map<String, int>>(
      label: 'Amorçage des poids à la pièce...',
      feature: 'admin_seed_ingredient_piece_weights',
      run: () =>
          ref.read(gcpBillingRepositoryProvider).seedIngredientPieceWeights(),
      format: (r) =>
          '${r['created']} poids versé(s) sur ${r['candidates']} candidat(s), '
          '${r['skipped']} laissé(s) intact(s) car déjà renseigné(s).',
    );
  }

  /// Audite les identifiants du référentiel d'ingrédients, puis propose la
  /// réparation. L'audit est systématique et sans effet de bord : on ne
  /// fusionne jamais de documents sans avoir montré lesquels et pourquoi.
  Future<void> _runIngredientReferentialAudit() async {
    final report = await _runBackfill<IngredientCleanupReport>(
      label: 'Audit des identifiants d\'ingrédients...',
      feature: 'admin_ingredient_referential_audit',
      run: () => ref
          .read(gcpBillingRepositoryProvider)
          .cleanupIngredientReferential(apply: false),
      format: (r) => r.misnormalized.isEmpty
          ? 'Référentiel sain : ${r.scanned} ingrédient(s) scanné(s), aucun identifiant à corriger.'
          : '${r.misnormalized.length} identifiant(s) à corriger sur ${r.scanned} scanné(s).',
    );
    if (report == null || report.misnormalized.isEmpty || !mounted) return;

    final withValues = report.misnormalized.where((m) => m.hasPer100g).length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Réparer les identifiants ?'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${report.misnormalized.length} document(s) portent un identifiant '
                'que la règle de normalisation actuelle ne produit plus : ils sont '
                'inatteignables.'
                '${withValues > 0 ? ' $withValues d\'entre eux contiennent des valeurs nutritionnelles.' : ''}',
              ),
              const SizedBox(height: 12),
              const Text(
                'La réparation fusionne chaque document vers son identifiant '
                'attendu. Les valeurs d\'un document cible existant ne sont '
                'jamais écrasées — elles font foi.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: SelectableText(
                    report.misnormalized
                        .take(40)
                        .map(
                          (m) =>
                              '${m.currentId}  →  ${m.expectedId}'
                              '${m.targetExists ? '  (fusion)' : '  (renommage)'}'
                              '${m.hasPer100g ? '  [per100g]' : ''}',
                        )
                        .join('\n'),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
              if (report.misnormalized.length > 40)
                Text(
                  '… et ${report.misnormalized.length - 40} autre(s).',
                  style: const TextStyle(fontSize: 11),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Réparer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _runBackfill<IngredientCleanupReport>(
      label: 'Réparation des identifiants...',
      feature: 'admin_ingredient_referential_cleanup',
      run: () => ref
          .read(gcpBillingRepositoryProvider)
          .cleanupIngredientReferential(apply: true),
      format: (r) =>
          '${r.deleted} document(s) corrigé(s) : ${r.renamed} renommé(s), '
          '${r.merged} fusionné(s).',
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
              const SizedBox(height: 12),
              _BackfillTile(
                icon: Icons.verified_user_outlined,
                title: 'Amorcer les droits utilisateurs',
                subtitle:
                    'Inscrit le rôle et la révocation dans le jeton de chaque '
                    'compte. Nécessaire pour que les règles de stockage puissent '
                    'les appliquer. Idempotent.',
                onTap: _busy ? null : _runBackfillUserClaims,
              ),
              const SizedBox(height: 12),
              _BackfillTile(
                icon: Icons.egg_outlined,
                title: 'Amorcer les poids à la pièce',
                subtitle:
                    'Verse la table intégrée (œuf, jaune, oignon, citron…) dans '
                    'le référentiel, pour que celui-ci prenne le relais. '
                    'Les poids déjà connus ne sont pas touchés.',
                onTap: _busy ? null : _runSeedIngredientPieceWeights,
              ),
              const SizedBox(height: 12),
              _BackfillTile(
                icon: Icons.cleaning_services_outlined,
                title: 'Auditer les identifiants d\'ingrédients',
                subtitle:
                    'Repère les documents devenus inatteignables parce que la '
                    'règle de normalisation a changé. Constate d\'abord, ne '
                    'répare qu\'après confirmation.',
                onTap: _busy ? null : _runIngredientReferentialAudit,
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
