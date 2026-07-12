import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
      ref.invalidate(billingReportProvider);
      ref.invalidate(gcpCostsReportProvider);
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

  Future<void> _runNutritionGlobalRebuild() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rebuild nutrition complet'),
        content: const Text(
          'Cette operation execute en une seule action:\n'
          '1) normalisation du referentiel nutrition_ingredients,\n'
          '2) enrichissement des per100g manquants,\n'
          '3) recalcul de toutes les recettes.\n\n'
          'Le traitement est internalise par batches cote serveur (aucun batch utilisateur). Continuer ?',
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
      label: 'Rebuild nutrition global en cours...',
      feature: 'admin_rebuild_all_nutrition',
      run: () => ref.read(gcpBillingRepositoryProvider).rebuildAllNutrition(),
      format: (r) =>
          'Referentiel: normalises=${r['normalizedDocs']}, fusionnes=${r['mergedDocs']}, '
          'enrichis=${r['enrichedDocs']}, erreurs_enrichissement=${r['enrichmentFailed']} | '
          'Recettes: recalculees=${r['recomputedRecipes']}, erreurs_recalcul=${r['recomputeFailed']} | '
          'Restants: ingredients_sans_per100g=${r['remainingIngredientsWithoutPer100g']}, '
          'recettes_sans_nutrition=${r['remainingRecipesWithoutNutrition']}'
          '${(r['completed'] ?? 0) == 1 ? ' - termine' : ' - incomplet'}'
          '${(r['stoppedByDeadline'] ?? 0) == 1 ? ' - arret preventif (timeout evite), relancer pour continuer' : ''}',
    );
  }

  Future<void> _runNutritionUnitsBackfill() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backfill unites nutrition'),
        content: const Text(
          'Cette operation inventorie les unites observees dans les recettes '
          'et alimente le referentiel nutrition_units.\n\n'
          'Le traitement reprend depuis le checkpoint serveur (idempotent). '
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
      label: 'Backfill unites nutrition en cours...',
      feature: 'admin_backfill_nutrition_units_from_recipes',
      run: () => ref
          .read(gcpBillingRepositoryProvider)
          .backfillNutritionUnitsFromRecipes(),
      format: (r) =>
          'Recettes scannees=${r['scannedRecipes']}, unites scannees=${r['scannedUnits']} | '
          'creees (connues)=${r['createdKnown']}, creees (inconnues)=${r['createdUnknown']} | '
          'maj existantes=${r['updatedExisting']}, unites piece inferees=${r['inferredPieceUnits'] ?? 0} | '
          'ignorees invalides=${r['skippedInvalid']}, erreurs=${r['failed']}'
          '${(r['stoppedByDeadline'] ?? 0) == 1 ? ' - arret preventif (timeout evite), relancer pour continuer' : ''}',
    );
  }

  Future<void> _runBackfillNutritionUnitsLabel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backfill label unites nutrition'),
        content: const Text(
          'Remplit le champ "label" manquant dans nutrition_units '
          'en utilisant le premier alias disponible.\n\n'
          'Seuls les documents sans label sont touches. '
          'Idempotent. Continuer ?',
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
      label: 'Backfill label unites en cours...',
      feature: 'admin_backfill_nutrition_units_label',
      run: () =>
          ref.read(gcpBillingRepositoryProvider).backfillNutritionUnitsLabel(),
      format: (r) =>
          '${r['scanned']} scannes: '
          '${r['updated']} mis a jour, ${r['skipped']} deja remplis.',
    );
  }

  Future<void> _runBackfillRecipesReferentials() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Backfill referentiels recettes'),
        content: const Text(
          'Cette operation normalise les ingredients et les unites sur les '
          'recettes historiques, puis reecrit le Cooklang avec les libelles '
          'canoniques resolves.\n\n'
          'Le traitement reprend depuis le checkpoint serveur (idempotent). '
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
      label: 'Backfill referentiels recettes en cours...',
      feature: 'admin_backfill_recipes_referentials',
      run: () =>
          ref.read(gcpBillingRepositoryProvider).backfillRecipesReferentials(),
      format: (r) =>
          'Recettes scannees=${r['scannedRecipes']}, maj=${r['updatedRecipes']}, '
          'cooklang reecrits=${r['rewrittenCooklangRecipes']} | '
          'renommages ingredients=${r['renamedIngredients']}, unites=${r['renamedUnits']} | '
          'erreurs=${r['failed']}'
          '${(r['stoppedByDeadline'] ?? 0) == 1 ? ' - arret preventif (timeout evite), relancer pour continuer' : ''}',
    );
  }

  Future<void> _runInitNutritionUnitsFromCsv() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Init referentiel unites (CSV)'),
        content: const Text(
          'Initialise nutrition_units depuis le referentiel CSV statique '
          '(25 unites culinaires standards).\n\n'
          'Operation idempotente: cree les entrees manquantes, '
          'enrichit les entrees existantes sans ecraser les alias observes. '
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
      label: 'Init unites depuis CSV en cours...',
      feature: 'admin_init_nutrition_units_from_csv',
      run: () =>
          ref.read(gcpBillingRepositoryProvider).initNutritionUnitsFromCsv(),
      format: (r) =>
          '${r['total']} unites traitees: '
          '${r['created']} creees, ${r['updated']} mises a jour.',
    );
  }

  Future<void> _runBackupCollections() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.backup_outlined,
              color: Theme.of(ctx).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            const Expanded(child: Text('Backup des collections')),
          ],
        ),
        content: const Text(
          'Cette operation va:\n'
          '1) Vider backup_recipes, backup_books, backup_nutrition_ingredients\n'
          '2) Copier l\'integralite de recipes, books et nutrition_ingredients '
          'vers ces tables backup.\n\n'
          'L\'operation peut prendre plusieurs minutes selon le volume de donnees.\n\n'
          'Continuer ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Lancer le backup'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _runBackfill<Map<String, int>>(
      label: 'Backup des collections en cours...',
      feature: 'admin_backup_collections',
      run: () => ref.read(gcpBillingRepositoryProvider).backupCollections(),
      format: (r) =>
          'Backup termine: '
          'recipes=${r['backedUpRecipes']}, '
          'books=${r['backedUpBooks']}, '
          'nutrition_ingredients=${r['backedUpNutritionIngredients']}',
    );
  }

  Future<void> _runPurgeNutritionIngredients() async {
    final step1 = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: Theme.of(ctx).colorScheme.error,
            ),
            const SizedBox(width: 8),
            const Expanded(child: Text('Purge nutrition_ingredients')),
          ],
        ),
        content: const Text(
          'Cette operation va SUPPRIMER DEFINITIVEMENT tous les documents '
          'de nutrition_ingredients pour repartir de zero.\n\n'
          'La table nutrition_units n\'est pas modifiee.\n'
          'Les recettes ne sont PAS modifiees.\n\n'
          'Continuer ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Continuer'),
          ),
        ],
      ),
    );
    if (step1 != true || !mounted) return;

    final step2 = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmer la purge ingredients'),
        content: const Text(
          'DERNIERE CONFIRMATION.\n\n'
          'nutrition_ingredients sera vide.\n'
          'Cette action est irreversible.\n\n'
          'Supprimer maintenant ?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Non, annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Oui, supprimer'),
          ),
        ],
      ),
    );
    if (step2 != true || !mounted) return;

    await _runBackfill<Map<String, int>>(
      label: 'Purge nutrition_ingredients en cours...',
      feature: 'admin_purge_nutrition_ingredients',
      run: () =>
          ref.read(gcpBillingRepositoryProvider).purgeNutritionIngredients(),
      format: (r) =>
          'Supprime: nutrition_ingredients=${r['deletedNutritionIngredients']} - '
          'Relancer le bootstrap ingredients pour reconstituer la table.',
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
                        'Backfills Comptabilite',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Ces operations reconstruisent des donnees historiques pour '
                        'ameliorer la coherence des couts et des statistiques.',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _BackfillTile(
                icon: Icons.monitor_heart_outlined,
                title: 'Rebuild nutrition complet',
                subtitle:
                    'Normalise le referentiel, enrichit per100g puis recalcule toutes les recettes en 1 clic.',
                onTap: _busy ? null : _runNutritionGlobalRebuild,
              ),
              const SizedBox(height: 8),
              _BackfillTile(
                icon: Icons.straighten_outlined,
                title: 'Backfill unites nutrition',
                subtitle:
                    'Inventorie les unites des ingredients recettes vers nutrition_units (avec checkpoint).',
                onTap: _busy ? null : _runNutritionUnitsBackfill,
              ),
              const SizedBox(height: 8),
              _BackfillTile(
                icon: Icons.table_chart_outlined,
                title: 'Init referentiel unites (CSV)',
                subtitle:
                    'Charge les 25 unites culinaires standards depuis le referentiel CSV dans nutrition_units.',
                onTap: _busy ? null : _runInitNutritionUnitsFromCsv,
              ),
              const SizedBox(height: 8),
              _BackfillTile(
                icon: Icons.label_outline,
                title: 'Backfill label unites nutrition',
                subtitle:
                    'Remplit le label manquant dans nutrition_units avec le premier alias disponible.',
                onTap: _busy ? null : _runBackfillNutritionUnitsLabel,
              ),
              const SizedBox(height: 8),
              _BackfillTile(
                icon: Icons.sync_alt_outlined,
                title: 'Backfill referentiels recettes',
                subtitle:
                    'Normalise ingredients/unites des recettes historiques et reecrit Cooklang en canonique.',
                onTap: _busy ? null : _runBackfillRecipesReferentials,
              ),
              const SizedBox(height: 8),
              _BackfillTile(
                icon: Icons.backup_outlined,
                title: 'Backup recipes / books / ingredients',
                subtitle:
                    'Vide puis recopie recipes, books et nutrition_ingredients vers backup_recipes, backup_books, backup_nutrition_ingredients.',
                onTap: _busy ? null : _runBackupCollections,
              ),
              const SizedBox(height: 8),
              _BackfillTile(
                icon: Icons.delete_sweep_outlined,
                title: 'Purge nutrition_ingredients',
                subtitle:
                    'DANGER: vide uniquement nutrition_ingredients pour redemarrer le referentiel ingredients a zero.',
                onTap: _busy ? null : _runPurgeNutritionIngredients,
                danger: true,
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
