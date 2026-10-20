import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/feature_catalog.dart';
import '../data/logs_repository.dart';
import '../domain/ai_call.dart';
import '../domain/log_scan_group.dart';
import '../domain/log_entry.dart';
import '../../../core/services/error_report_service.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/theme/app_icon_size.dart';

/// Provider singleton du repo.
final logsRepositoryProvider = Provider<LogsRepository>(
  (ref) => LogsRepository(),
);

/// Filtres actifs (état mutable simple via Notifier).
class LogsFilter {
  const LogsFilter({
    /// Seuil de sévérité, `null` = tout y compris l'instrumentation DEBUG.
    ///
    /// Par défaut `INFO` : un import écrit une cinquantaine de lignes dont une
    /// quinzaine porte une information — prompts et réponses brutes sont
    /// désormais en DEBUG et restent à un clic, sans noyer l'écran.
    this.severity = 'INFO',
    this.timeRangeMinutes = 60,
    this.correlationId,
    this.scanId,
    this.jobId,
    this.userId,
    this.freeText,
    this.pageSize = 100,
  });

  final String? severity;
  final int timeRangeMinutes;
  final String? correlationId;

  /// Scan isolé — l'acte de l'utilisateur, pas l'un de ses traitements.
  ///
  /// Filtrer sur `correlationId` ne rendait qu'un des quatre traitements d'un
  /// import : on croyait tenir le scan entier alors qu'il en manquait les
  /// trois quarts, coût compris.
  final String? scanId;

  final String? jobId;
  final String? userId;
  final String? freeText;
  final int pageSize;

  LogsFilter copyWith({
    Object? severity = _sentinel,
    int? timeRangeMinutes,
    Object? correlationId = _sentinel,
    Object? scanId = _sentinel,
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
      scanId: scanId == _sentinel ? this.scanId : scanId as String?,
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

/// Entrées chargées, page après page, et ce que chaque appel a coûté.
///
/// L'écran affichait une page et rien d'autre. Cloud Logging en rend cent par
/// défaut ; un import bavard en produit davantage, et les suivantes étaient
/// simplement absentes — sans message, sans bouton, sans indice. On croyait
/// lire un traitement entier alors qu'on n'en voyait que la fin.
class LogsPageState {
  const LogsPageState({
    required this.entries,
    this.calls = const [],
    this.usdToEur,
    this.nextPageToken,
    this.loadingMore = false,
  });

  final List<LogEntry> entries;

  /// Les appels facturés rattachés à ces entrées, lus dans `ai_usage`.
  final List<AiCall> calls;

  /// Taux du jour, `null` s'il est indisponible : les montants restent alors
  /// en dollars plutôt que d'être convertis à un taux inventé.
  final double? usdToEur;

  final String? nextPageToken;

  /// Vrai pendant le chargement de la page suivante — l'écran garde les
  /// entrées déjà lues à l'écran plutôt que de repartir d'un cadre vide.
  final bool loadingMore;

  bool get hasMore => (nextPageToken ?? '').isNotEmpty;
}

final logsQueryProvider =
    AsyncNotifierProvider.autoDispose<LogsQueryNotifier, LogsPageState>(
      LogsQueryNotifier.new,
    );

class LogsQueryNotifier extends AsyncNotifier<LogsPageState> {
  @override
  Future<LogsPageState> build() async {
    final repo = ref.watch(logsRepositoryProvider);
    final f = ref.watch(logsFilterProvider);
    final page = await repo.query(
      severity: f.severity,
      timeRangeMinutes: f.timeRangeMinutes,
      correlationId: f.correlationId,
      scanId: f.scanId,
      jobId: f.jobId,
      userId: f.userId,
      freeText: f.freeText,
      pageSize: f.pageSize,
    );
    return LogsPageState(
      entries: page.entries,
      calls: page.calls,
      usdToEur: page.usdToEur,
      nextPageToken: page.nextPageToken,
    );
  }

  /// Ajoute la page suivante à celles déjà lues.
  Future<void> loadMore() async {
    final current = state.value;
    if (current == null || !current.hasMore || current.loadingMore) return;

    state = AsyncData(
      LogsPageState(
        entries: current.entries,
        calls: current.calls,
        usdToEur: current.usdToEur,
        nextPageToken: current.nextPageToken,
        loadingMore: true,
      ),
    );

    final repo = ref.read(logsRepositoryProvider);
    final f = ref.read(logsFilterProvider);
    try {
      final page = await repo.query(
        severity: f.severity,
        timeRangeMinutes: f.timeRangeMinutes,
        correlationId: f.correlationId,
        scanId: f.scanId,
        jobId: f.jobId,
        userId: f.userId,
        freeText: f.freeText,
        pageSize: f.pageSize,
        pageToken: current.nextPageToken,
      );
      state = AsyncData(
        LogsPageState(
          entries: [...current.entries, ...page.entries],
          // Un même appel revient d'une page à l'autre : les appels sont
          // rattachés aux entrées visibles, et deux pages voisines partagent
          // souvent un traitement. Le compter deux fois doublerait son coût
          // dans le total du scan.
          calls: mergeAiCalls(current.calls, page.calls),
          usdToEur: page.usdToEur ?? current.usdToEur,
          nextPageToken: page.nextPageToken,
        ),
      );
    } catch (err, stack) {
      // Les entrées déjà lues restent à l'écran : perdre la page précédente
      // parce que la suivante a échoué punirait deux fois.
      state = AsyncData(
        LogsPageState(
          entries: current.entries,
          calls: current.calls,
          usdToEur: current.usdToEur,
          nextPageToken: current.nextPageToken,
        ),
      );
      ErrorReportService().reportError(
        feature: 'admin_logs',
        error: err,
        stackTrace: stack,
        context: {'action': 'loadMore', 'deja_lues': current.entries.length},
      );
      rethrow;
    }
  }
}

// ─── Écran ───────────────────────────────────────────────────────────────────

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

  /// Regroupe les entrées par scan plutôt qu'en liste plate.
  ///
  /// Un scan déclenche quatre traitements et une trentaine de messages,
  /// dispersés dans le flux entre ceux des autres scans. Lus à plat, ils
  /// obligent à reconstituer mentalement ce qui appartient à quoi.
  bool _grouped = true;

  @override
  void dispose() {
    _freeTextCtrl.dispose();
    _correlationCtrl.dispose();
    _jobIdCtrl.dispose();
    _userIdCtrl.dispose();
    super.dispose();
  }

  void _applyFilters() {
    ref
        .read(logsFilterProvider.notifier)
        .update(
          (s) => s.copyWith(
            freeText: _freeTextCtrl.text.trim().isEmpty
                ? null
                : _freeTextCtrl.text.trim(),
            correlationId: _correlationCtrl.text.trim().isEmpty
                ? null
                : _correlationCtrl.text.trim(),
            jobId: _jobIdCtrl.text.trim().isEmpty
                ? null
                : _jobIdCtrl.text.trim(),
            userId: _userIdCtrl.text.trim().isEmpty
                ? null
                : _userIdCtrl.text.trim(),
          ),
        );
  }

  void _isolateScan(String scanId) {
    _correlationCtrl.clear();
    ref
        .read(logsFilterProvider.notifier)
        .update((s) => s.copyWith(scanId: scanId, correlationId: null));
  }

  void _isolateCorrelation(String correlationId) {
    _correlationCtrl.text = correlationId;
    ref
        .read(logsFilterProvider.notifier)
        .update((s) => s.copyWith(correlationId: correlationId, scanId: null));
  }

  void _clearScan() {
    ref
        .read(logsFilterProvider.notifier)
        .update((s) => s.copyWith(scanId: null));
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
                      // Seuils, pas égalités : « INFO » montre aussi les WARN
                      // et les ERROR. Seul « DEBUG » isole l'instrumentation.
                      _sevChip(filter, null, 'Tout'),
                      _sevChip(filter, 'INFO', 'INFO+'),
                      _sevChip(filter, 'WARNING', 'WARN+'),
                      _sevChip(filter, 'ERROR', 'ERROR'),
                      _sevChip(filter, 'DEBUG', 'DEBUG seul'),
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
                        '${async.maybeWhen(data: (d) => d.entries.length, orElse: () => 0)} entrées',
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
                      FilterChip(
                        label: const Text('Par scan'),
                        avatar: const Icon(
                          Icons.account_tree_outlined,
                          size: AppIconSize.small,
                        ),
                        selected: _grouped,
                        onSelected: (v) => setState(() => _grouped = v),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        onPressed: _applyFilters,
                        icon: const Icon(Icons.search),
                        label: const Text('Filtrer'),
                      ),
                    ],
                  ),
                  // Un scan isolé doit se voir et se défaire : sans ce bandeau,
                  // l'écran semblait vide de tout le reste sans dire pourquoi.
                  if (filter.scanId != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Scan isolé : ${filter.scanId}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.primary,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        TextButton.icon(
                          onPressed: _clearScan,
                          icon: const Icon(
                            Icons.close,
                            size: AppIconSize.small,
                          ),
                          label: const Text('Tout afficher'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          // ─── Résultats ───────────────────────────────────────────────────
          Expanded(
            child: async.when(
              loading: () => const AppLoadingState(),
              error: (e, _) => AppErrorState(
                error: e,
                onRetry: () => ref.invalidate(logsQueryProvider),
              ),
              data: (page) {
                final entries = page.entries;
                if (entries.isEmpty && page.calls.isEmpty) {
                  return const Center(
                    child: Text('Aucune entrée correspondant aux filtres.'),
                  );
                }

                // Le pied de liste dit toujours ce qui est affiché, et si la
                // suite existe. Une liste tronquée en silence se lit comme une
                // liste complète : c'est ainsi qu'on conclut à tort qu'une
                // étape n'a pas eu lieu.
                Widget footer() => _LoadMoreFooter(
                  loaded: entries.length,
                  hasMore: page.hasMore,
                  loading: page.loadingMore,
                  onLoadMore: () =>
                      ref.read(logsQueryProvider.notifier).loadMore(),
                );

                if (!_grouped) {
                  return ListView.separated(
                    itemCount: entries.length + 1,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      if (i == entries.length) return footer();
                      return _LogTile(entry: entries[i], fmt: fmt);
                    },
                  );
                }

                final groups = groupLogsByScan(entries, page.calls);
                return ListView.separated(
                  itemCount: groups.length + 1,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) {
                    if (i == groups.length) return footer();
                    return _ScanTile(
                      group: groups[i],
                      fmt: fmt,
                      usdToEur: page.usdToEur,
                      onIsolateScan: _isolateScan,
                      onIsolateCorrelation: _isolateCorrelation,
                    );
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

/// Pied de liste : combien d'entrées sont lues, et comment lire la suite.
///
/// Il s'affiche même quand il n'y a plus rien à charger — c'est justement le
/// cas où il faut le dire, sans quoi on ne sait pas si l'on tient tout ou
/// seulement le début.
class _LoadMoreFooter extends StatelessWidget {
  const _LoadMoreFooter({
    required this.loaded,
    required this.hasMore,
    required this.loading,
    required this.onLoadMore,
  });

  final int loaded;
  final bool hasMore;
  final bool loading;
  final VoidCallback onLoadMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: Column(
        children: [
          Text(
            hasMore
                ? '$loaded entrée(s) lues — il en reste'
                : '$loaded entrée(s) — c\x27est tout pour ces filtres',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (hasMore) ...[
            const SizedBox(height: 8),
            loading
                ? const SizedBox(
                    height: 24,
                    width: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : OutlinedButton.icon(
                    onPressed: onLoadMore,
                    icon: const Icon(Icons.expand_more),
                    label: const Text('Charger la suite'),
                  ),
          ],
        ],
      ),
    );
  }
}

// ─── Niveau 1 : le scan ──────────────────────────────────────────────────────

class _ScanTile extends StatelessWidget {
  const _ScanTile({
    required this.group,
    required this.fmt,
    required this.usdToEur,
    required this.onIsolateScan,
    required this.onIsolateCorrelation,
  });

  final ScanGroup group;
  final DateFormat fmt;
  final double? usdToEur;
  final ValueChanged<String> onIsolateScan;
  final ValueChanged<String> onIsolateCorrelation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final color = group.hasError
        ? cs.error
        : group.hasWarning
        ? cs.tertiary
        : cs.primary;
    final icon = group.hasError
        ? Icons.error_outline
        : group.hasWarning
        ? Icons.warning_amber_outlined
        : group.isScan
        ? Icons.document_scanner_outlined
        : Icons.account_tree_outlined;

    final when = group.lastAt != null
        ? fmt.format(group.lastAt!.toLocal())
        : '';
    final traitements = group.treatments.isEmpty
        ? ''
        : '${group.treatments.join(' · ')} · ';

    return ExpansionTile(
      // Un scan en échec s'ouvre de lui-même : c'est celui qu'on est venu lire.
      // Les autres restent pliés pour que l'écran reste parcourable.
      initiallyExpanded: group.hasError,
      tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(icon, color: color),
      title: Row(
        children: [
          Expanded(
            child: Text(
              group.label,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _CostChip(total: group.total, usdToEur: usdToEur, emphasized: true),
        ],
      ),
      subtitle: Text(
        '$traitements${group.entryCount} message(s) · $when',
        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
      ),
      trailing: _isolateButton(),
      children: group.items
          .map((item) {
            if (item is CallItem) {
              return _CallTile(item: item, fmt: fmt, usdToEur: usdToEur);
            }
            return _LogTile(entry: (item as EntryItem).entry, fmt: fmt);
          })
          .toList(growable: false),
    );
  }

  /// Isoler le scan quand il y en a un, le traitement sinon.
  Widget? _isolateButton() {
    if (group.isScan) {
      return IconButton(
        icon: const Icon(Icons.filter_alt_outlined),
        tooltip: 'N\x27afficher que ce scan',
        onPressed: () => onIsolateScan(group.key),
      );
    }
    if (group.correlationIds.isEmpty) return null;
    return IconButton(
      icon: const Icon(Icons.filter_alt_outlined),
      tooltip: 'N\x27afficher que ce traitement',
      onPressed: () => onIsolateCorrelation(group.correlationIds.first),
    );
  }
}

// ─── Niveau 2 : un appel de modèle ───────────────────────────────────────────

class _CallTile extends StatelessWidget {
  const _CallTile({
    required this.item,
    required this.fmt,
    required this.usdToEur,
  });

  final CallItem item;
  final DateFormat fmt;
  final double? usdToEur;

  /// Le poste, en français. Il vient du catalogue comptable : c'est le même
  /// nom que sur l'écran des coûts, et deux noms pour un poste obligeraient à
  /// traduire de tête pour rapprocher deux chiffres.
  String get _label {
    final feature =
        item.call?.feature ??
        item.entries
            .map((e) => e.labels['feature'])
            .firstWhere((f) => f != null && f.isNotEmpty, orElse: () => null) ??
        '';
    return feature.isEmpty ? 'Appel de modèle' : featureLabel(feature);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final call = item.call;
    final color = item.hasError ? cs.error : cs.tertiary;

    final at = item.at;
    final when = at != null ? fmt.format(at.toLocal()) : '';
    final details = <String>[
      if (call != null && call.model.isNotEmpty)
        _providerName(call.provider) +
            (call.model.isEmpty ? '' : ' · ${call.model}'),
      if (call != null && call.totalTokens > 0)
        '${call.inputTokens} → ${call.outputTokens} jetons',
      if (call != null && call.failed) 'appel en échec',
      if (when.isNotEmpty) when,
    ];

    final title = Row(
      children: [
        Expanded(
          child: Text(
            _label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(width: 8),
        _CostChip(
          total: call == null
              ? AiCostTotal.empty
              : AiCostTotal.empty.plus(call),
          usdToEur: usdToEur,
          // L'appel dont la ligne de consommation n'a pas été lue n'a pas de
          // montant à zéro : il n'en a pas du tout, et le dire est le seul
          // moyen de ne pas prendre un total amputé pour une dépense réelle.
          missing: call == null,
        ),
      ],
    );

    final subtitle = Text(
      details.join(' · '),
      style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
    );

    // Un appel dont aucune ligne de journal n'est visible ne s'ouvre pas :
    // une flèche qui ne déplie rien fait chercher ce qui n'existe pas.
    if (item.entries.isEmpty) {
      return ListTile(
        contentPadding: const EdgeInsets.only(left: 32, right: 16),
        leading: Icon(
          Icons.bolt_outlined,
          color: color,
          size: AppIconSize.small,
        ),
        title: title,
        subtitle: subtitle,
      );
    }

    return ExpansionTile(
      initiallyExpanded: item.hasError,
      tilePadding: const EdgeInsets.only(left: 32, right: 16),
      leading: Icon(Icons.bolt_outlined, color: color, size: AppIconSize.small),
      title: title,
      subtitle: subtitle,
      children: item.entries
          .map((e) => _LogTile(entry: e, fmt: fmt))
          .toList(growable: false),
    );
  }
}

String _providerName(String provider) {
  switch (provider) {
    case 'anthropic':
      return 'Claude';
    case 'gemini':
      return 'Gemini';
    case 'vision':
      return 'Cloud Vision';
    case 'internal':
      return 'Interne';
    default:
      return provider;
  }
}

/// Le montant d'un niveau, ou son absence.
///
/// « sans montant » et « 0,00 € » ne disent pas la même chose : le premier est
/// un appel dont on ne sait pas le prix, le second un appel gratuit. Les
/// confondre fait passer une grille tarifaire en panne pour une bonne nouvelle.
class _CostChip extends StatelessWidget {
  const _CostChip({
    required this.total,
    required this.usdToEur,
    this.emphasized = false,
    this.missing = false,
  });

  final AiCostTotal total;
  final double? usdToEur;
  final bool emphasized;
  final bool missing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    final String text;
    final Color color;
    if (missing) {
      text = 'sans montant';
      color = cs.onSurfaceVariant;
    } else if (total.isEmpty) {
      return const SizedBox.shrink();
    } else if (emphasized) {
      text = formatTotal(total, usdToEur);
      color = total.unpricedCalls > 0 ? cs.tertiary : cs.primary;
    } else {
      text = formatCost(
        total.unpricedCalls == total.calls ? null : total.costUsd,
        usdToEur,
      );
      color = total.unpricedCalls > 0 ? cs.tertiary : cs.primary;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: emphasized ? FontWeight.w600 : FontWeight.w500,
        ),
      ),
    );
  }
}

// ─── Niveau 3 : une ligne de journal ─────────────────────────────────────────

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
        return cs.tertiary;
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
            _providerChip(
              theme,
              entry.labels['provider']!,
              entry.labels['model'],
            ),
          if (entry.labels['feature'] != null)
            _label(theme, 'poste', entry.labels['feature']!),
          if (entry.labels['moduleType'] != null)
            _label(theme, 'module', entry.labels['moduleType']!),
          // Ni `scanId` ni `callId` ici : ils nomment les deux niveaux qui
          // portent déjà cette ligne, et les répéter sur chacune de ses sœurs
          // n'apprend rien. Ils restent dans la section Labels, où l'on va
          // quand on veut les copier.
          if (entry.labels['correlationId'] != null)
            _label(theme, 'corr', entry.labels['correlationId']!),
          if (entry.labels['jobId'] != null)
            _label(theme, 'job', entry.labels['jobId']!),
        ],
      ),
      children: [
        _section(
          context,
          'Labels',
          entry.labels.entries.map((e) {
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
                  icon: const Icon(
                    Icons.copy_outlined,
                    size: AppIconSize.inline,
                  ),
                  tooltip: 'Copier',
                  onPressed: () =>
                      Clipboard.setData(ClipboardData(text: e.value)),
                ),
              ],
            );
          }).toList(),
        ),
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
