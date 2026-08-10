import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'auth_providers.dart';
import '../../../core/app_version.dart';
import '../../../core/services/error_reporting.dart';

const _devAutoLogin = bool.fromEnvironment(
  'DEV_AUTO_LOGIN',
  defaultValue: true,
);

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
        child: Stack(
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
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
                            color: Theme.of(context).colorScheme.errorContainer,
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Text(
                                "Votre accès a été révoqué. Contactez l'administrateur.",
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
                          await repo.signInWithGoogle();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 8,
              child: Center(
                child: Text(
                  'v$kAppVersion',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withValues(alpha: 0.35),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GoogleSignInButton extends StatefulWidget {
  final Future<void> Function() onSignIn;
  const _GoogleSignInButton({required this.onSignIn});

  @override
  State<_GoogleSignInButton> createState() => _GoogleSignInButtonState();
}

class _GoogleSignInButtonState extends State<_GoogleSignInButton> {
  bool _loading = false;
  String? _errorMessage;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_errorMessage != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Card(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  _errorMessage!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onErrorContainer,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
        SizedBox(
          width: double.infinity,
          height: 52,
          child: OutlinedButton.icon(
            onPressed: _loading
                ? null
                : () async {
                    setState(() {
                      _loading = true;
                      _errorMessage = null;
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
                      );
                      if (mounted) {
                        setState(() => _errorMessage = e.message);
                      }
                    } catch (e, stackTrace) {
                      reportUnexpectedError(
                        feature: 'loginScreen.build',
                        error: e,
                        stackTrace: stackTrace,
                      );
                      if (mounted) {
                        setState(
                          () => _errorMessage =
                              'Erreur de connexion: ${e.toString()}',
                        );
                      }
                      debugPrint('Login error: $e');
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
