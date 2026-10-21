import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'auth_providers.dart';
import 'auth_screen_footer.dart';
import '../../admin/presentation/admin_providers.dart'
    show errorReportServiceProvider;
import '../../../core/services/error_reporting.dart';
import '../../../core/widgets/error_message.dart';

const _devAutoLogin = bool.fromEnvironment(
  'DEV_AUTO_LOGIN',
  defaultValue: true,
);

/// Message de l'écran de connexion d'un compte révoqué.
const kRevokedLoginMessage =
    "Votre accès a été révoqué. Contactez l'administrateur.\n"
    'Vous avez reçu une invitation ? Reconnectez-vous avec le compte Google '
    "de l'adresse invitée.";

/// Conseil des erreurs de connexion qui n'en ont pas de propre : un refus
/// d'accès ou une erreur inattendue. Les conseils génériques renvoient à un
/// rôle ou à des détails techniques que l'écran de connexion n'a pas.
const kLoginErrorAdvice =
    'Réessayez. Si le problème persiste, prévenez l\'administrateur de la '
    'famille.';

/// Le message affiché quand la connexion échoue : un titre et un conseil,
/// jamais le texte technique de l'exception (code, « Exception »), qui part
/// dans le rapport d'erreur.
@visibleForTesting
({String title, String? advice}) loginError(Object error) {
  final message = describeError(error);
  final accessDenied = describeError(
    FirebaseException(plugin: 'auth', code: 'permission-denied'),
  ).title;
  final unexpected = describeError(Object()).title;
  final ownAdvice =
      message.title != accessDenied && message.title != unexpected;
  return (
    title: message.title,
    advice: ownAdvice ? message.advice : kLoginErrorAdvice,
  );
}

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started || !kDebugMode || !_devAutoLogin) return;
    _started = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await ref.read(authRepositoryProvider).signInWithGoogle();
      } catch (error, stackTrace) {
        reportUnexpectedError(
          feature: 'loginScreen.didChangeDependencies',
          error: error,
          stackTrace: stackTrace,
          service: ref.read(errorReportServiceProvider),
        );
        // Laisse l'utilisateur utiliser le bouton manuel en cas d'échec popup.
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isRevoked =
        GoRouterState.of(context).uri.queryParameters['revoked'] == 'true';

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 400),
                  // Défile : sur un téléphone en paysage, ou avec une grande
                  // taille de police, le bouton de connexion sortait de l'écran.
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Image.asset('assets/Icon.png', width: 120, height: 120),
                        const SizedBox(height: 24),
                        Text(
                          "Kass'dalle",
                          style: Theme.of(context).textTheme.headlineLarge
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Votre Bibliothèque Gourmande',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 48),
                        if (isRevoked)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 24),
                            child: Card(
                              color: Theme.of(
                                context,
                              ).colorScheme.errorContainer,
                              child: Padding(
                                padding: const EdgeInsets.all(16),
                                child: Text(
                                  kRevokedLoginMessage,
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onErrorContainer,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        _GoogleSignInButton(
                          onSignIn: () async {
                            final repo = ref.read(authRepositoryProvider);
                            // Compte révoqué : nouvelle session, pour écrire
                            // `last_seen_at` et laisser choisir l'adresse
                            // invitée. L'écran se ferme seul quand l'accès
                            // revient (le routeur suit `appUserProvider`).
                            if (isRevoked) {
                              await repo.signInAgainAfterRevocation();
                            } else {
                              await repo.signInWithGoogle();
                            }
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Sous le contenu, pas en surimpression : en paysage, le contenu
            // qui défile ne passe pas sous les liens du pied de page.
            const AuthScreenFooter(),
          ],
        ),
      ),
    );
  }
}

class _GoogleSignInButton extends ConsumerStatefulWidget {
  final Future<void> Function() onSignIn;
  const _GoogleSignInButton({required this.onSignIn});

  @override
  ConsumerState<_GoogleSignInButton> createState() =>
      _GoogleSignInButtonState();
}

class _GoogleSignInButtonState extends ConsumerState<_GoogleSignInButton> {
  bool _loading = false;
  ({String title, String? advice})? _error;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_error case final error?)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      error.title,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                    if (error.advice != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        error.advice!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onErrorContainer,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ConstrainedBox(
          // Hauteur minimale : avec une grande police, le libellé grandit.
          constraints: const BoxConstraints(
            minWidth: double.infinity,
            minHeight: 52,
          ),
          child: OutlinedButton.icon(
            onPressed: _loading
                ? null
                : () async {
                    setState(() {
                      _loading = true;
                      _error = null;
                    });
                    try {
                      await widget.onSignIn().timeout(
                        const Duration(seconds: 30),
                        onTimeout: () {
                          throw TimeoutException(
                            'La connexion a dépassé le délai d\'attente. Vérifiez votre connexion réseau.',
                          );
                        },
                      );
                    } on TimeoutException catch (e, stackTrace) {
                      reportUnexpectedError(
                        feature: 'loginScreen.build',
                        error: e,
                        stackTrace: stackTrace,
                        service: ref.read(errorReportServiceProvider),
                      );
                      if (mounted) {
                        setState(
                          () => _error = (
                            title: e.message ?? describeError(e).title,
                            advice: null,
                          ),
                        );
                      }
                    } catch (e, stackTrace) {
                      reportUnexpectedError(
                        feature: 'loginScreen.build',
                        error: e,
                        stackTrace: stackTrace,
                        service: ref.read(errorReportServiceProvider),
                      );
                      if (mounted) {
                        setState(() => _error = loginError(e));
                      }
                    } finally {
                      if (mounted) setState(() => _loading = false);
                    }
                  },
            icon: _loading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.login),
            label: const Text('Continuer avec Google'),
          ),
        ),
      ],
    );
  }
}
