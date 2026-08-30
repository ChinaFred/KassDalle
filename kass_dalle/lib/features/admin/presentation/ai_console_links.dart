import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/error_report_service.dart';
import '../../../core/utils/context_extensions.dart';

/// Les consoles des deux comptes qui paient ce que l'application dépense.
///
/// Le repli sur l'autre moteur est silencieux par construction : un poste routé
/// vers Claude continue d'être servi par Gemini quand le compte Anthropic n'a
/// plus de crédit, sans qu'aucun écran ne bronche. La cause n'est jamais dans
/// l'application — elle est sur ces pages, et les y chercher prenait jusqu'ici
/// de retrouver soi-même les adresses.
///
/// [withUsageReports] ajoute les deux pages de détail. Elles n'ont de sens que
/// là où l'application affiche ses propres montants : ce sont elles qui portent
/// le chiffre à confronter au nôtre.
class AiConsoleLinks extends StatelessWidget {
  static const _googleBilling =
      'https://console.cloud.google.com/billing?project=kassdale-6d948';
  static const _googleReports =
      'https://console.cloud.google.com/billing/reports?project=kassdale-6d948';
  static const _claudeBilling = 'https://platform.claude.com/settings/billing';
  static const _claudeUsage = 'https://platform.claude.com/settings/usage';

  final bool withUsageReports;

  const AiConsoleLinks({super.key, this.withUsageReports = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            withUsageReports ? 'Consoles :' : 'Facturation :',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const _ConsoleChip(
            label: 'Google Cloud',
            url: _googleBilling,
            tooltip: 'Crédit et facturation du projet Gemini',
          ),
          if (withUsageReports)
            const _ConsoleChip(
              label: 'Rapports Google Cloud',
              url: _googleReports,
              tooltip:
                  'La facture détaillée du projet, par service et par jour — '
                  'le chiffre à confronter à celui de cet écran',
            ),
          const _ConsoleChip(
            label: 'Anthropic',
            url: _claudeBilling,
            tooltip: 'Crédit et facturation du compte Claude',
          ),
          if (withUsageReports)
            const _ConsoleChip(
              label: 'Usage Claude',
              url: _claudeUsage,
              tooltip:
                  'Les jetons et les appels comptés par Anthropic — le chiffre '
                  'à confronter à celui de cet écran',
            ),
        ],
      ),
    );
  }
}

class _ConsoleChip extends StatelessWidget {
  final String label;
  final String url;
  final String tooltip;

  const _ConsoleChip({
    required this.label,
    required this.url,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Tooltip(
      message: tooltip,
      child: ActionChip(
        avatar: Icon(
          Icons.open_in_new,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        label: Text(label),
        onPressed: () => _open(context),
      ),
    );
  }

  Future<void> _open(BuildContext context) async {
    try {
      await launchUrl(Uri.parse(url), mode: LaunchMode.platformDefault);
    } catch (error, stackTrace) {
      // Un lien qui ne s'ouvre pas ne casse rien, mais il ne se tait pas non
      // plus : l'administrateur croirait sinon avoir mal cliqué.
      await ErrorReportService().reportError(
        feature: 'admin.consoleLink',
        error: error,
        stackTrace: stackTrace,
        context: {'url': url},
      );
      if (context.mounted) {
        context.showErrorSnackBar('Impossible d\'ouvrir $url');
      }
    }
  }
}
