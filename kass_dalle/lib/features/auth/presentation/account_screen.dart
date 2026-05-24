import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/router/app_router.dart';
import 'auth_providers.dart';

class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(appUserProvider).value;

    return Scaffold(
      appBar: AppBar(title: const Text('Profil et compte')),
      body: user == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundImage: user.photoUrl != null
                          ? NetworkImage(user.photoUrl!)
                          : null,
                      child: user.photoUrl == null
                          ? Text(user.displayName[0].toUpperCase())
                          : null,
                    ),
                    title: Text(
                      user.displayName,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(user.email),
                    trailing: Chip(label: Text(user.role.name.toUpperCase())),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.tune_outlined),
                        title: const Text('Préférences de planification'),
                        subtitle: const Text('Cycle, contraintes, Calendar'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.push(AppRoutes.planningConfig),
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
                        title: Text('Identite'),
                      ),
                      _InfoRow(label: 'Nom affiche', value: user.displayName),
                      _InfoRow(label: 'Email', value: user.email),
                      _InfoRow(label: 'UID', value: user.uid),
                      _InfoRow(
                        label: 'Photo de profil',
                        value: user.photoUrl ?? 'Aucune photo',
                      ),
                      const Divider(height: 1),
                      const ListTile(
                        leading: Icon(Icons.shield_outlined),
                        title: Text('Acces et permissions'),
                      ),
                      _InfoRow(label: 'Role', value: user.role.name),
                      _InfoRow(
                        label: 'Compte revoque',
                        value: user.isRevoked ? 'Oui' : 'Non',
                      ),
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
                              label: 'Edition',
                              enabled: user.canEdit,
                            ),
                            _PermissionChip(
                              label: 'Admin',
                              enabled: user.isAdmin,
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      const ListTile(
                        leading: Icon(Icons.schedule_outlined),
                        title: Text('Activite du compte'),
                      ),
                      _InfoRow(
                        label: 'Compte cree le',
                        value: _formatDateTime(user.createdAt),
                      ),
                      _InfoRow(
                        label: 'Derniere activite',
                        value: _formatDateTime(user.lastSeenAt),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.logout),
                        title: const Text('Se deconnecter'),
                        onTap: () => ref.read(authRepositoryProvider).signOut(),
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
        size: 16,
      ),
      label: Text(label),
      backgroundColor: enabled
          ? Theme.of(context).colorScheme.secondaryContainer
          : Theme.of(context).colorScheme.surfaceContainerHighest,
    );
  }
}
