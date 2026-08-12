import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/logs_repository.dart';
import '../domain/log_entry.dart';

/// Provider singleton du repo.
final logsRepositoryProvider = Provider<LogsRepository>(
  (ref) => LogsRepository(),
);

/// Filtres actifs (état mutable simple via Notifier).
class LogsFilter {
  const LogsFilter({
    this.severity,
    this.timeRangeMinutes = 60,
    this.correlationId,
    this.jobId,
    this.userId,
    this.freeText,
    this.pageSize = 100,
  });

  final String? severity;
  final int timeRangeMinutes;
  final String? correlationId;
  final String? jobId;
  final String? userId;
  final String? freeText;
  final int pageSize;

  LogsFilter copyWith({
    Object? severity = _sentinel,
    int? timeRangeMinutes,
    Object? correlationId = _sentinel,
    Object? jobId = _sentinel,
    Object? userId = _sentinel,
    Object? freeText = _sentinel,
    int? pageSize,
  }) {
    return LogsFilter(
      severity: severity == _sentinel ? this.severity : severity as String?,
      timeRangeMinutes: timeRangeMinutes ?? this.timeRangeMinutes,
      correlationId: correlationId == _sentinel
          ? this.correlationId
          : correlationId as String?,
      jobId: jobId == _sentinel ? this.jobId : jobId as String?,
      userId: userId == _sentinel ? this.userId : userId as String?,
      freeText: freeText == _sentinel ? this.freeText : freeText as String?,
      pageSize: pageSize ?? this.pageSize,
    );
  }

  static const _sentinel = Object();
}

final logsFilterProvider = NotifierProvider<LogsFilterNotifier, LogsFilter>(
  LogsFilterNotifier.new,
);

class LogsFilterNotifier extends Notifier<LogsFilter> {
  @override
  LogsFilter build() => const LogsFilter();

  void update(LogsFilter Function(LogsFilter) updater) {
    state = updater(state);
  }
}

/// Résultat de requête déclenché manuellement (refresh / changement de filtre).
final logsQueryProvider = FutureProvider.autoDispose<List<LogEntry>>((
  ref,
) async {
  final repo = ref.watch(logsRepositoryProvider);
  final f = ref.watch(logsFilterProvider);
  return repo.query(
    severity: f.severity,
    timeRangeMinutes: f.timeRangeMinutes,
    correlationId: f.correlationId,
    jobId: f.jobId,
    userId: f.userId,
    freeText: f.freeText,
    pageSize: f.pageSize,
  );
});

class LogsScreen extends ConsumerStatefulWidget {
  const LogsScreen({super.key});

  @override
  ConsumerState<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends ConsumerState<LogsScreen> {
  final _freeTextCtrl = TextEditingController();
  final _correlationCtrl = TextEditingController();
  final _jobIdCtrl = TextEditingController();
  final _userIdCtrl = TextEditingController();

  @override
  void dispose() {
    _freeTextCtrl.dispose();
    _correlationCtrl.dispose();
    _jobIdCtrl.dispose();
    _userIdCtrl.dispose();
    super.dispose();
  }

  void _applyFilters() {
    ref.read(logsFilterProvider.notifier).update(
      (s) => s.copyWith(
        freeText: _freeTextCtrl.text.trim().isEmpty
            ? null
            : _freeTextCtrl.text.trim(),
        correlationId: _correlationCtrl.text.trim().isEmpty
            ? null
            : _correlationCtrl.text.trim(),
        jobId: _jobIdCtrl.text.trim().isEmpty ? null : _jobIdCtrl.text.trim(),
        userId: _userIdCtrl.text.trim().isEmpty
            ? null
            : _userIdCtrl.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Date ET heure : la fenêtre de recherche va jusqu'à sept jours, si bien
    // qu'une heure seule ne dit pas de quel jour on parle — et deux appels du
    // même poste à 15:19 deviennent indiscernables.
    final fmt = DateFormat('dd/MM HH:mm:ss.SSS');
    final filter = ref.watch(logsFilterProvider);
    final async = ref.watch(logsQueryProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cloud Logging'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualiser',
            onPressed: () => ref.invalidate(logsQueryProvider),
          ),
        ],
      ),
      body: Column(
        children: [
          // ─── Bandeau de filtres ──────────────────────────────────────────
          Material(
            color: theme.colorScheme.surfaceContainerLow,
            elevation: 1,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Sévérité (Chips).
                  Wrap(
                    spacing: 8,
                    children: [
                      _sevChip(filter, null, 'Tous'),
                      _sevChip(filter, 'INFO', 'INFO'),
                      _sevChip(filter, 'WARNING', 'WARN'),
                      _sevChip(filter, 'ERROR', 'ERROR'),
                      _sevChip(filter, 'DEBUG', 'DEBUG'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // Fenêtre temporelle.
                  Row(
                    children: [
                      const Text('Fenêtre : '),
                      const SizedBox(width: 8),
                      DropdownButton<int>(
                        value: filter.timeRangeMinutes,
                        items: const [
                          DropdownMenuItem(value: 15, child: Text('15 min')),
                          DropdownMenuItem(value: 60, child: Text('1 h')),
                          DropdownMenuItem(value: 360, child: Text('6 h')),
                          DropdownMenuItem(value: 1440, child: Text('24 h')),
                          DropdownMenuItem(value: 10080, child: Text('7 j')),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          ref
                              .read(logsFilterProvider.notifier)
                              .update((s) => s.copyWith(timeRangeMinutes: v));
                        },
                      ),
                      const Spacer(),
                      Text(
                        '${async.maybeWhen(data: (d) => d.length, orElse: () => 0)} entrées',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _freeTextCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Recherche message',
                            isDense: true,
                          ),
                          onSubmitted: (_) => _applyFilters(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _correlationCtrl,
                          decoration: const InputDecoration(
                            labelText: 'correlationId',
                            isDense: true,
                          ),
                          onSubmitted: (_) => _applyFilters(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _jobIdCtrl,
                          decoration: const InputDecoration(
                            labelText: 'jobId',
                            isDense: true,
                          ),
                          onSubmitted: (_) => _applyFilters(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _userIdCtrl,
                          decoration: const InputDecoration(
                            labelText: 'userId',
                            isDense: true,
                          ),
                          onSubmitted: (_) => _applyFilters(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: _applyFilters,
                        icon: const Icon(Icons.search),
                        label: const Text('Filtrer'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          // ─── Résultats ───────────────────────────────────────────────────
          Expanded(
            child: async.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'Erreur : $e',
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
              ),
              data: (entries) {
                if (entries.isEmpty) {
                  return const Center(
                    child: Text('Aucune entrée correspondant aux filtres.'),
                  );
                }
                return ListView.separated(
                  itemCount: entries.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1),
                  itemBuilder: (context, i) {
                    final e = entries[i];
                    return _LogTile(entry: e, fmt: fmt);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _sevChip(LogsFilter filter, String? value, String label) {
    final selected = filter.severity == value;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) {
        ref
            .read(logsFilterProvider.notifier)
            .update((s) => s.copyWith(severity: value));
      },
    );
  }
}

class _LogTile extends StatelessWidget {
  const _LogTile({required this.entry, required this.fmt});
  final LogEntry entry;
  final DateFormat fmt;

  Color _sevColor(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    switch (entry.severity) {
      case 'ERROR':
        return cs.error;
      case 'WARNING':
        return Colors.orange;
      case 'INFO':
        return cs.primary;
      case 'DEBUG':
        return cs.outline;
      default:
        return cs.onSurfaceVariant;
    }
  }

  IconData _sevIcon() {
    switch (entry.severity) {
      case 'ERROR':
        return Icons.error_outline;
      case 'WARNING':
        return Icons.warning_amber_outlined;
      case 'INFO':
        return Icons.info_outline;
      case 'DEBUG':
        return Icons.bug_report_outlined;
      default:
        return Icons.circle_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = _sevColor(context);
    final dt = entry.timestampDate;
    final dateStr = dt != null ? fmt.format(dt.toLocal()) : entry.timestamp;
    final encoder = const JsonEncoder.withIndent('  ');

    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      leading: Icon(_sevIcon(), color: color),
      title: Text(
        entry.message.isEmpty ? '(sans message)' : entry.message,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          Text(dateStr, style: theme.textTheme.bodySmall),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              entry.severity,
              style: theme.textTheme.labelSmall?.copyWith(color: color),
            ),
          ),
          // Le moteur d'abord : depuis qu'il y en a deux, c'est la première
          // question qu'on pose à un log d'appel IA.
          if (entry.labels['provider'] != null)
            _providerChip(theme, entry.labels['provider']!, entry.labels['model']),
          if (entry.labels['feature'] != null)
            _label(theme, 'poste', entry.labels['feature']!),
          if (entry.labels['moduleType'] != null)
            _label(theme, 'module', entry.labels['moduleType']!),
          if (entry.labels['correlationId'] != null)
            _label(theme, 'corr', entry.labels['correlationId']!),
          if (entry.labels['jobId'] != null)
            _label(theme, 'job', entry.labels['jobId']!),
        ],
      ),
      children: [
        _section(context, 'Labels', entry.labels.entries.map((e) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 130,
                child: Text(
                  e.key,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              Expanded(child: SelectableText(e.value)),
              IconButton(
                icon: const Icon(Icons.copy, size: 16),
                tooltip: 'Copier',
                onPressed: () => Clipboard.setData(ClipboardData(text: e.value)),
              ),
            ],
          );
        }).toList()),
        const SizedBox(height: 8),
        Text('JSON payload', style: theme.textTheme.labelMedium),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: SelectableText(
            encoder.convert(entry.payload),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
        ),
      ],
    );
  }

  /// Pastille du moteur d'inférence, colorée pour être repérable d'un coup
  /// d'œil dans une liste longue — et suivie du modèle exact, parce que
  /// « Claude » ne dit pas lequel ni à quel tarif.
  Widget _providerChip(ThemeData theme, String provider, String? model) {
    final isAnthropic = provider == 'anthropic';
    final color = isAnthropic
        ? theme.colorScheme.tertiary
        : theme.colorScheme.primary;
    final label = isAnthropic ? 'Claude' : 'Gemini';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        model == null ? label : '$label · $model',
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _label(ThemeData theme, String key, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$key=$value',
        style: theme.textTheme.labelSmall?.copyWith(fontFamily: 'monospace'),
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<Widget> children) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 4),
        ...children,
      ],
    );
  }
}
