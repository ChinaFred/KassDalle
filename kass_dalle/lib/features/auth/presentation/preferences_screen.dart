import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/services/error_reporting.dart';
import '../data/user_preferences_repository.dart';

/// Les réglages du compte, rassemblés en un endroit.
///
/// Ils vivaient dispersés : la planification enterrée dans l'écran de compte,
/// le reste nulle part. Un réglage qu'on ne trouve pas est un réglage qui
/// n'existe pas, et l'entrée du menu vaut mieux qu'un sous-titre de carte.
class PreferencesScreen extends ConsumerStatefulWidget {
  const PreferencesScreen({super.key});

  @override
  ConsumerState<PreferencesScreen> createState() => _PreferencesScreenState();
}

class _PreferencesScreenState extends ConsumerState<PreferencesScreen> {
  bool _saving = false;

  Future<void> _setImportIllustrations(bool value) async {
    setState(() => _saving = true);
    try {
      await ref
          .read(userPreferencesRepositoryProvider)
          .setImportIllustrations(value);
      ref.invalidate(userPreferencesProvider);
      if (!mounted) return;
      context.showSuccessSnackBar('Préférence enregistrée.');
    } catch (error, stackTrace) {
      reportUnexpectedError(
        feature: 'account.setImportIllustrations',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      context.showErrorSnackBar('Enregistrement impossible : $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preferences = ref.watch(userPreferencesProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Préférences')),
      body: preferences.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => AppErrorState(
          error: error,
          title: 'Préférences illisibles',
          onRetry: () => ref.invalidate(userPreferencesProvider),
        ),
        data: (value) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Import de livres', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: SwitchListTile(
                value: value.importIllustrations,
                onChanged: _saving ? null : _setImportIllustrations,
                title: const Text('Extraire les illustrations des pages'),
                subtitle: const Text(
                  'Repère les photos et dessins d\'une page importée, les '
                  'découpe et les attache à la recette. Ce réglage est le '
                  'défaut : chaque import peut le changer pour lui seul.',
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text('Planification', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.tune_outlined),
                title: const Text('Préférences de planification'),
                subtitle: const Text('Cycle, contraintes, Calendar'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppRoutes.planningConfig),
              ),
            ),
            const SizedBox(height: 8),
            Card(
              child: ListTile(
                leading: const Icon(Icons.rice_bowl_outlined),
                title: const Text('Mes garnitures'),
                subtitle: const Text(
                  'Riz, pâtes, salade, yaourt : la part par personne, à '
                  'votre main. Ne change rien pour les autres.',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push(AppRoutes.myStaples),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
