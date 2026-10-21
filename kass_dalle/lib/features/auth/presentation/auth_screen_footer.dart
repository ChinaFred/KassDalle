import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/link.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/app_links.dart';
import '../../../core/app_version.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/utils/context_extensions.dart';
import '../../admin/presentation/admin_providers.dart'
    show errorReportServiceProvider;

/// Libellé du lien vers les règles de confidentialité.
const kPrivacyPolicyLabel = 'Confidentialité';

/// Libellé du lien vers les conditions d'utilisation.
const kTermsOfUseLabel = "Conditions d'utilisation";

/// Pied de l'écran de connexion et de la salle d'attente : les liens vers les
/// règles de confidentialité et les conditions d'utilisation, puis, en
/// dessous, le numéro de version.
///
/// Les liens donnent accès aux règles et aux conditions depuis l'écran de
/// connexion, avant que l'utilisateur accorde l'accès à son compte Google.
/// Les deux pages sont des fichiers statiques de `web/` ([kPrivacyPolicyUrl],
/// [kTermsOfUseUrl]), pas des routes : elles se lisent sans exécuter Flutter.
/// La page d'accueil déclarée à Google est une troisième page statique,
/// `web/accueil.html`.
class AuthScreenFooter extends StatelessWidget {
  const AuthScreenFooter({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const _LegalLink(
                label: kPrivacyPolicyLabel,
                url: kPrivacyPolicyUrl,
              ),
              ExcludeSemantics(child: Text('·', style: muted)),
              const _LegalLink(label: kTermsOfUseLabel, url: kTermsOfUseUrl),
            ],
          ),
          Text('v$kAppVersion', style: muted),
        ],
      ),
    );
  }
}

/// Un lien discret vers une page publique.
///
/// Sur le web, [Link] pose un vrai `<a href>` : le navigateur le suit, et un
/// robot qui lit la page le voit. Ailleurs, l'adresse s'ouvre dans le
/// navigateur du système ; un échec est rapporté et annoncé.
class _LegalLink extends ConsumerWidget {
  final String label;
  final String url;

  const _LegalLink({required this.label, required this.url});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    Widget button(VoidCallback? onPressed) => TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: theme.colorScheme.onSurfaceVariant,
        textStyle: theme.textTheme.labelSmall?.copyWith(
          decoration: TextDecoration.underline,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        // 48 px de haut et de large sur toutes les plateformes : la cible
        // tactile minimale, même là où le thème resserre les boutons.
        minimumSize: const Size(48, 48),
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
      child: Text(label),
    );

    if (kIsWeb) {
      return Link(
        uri: Uri.parse(url),
        target: LinkTarget.blank,
        builder: (context, followLink) => button(followLink),
      );
    }
    return button(() => _open(context, ref));
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    Object? failure;
    StackTrace? failureStack;
    try {
      final opened = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!opened) {
        failure = StateError('Aucune application n\'a ouvert $url');
        failureStack = StackTrace.current;
      }
    } catch (error, stackTrace) {
      failure = error;
      failureStack = stackTrace;
    }
    if (failure == null) return;
    reportUnexpectedError(
      feature: 'auth.legalLink',
      error: failure,
      stackTrace: failureStack,
      context: {'url': url},
      service: ref.read(errorReportServiceProvider),
    );
    if (context.mounted) {
      context.showErrorSnackBar(
        'Page non ouverte. Ouvrez $url dans votre navigateur.',
      );
    }
  }
}
