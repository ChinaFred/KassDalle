import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/app_version.dart';
import '../../../core/services/error_reporting.dart';
import 'auth_providers.dart';

/// Le sas d'entrée, côté écran.
///
/// Un compte connecté mais pas encore nommé ne peut rien lire : sans cet écran,
/// il tomberait sur une bibliothèque vide semée d'erreurs de permission, sans
/// jamais apprendre qu'il lui manque seulement une approbation.
///
/// Il n'est pas renvoyé vers l'écran de connexion : il *est* connecté. L'y
/// renvoyer bouclerait — le routeur ramène tout compte authentifié vers
/// l'accueil — et lui suggérerait de se reconnecter, ce qui ne changera rien.
class PendingApprovalScreen extends ConsumerWidget {
  const PendingApprovalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final user = ref.watch(appUserProvider).value;

    return Scaffold(
      body: SafeArea(
        child: Stack(
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Image.asset('assets/Icon.png', width: 96, height: 96),
                      const SizedBox(height: 24),
                      Icon(
                        Icons.hourglass_top,
                        size: 40,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Votre compte attend son approbation',
                        style: theme.textTheme.titleLarge,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'La bibliothèque est privée. Un administrateur doit '
                        'vous nommer avant que vous puissiez y entrer.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      if (user != null) ...[
                        const SizedBox(height: 24),
                        Card(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            child: Column(
                              children: [
                                Text(
                                  user.displayName,
                                  style: theme.textTheme.bodyLarge,
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  user.email,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Communiquez cette adresse à l\'administrateur : '
                          'c\'est elle qu\'il verra dans sa liste.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: 32),
                      // L'approbation arrive par le flux temps réel du document
                      // utilisateur : cet écran se referme de lui-même. Le
                      // bouton n'existe que pour ceux qui n'y croiront pas.
                      OutlinedButton.icon(
                        onPressed: () => ref.invalidate(appUserProvider),
                        icon: const Icon(Icons.refresh),
                        label: const Text('Vérifier maintenant'),
                      ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: () async {
                          try {
                            await ref.read(authRepositoryProvider).signOut();
                          } catch (error, stackTrace) {
                            reportUnexpectedError(
                              feature: 'pendingApprovalScreen.signOut',
                              error: error,
                              stackTrace: stackTrace,
                            );
                          }
                        },
                        icon: const Icon(Icons.logout),
                        label: const Text('Se déconnecter'),
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
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.35),
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
