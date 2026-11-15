import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/email_invitation.dart';
import 'admin_providers.dart';

/// Page « Audience » de Google Auth Platform, où se gèrent les utilisateurs
/// test de l'écran de consentement OAuth du projet.
const kGoogleTestUsersUrl =
    'https://console.cloud.google.com/auth/audience?project=kassdale-6d948';

/// Ouvre une adresse dans le navigateur ; rend faux si le système refuse.
/// Remplacé dans les tests.
final openGoogleConsoleProvider = Provider<Future<bool> Function(Uri uri)>(
  (ref) =>
      (uri) => launchUrl(uri, mode: LaunchMode.externalApplication),
);

/// Bloc du formulaire « Inviter par e-mail » : tant que l'écran de
/// consentement OAuth est en mode « Test », Google refuse la connexion d'une
/// adresse absente des utilisateurs test. Google ne fournit aucune API pour
/// les ajouter : le bouton copie l'adresse saisie et ouvre la page de la
/// console, où l'administrateur la colle.
class GoogleTestUsersLink extends ConsumerStatefulWidget {
  const GoogleTestUsersLink({super.key, required this.emailController});

  /// Champ de l'adresse : lu à l'appui ; une frappe efface le message.
  final TextEditingController emailController;

  static const hint =
      'Google refuse la connexion tant que l\'adresse n\'est pas dans les '
      'utilisateurs test du projet. Ajoutez-la dans la console Google.';
  static const button = 'Copier l\'adresse et ouvrir la console Google';
  static String copied(String email) =>
      'Adresse copiée ($email) : collez-la dans « Utilisateurs test » › '
      '« Ajouter des utilisateurs ».';
  static const noEmail =
      'Aucune adresse valide à copier : saisissez-la d\'abord.';
  static const copyFailed = 'Copie impossible : recopiez l\'adresse à la main.';
  static const openFailure =
      'Impossible d\'ouvrir la console. Adresse de la page :';

  @override
  ConsumerState<GoogleTestUsersLink> createState() =>
      _GoogleTestUsersLinkState();
}

class _GoogleTestUsersLinkState extends ConsumerState<GoogleTestUsersLink> {
  bool _busy = false;
  String? _message;
  bool _messageIsError = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    widget.emailController.addListener(_clearMessage);
  }

  @override
  void dispose() {
    widget.emailController.removeListener(_clearMessage);
    super.dispose();
  }

  void _clearMessage() {
    if (_message != null && !_busy) setState(() => _message = null);
  }

  Future<void> _open() async {
    final errors = ref.read(errorReportServiceProvider);
    final open = ref.read(openGoogleConsoleProvider);
    setState(() {
      _busy = true;
      _message = null;
      _failed = false;
    });
    final email = widget.emailController.text.trim().toLowerCase();
    var copied = false;
    final valid = looksLikeEmail(email);
    if (valid) {
      try {
        await Clipboard.setData(ClipboardData(text: email));
        copied = true;
      } catch (error, stackTrace) {
        await errors.reportError(
          feature: 'admin.invitations',
          error: error,
          stackTrace: stackTrace,
          context: const {'step': 'copy_test_user_email'},
        );
      }
    }
    Object? error;
    StackTrace? stackTrace;
    var opened = false;
    try {
      opened = await open(Uri.parse(kGoogleTestUsersUrl));
    } catch (e, st) {
      error = e;
      stackTrace = st;
    }
    if (!opened) {
      await errors.reportError(
        feature: 'admin.consoleLink',
        error: error ?? StateError('ouverture refusée par le système'),
        stackTrace: stackTrace ?? StackTrace.current,
        context: const {'url': kGoogleTestUsersUrl},
      );
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = copied
          ? GoogleTestUsersLink.copied(email)
          : valid
          ? GoogleTestUsersLink.copyFailed
          : GoogleTestUsersLink.noEmail;
      _messageIsError = valid && !copied;
      _failed = !opened;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final error = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.error,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(GoogleTestUsersLink.hint, style: muted),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _busy ? null : _open,
            icon: const Icon(Icons.open_in_new),
            label: const Text(GoogleTestUsersLink.button),
          ),
        ),
        if (_message case final message?)
          Semantics(
            liveRegion: true,
            child: Text(message, style: _messageIsError ? error : muted),
          ),
        if (_failed) ...[
          Semantics(
            liveRegion: true,
            child: Text(GoogleTestUsersLink.openFailure, style: error),
          ),
          const SelectableText(kGoogleTestUsersUrl),
        ],
      ],
    );
  }
}
