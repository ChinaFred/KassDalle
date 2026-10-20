import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/presentation/leave_guard.dart';
import '../../../core/router/app_router.dart';
import '../../../core/widgets/app_states.dart';
import '../domain/app_user.dart';
import 'auth_providers.dart';
import 'preferred_name_dialog.dart';
import '../../../core/theme/app_icon_size.dart';

/// Conseil d'un refus de lecture de son propre profil.
const kProfileDeniedAdvice =
    'Déconnectez-vous puis reconnectez-vous. Si le problème persiste, '
    'signalez-le depuis le menu du compte.';

bool _isPermissionDenied(Object? error) =>
    error is FirebaseException && error.code == 'permission-denied';

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(appUserProvider);
    final user = userAsync.value;
    final isAdmin = ref.watch(isAdminProvider);
    final hasPhoto = (user?.photoUrl ?? '').isNotEmpty;

    return Scaffold(
      appBar: AppBar(title: const Text('Profil et compte')),
      body: user == null
          // Une lecture du profil en échec ne laisse plus la roue tourner :
          // l'erreur s'affiche, avec « Réessayer ».
          ? (userAsync.hasError
                ? AppErrorState(
                    error: userAsync.error,
                    title: 'Profil non chargé',
                    // Le conseil par défaut d'un refus parle d'un livre : pour
                    // son propre profil, c'est la session qu'il faut refaire.
                    advice: _isPermissionDenied(userAsync.error)
                        ? kProfileDeniedAdvice
                        : null,
                    onRetry: () => ref.invalidate(appUserProvider),
                  )
                : const AppLoadingState(label: 'Chargement du profil…'))
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundImage: hasPhoto
                          ? NetworkImage(user.photoUrl!)
                          : null,
                      child: hasPhoto ? null : Text(user.initial),
                    ),
                    title: Text(
                      // Un compte Google sans nom : le nom affiché partout.
                      user.displayName.trim().isEmpty
                          ? user.displayedName
                          : user.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(user.email),
                    trailing: Chip(label: Text(userRoleLabel(user.role))),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Column(
                    children: [
                      // Les réglages ont quitté cet écran pour Préférences, qui
                      // a maintenant son entrée de menu. Le raccourci reste :
                      // on vient encore les chercher ici par habitude.
                      ListTile(
                        leading: const Icon(Icons.tune_outlined),
                        title: const Text('Préférences'),
                        subtitle: const Text(
                          'Thème, import des illustrations, planification',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.push(AppRoutes.preferences),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Column(
                    children: [
                      const ListTile(
                        leading: Icon(Icons.badge_outlined),
                        title: Text('Identité'),
                      ),
                      _InfoRow(
                        label: 'Nom du compte Google',
                        value: user.displayName.trim().isEmpty
                            ? 'Aucun nom'
                            : user.displayName,
                      ),
                      // Le nom Google revient à chaque connexion et n'est pas
                      // modifiable ici. Le nom préféré, lui, est le seul que
                      // la famille voit sur les bibliothèques.
                      ListTile(
                        dense: true,
                        title: const Text('Nom préféré'),
                        subtitle: Text(user.displayedName),
                        trailing: const Icon(Icons.edit_outlined),
                        onTap: () =>
                            showPreferredNameDialog(context, ref, user),
                      ),
                      _InfoRow(label: 'Adresse e-mail', value: user.email),
                      // L'identifiant technique ne sert qu'à l'administrateur,
                      // qui le recoupe avec les journaux et les rapports.
                      if (isAdmin)
                        _InfoRow(
                          label: 'Identifiant du compte',
                          value: user.uid,
                        ),
                      _InfoRow(
                        label: 'Photo de profil',
                        value: hasPhoto
                            ? 'Photo du compte Google'
                            : 'Aucune photo',
                      ),
                      const Divider(height: 1),
                      const ListTile(
                        leading: Icon(Icons.shield_outlined),
                        title: Text('Accès et permissions'),
                      ),
                      _InfoRow(label: 'Rôle', value: userRoleLabel(user.role)),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _PermissionChip(
                              label: 'Lecture',
                              enabled: user.canRead,
                            ),
                            _PermissionChip(
                              label: 'Édition',
                              enabled: user.canEdit,
                            ),
                            _PermissionChip(
                              label: 'Administration',
                              enabled: user.isAdmin,
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      const ListTile(
                        leading: Icon(Icons.schedule_outlined),
                        title: Text('Activité du compte'),
                      ),
                      _InfoRow(
                        label: 'Compte créé le',
                        value: _formatDateTime(user.createdAt),
                      ),
                      _InfoRow(
                        label: 'Dernière activité',
                        value: _formatDateTime(user.lastSeenAt),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.logout),
                        title: const Text('Se déconnecter'),
                        onTap: () => signOutGuarded(context, ref),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

String _formatDateTime(DateTime dt) {
  final day = dt.day.toString().padLeft(2, '0');
  final month = dt.month.toString().padLeft(2, '0');
  final year = dt.year.toString();
  final hour = dt.hour.toString().padLeft(2, '0');
  final minute = dt.minute.toString().padLeft(2, '0');
  return '$day/$month/$year $hour:$minute';
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;

  const _InfoRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      title: Text(label),
      subtitle: SelectableText(value),
    );
  }
}

class _PermissionChip extends StatelessWidget {
  final String label;
  final bool enabled;

  const _PermissionChip({required this.label, required this.enabled});

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: Icon(
        enabled ? Icons.check_circle_outline : Icons.block,
        size: AppIconSize.inline,
      ),
      label: Text(label),
      backgroundColor: enabled
          ? Theme.of(context).colorScheme.secondaryContainer
          : Theme.of(context).colorScheme.surfaceContainerHighest,
    );
  }
}
