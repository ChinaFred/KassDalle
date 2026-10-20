import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'admin_providers.dart';
import '../../../core/services/error_report_service.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../../core/widgets/tappable_pill.dart';

class ErrorReportsScreen extends ConsumerWidget {
  const ErrorReportsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reportsAsync = ref.watch(allErrorReportsProvider);
    final theme = Theme.of(context);
    final fmt = DateFormat('dd/MM/yy HH:mm');

    return Scaffold(
      appBar: AppBar(
        title: const Text('Rapports d\'erreurs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Actualiser',
            onPressed: () => ref.invalidate(allErrorReportsProvider),
          ),
        ],
      ),
      body: reportsAsync.when(
        loading: () => const AppLoadingState(),
        error: (e, _) => AppErrorState(
          error: e,
          onRetry: () => ref.invalidate(allErrorReportsProvider),
        ),
        data: (reports) {
          if (reports.isEmpty) {
            return const Center(child: Text('Aucun rapport d\'erreur.'));
          }
          return ListView.separated(
            itemCount: reports.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final r = reports[i];
              return _ErrorReportTile(report: r, fmt: fmt, theme: theme);
            },
          );
        },
      ),
    );
  }
}

class _ErrorReportTile extends StatelessWidget {
  final ErrorReport report;
  final DateFormat fmt;
  final ThemeData theme;

  const _ErrorReportTile({
    required this.report,
    required this.fmt,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      leading: Icon(
        Icons.bug_report_outlined,
        color: theme.colorScheme.error,
        size: AppIconSize.small,
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(
              report.feature,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          _CopyableChip(label: report.id, context: context),
        ],
      ),
      subtitle: Text(
        '${fmt.format(report.timestamp)}  •  v${report.appVersion}  •  ${report.errorType}',
        style: theme.textTheme.bodySmall,
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        // Message d'erreur
        _Section(label: 'Message', content: report.errorMessage, theme: theme),
        // Contexte
        if (report.context.isNotEmpty)
          _Section(
            label: 'Contexte',
            content: report.context.entries
                .map((e) => '${e.key}: ${e.value}')
                .join('\n'),
            theme: theme,
          ),
        // Stack trace
        if (report.stackTrace != null && report.stackTrace!.isNotEmpty)
          _Section(
            label: 'Stack trace',
            content: report.stackTrace!,
            theme: theme,
            mono: true,
          ),
        // Job ID
        if (report.jobId != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Job : ${report.jobId}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String label;
  final String content;
  final ThemeData theme;
  final bool mono;

  const _Section({
    required this.label,
    required this.content,
    required this.theme,
    this.mono = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.bold,
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
            child: Text(
              content,
              style: mono
                  ? theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      fontSize: 10,
                    )
                  : theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyableChip extends StatelessWidget {
  final String label;
  final BuildContext context;

  const _CopyableChip({required this.label, required this.context});

  @override
  Widget build(BuildContext outerContext) {
    return TappablePill(
      tooltip: 'Copier l\'identifiant',
      label: 'Copier l\'identifiant $label',
      customBorder: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(4),
      ),
      onTap: () {
        Clipboard.setData(ClipboardData(text: label));
        outerContext.showSuccessSnackBar('ID copié : $label');
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Theme.of(outerContext).colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label.length > 8 ? label.substring(0, 8) : label,
              style: TextStyle(
                fontSize: 10,
                fontFamily: 'monospace',
                color: Theme.of(outerContext).colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(width: 2),
            Icon(
              Icons.copy_outlined,
              size: AppIconSize.badge,
              color: Theme.of(outerContext).colorScheme.onErrorContainer,
            ),
          ],
        ),
      ),
    );
  }
}
