import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/error_reporting.dart';
import '../../../core/utils/context_extensions.dart';
import '../data/app_check_repository.dart';
import 'admin_providers.dart';

/// Attestation de l'application — App Check.
///
/// Le reste du contrôle d'accès vérifie *qui* appelle. Celui-ci vérifie *quoi* :
/// une callable est une URL HTTPS publique, et un jeton d'identité se recopie.
/// Sans attestation, l'application et une boucle dans un terminal sont
/// indiscernables côté serveur — or chaque appel part chez Gemini ou Anthropic.
///
/// Le mode se change ici et non par un déploiement : le jour où l'attestation
/// refuse à tort, il faut rouvrir en une minute.
class AppCheckScreen extends ConsumerStatefulWidget {
  const AppCheckScreen({super.key});

  @override
  ConsumerState<AppCheckScreen> createState() => _AppCheckScreenState();
}

class _AppCheckScreenState extends ConsumerState<AppCheckScreen> {
  AppCheckSnapshot? _snapshot;
  Object? _loadError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snapshot = await ref.read(appCheckRepositoryProvider).fetch();
      if (!mounted) return;
      setState(() {
        _snapshot = snapshot;
        _loadError = null;
      });
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'admin.fetchAppCheckPolicy',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() => _loadError = error);
    }
  }

  Future<void> _apply(AppCheckMode mode) async {
    if (mode == AppCheckMode.enforce && !await _confirmEnforce()) return;
    setState(() => _saving = true);
    try {
      final saved = await ref.read(appCheckRepositoryProvider).save(mode);
      if (!mounted) return;
      setState(() => _snapshot = saved);
      context.showSuccessSnackBar('Politique App Check : ${mode.label}.');
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'admin.saveAppCheckPolicy',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      context.showErrorSnackBar('Changement impossible : $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmEnforce() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Exiger l\'attestation ?'),
        content: const Text(
          'Tout appel dont l\'application n\'est pas attestée sera refusé.\n\n'
          'Le client Windows desktop n\'atteste pas : sa seule voie est un jeton '
          'de débogage, c\'est-à-dire un secret partagé dans un binaire '
          'distribué. Il perdra donc toutes les fonctions d\'IA. Et cette limite '
          'ne se contourne pas par une exemption de plateforme : la plateforme '
          'est déclarée par le client, donc par un attaquant aussi.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Exiger'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final snapshot = _snapshot;

    return Scaffold(
      appBar: AppBar(title: const Text('Attestation de l\'application')),
      body: _loadError != null
          ? _ErrorState(error: _loadError!, onRetry: _load)
          : snapshot == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  color: snapshot.callerAttested
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(
                          snapshot.callerAttested
                              ? Icons.verified_user
                              : Icons.gpp_maybe,
                          color: snapshot.callerAttested
                              ? theme.colorScheme.onPrimaryContainer
                              : theme.colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            snapshot.callerAttested
                                ? 'Cet écran est attesté : l\'appel qui l\'a chargé portait un jeton App Check valide.'
                                : 'Cet écran n\'est pas attesté. Exiger l\'attestation maintenant vous mettrait '
                                      'dehors le premier — le serveur refusera d\'ailleurs le changement. '
                                      'Vérifiez la clé reCAPTCHA du client web et l\'enregistrement des '
                                      'applications dans la console Firebase.',
                            style: TextStyle(
                              color: snapshot.callerAttested
                                  ? theme.colorScheme.onPrimaryContainer
                                  : theme.colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Text('Mode', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Prend effet en moins d\'une minute, sur toutes les entrées '
                  'd\'IA et d\'administration à la fois.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 8),
                RadioGroup<AppCheckMode>(
                  groupValue: snapshot.mode,
                  // Un changement en cours d'enregistrement est ignoré plutôt
                  // que désactivé : `RadioGroup` n'accepte pas de rappel nul.
                  onChanged: (mode) {
                    if (mode == null || _saving) return;
                    _apply(mode);
                  },
                  child: Column(
                    children: [
                      for (final mode in AppCheckMode.values)
                        Card(
                          child: RadioListTile<AppCheckMode>(
                            value: mode,
                            title: Text(mode.label),
                            subtitle: Text(mode.description),
                            isThreeLine: true,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Comment lire l\'observation',
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'En mode Observation, chaque appel non attesté écrit un '
                          'avertissement dans Cloud Logging, avec le poste concerné et '
                          'l\'agent utilisateur de l\'appelant. Ces traces se filtrent '
                          'depuis l\'écran Cloud Logging (chip « WARN+ »). Tant qu\'il '
                          'en arrive, exiger l\'attestation couperait quelque chose : '
                          'ce sont elles qui disent quoi.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const _ErrorState({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 40),
            const SizedBox(height: 12),
            Text('Politique illisible : $error', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Réessayer'),
            ),
          ],
        ),
      ),
    );
  }
}
