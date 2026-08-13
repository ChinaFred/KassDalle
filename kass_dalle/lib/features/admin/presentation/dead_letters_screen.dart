import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/dead_letter_repository.dart';
import '../domain/dead_letter.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/utils/context_extensions.dart';

/// Provider du repo (singleton).
final deadLetterRepositoryProvider = Provider<DeadLetterRepository>(
  (ref) => DeadLetterRepository(),
);

/// Stream temps réel de toutes les entrées DLQ.
final deadLettersStreamProvider = StreamProvider.autoDispose<List<DeadLetter>>(
  (ref) => ref.watch(deadLetterRepositoryProvider).watchAll(),
);

class DeadLettersScreen extends ConsumerWidget {
  const DeadLettersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final fmt = DateFormat('dd/MM/yy HH:mm');
    final async = ref.watch(deadLettersStreamProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dead Letter Queue'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualiser',
            onPressed: () => ref.invalidate(deadLettersStreamProvider),
          ),
        ],
      ),
      body: async.when(
        loading: () => const AppLoadingState(),
        error: (e, _) => AppErrorState(
          error: e,
          onRetry: () => ref.invalidate(deadLettersStreamProvider),
        ),
        data: (items) {
          if (items.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Aucun job en échec. La file est saine.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (_, i) =>
                _DeadLetterTile(item: items[i], fmt: fmt, theme: theme),
          );
        },
      ),
    );
  }
}

class _DeadLetterTile extends ConsumerWidget {
  final DeadLetter item;
  final DateFormat fmt;
  final ThemeData theme;

  const _DeadLetterTile({
    required this.item,
    required this.fmt,
    required this.theme,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final relaunched = item.isRelaunched;
    return ExpansionTile(
      leading: Icon(
        relaunched ? Icons.replay_circle_filled : Icons.error_outline,
        color: relaunched ? theme.colorScheme.primary : theme.colorScheme.error,
      ),
      title: Text(
        item.failureReason.isEmpty ? '(raison inconnue)' : item.failureReason,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w600,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          spacing: 12,
          runSpacing: 2,
          children: [
            Text(
              item.failedAt == null ? '—' : fmt.format(item.failedAt!),
              style: theme.textTheme.bodySmall,
            ),
            Text(
              'tentatives : ${item.retryCount}',
              style: theme.textTheme.bodySmall,
            ),
            if (relaunched)
              Text(
                'relancé le ${fmt.format(item.relaunchedAt!)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
          ],
        ),
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        _kv(theme, 'Job original', item.originalJobId, copyable: true),
        _kv(theme, 'User ID', item.userId, copyable: true),
        if (item.correlationId != null)
          _kv(theme, 'Correlation ID', item.correlationId!, copyable: true),
        if (item.filePath != null)
          _kv(theme, 'Fichier', item.filePath!, copyable: true),
        if (item.queueName != null) _kv(theme, 'Queue', item.queueName!),
        if (item.relaunchedIntoJobId != null)
          _kv(theme, 'Nouveau job', item.relaunchedIntoJobId!, copyable: true),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'Dernière erreur',
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: SelectableText(
            item.lastError.isEmpty ? '(vide)' : item.lastError,
            style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              onPressed: () => _confirmDelete(context, ref),
              icon: const Icon(Icons.delete_outline),
              label: const Text('Supprimer'),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: relaunched
                  ? null
                  : () => _confirmRelaunch(context, ref),
              icon: const Icon(Icons.replay),
              label: Text(relaunched ? 'Déjà relancé' : 'Relancer'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _kv(
    ThemeData theme,
    String label,
    String value, {
    bool copyable = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(value, style: theme.textTheme.bodySmall),
          ),
          if (copyable)
            IconButton(
              icon: const Icon(Icons.copy, size: 16),
              tooltip: 'Copier',
              onPressed: () => Clipboard.setData(ClipboardData(text: value)),
              visualDensity: VisualDensity.compact,
            ),
        ],
      ),
    );
  }

  Future<void> _confirmRelaunch(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Relancer ce job ?'),
        content: const Text(
          'Un nouveau processing_job sera créé à partir des données '
          'originales et passera dans la file Cloud Tasks.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Relancer'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      final newId = await ref
          .read(deadLetterRepositoryProvider)
          .relaunch(item.id);
      if (!context.mounted) return;
      context.showSuccessSnackBar('Relancé — nouveau job : $newId');
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'deadLettersScreen.confirmRelaunch',
        error: e,
        stackTrace: stackTrace,
      );
      if (!context.mounted) return;
      context.showErrorSnackBar('Échec de la relance : $e');
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Supprimer cette entrée ?'),
        content: const Text(
          'Cette action est définitive. L\'entrée DLQ sera retirée mais le '
          'job original et le fichier source restent intacts.',
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
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      await ref.read(deadLetterRepositoryProvider).delete(item.id);
      if (!context.mounted) return;
      context.showSuccessSnackBar('Entrée supprimée.');
    } catch (e, stackTrace) {
      reportUnexpectedError(
        feature: 'deadLettersScreen.confirmDelete',
        error: e,
        stackTrace: stackTrace,
      );
      if (!context.mounted) return;
      context.showErrorSnackBar('Échec de la suppression : $e');
    }
  }
}
