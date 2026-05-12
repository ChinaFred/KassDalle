import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'admin_providers.dart';
import '../../auth/domain/app_user.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../recipes/data/recipe_repository.dart';
import '../../recipes/presentation/recipe_providers.dart';
import '../../../core/services/gemini_service.dart';
import '../../search/presentation/search_providers.dart'
    show geminiServiceProvider;

class AdminScreen extends ConsumerStatefulWidget {
  const AdminScreen({super.key});

  @override
  ConsumerState<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends ConsumerState<AdminScreen> {
  bool _migrating = false;
  String _migrationStatus = '';
  int _migrationDone = 0;
  int _migrationTotal = 0;

  Future<void> _runMigration() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Migrer les types de plat ?'),
        content: const Text(
          'Cette opération va classifier toutes les recettes validées sans type de plat '
          'via Gemini et mettre à jour Firestore.\n\nCela peut prendre quelques minutes.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Lancer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _migrating = true;
      _migrationStatus = 'Chargement des recettes…';
      _migrationDone = 0;
      _migrationTotal = 0;
    });

    try {
      final recipeRepo = ref.read(recipeRepositoryProvider);
      final gemini = ref.read(geminiServiceProvider);

      // Charger toutes les recettes validées sans dish_types
      final all = await recipeRepo.fetchAllValidated();
      final toMigrate = all
          .where((r) => r.tags.dishTypes.isEmpty)
          .toList();

      if (toMigrate.isEmpty) {
        setState(() {
          _migrationStatus = 'Toutes les recettes ont déjà leurs types de plat !';
          _migrating = false;
        });
        return;
      }

      setState(() {
        _migrationTotal = toMigrate.length;
        _migrationStatus = 'Classification en cours…';
      });

      const batchSize = 30;
      final updates = <String, List<String>>{};

      for (var i = 0; i < toMigrate.length; i += batchSize) {
        final chunk = toMigrate.sublist(
          i,
          (i + batchSize).clamp(0, toMigrate.length),
        );
        final input = chunk
            .map(
              (r) => {
                'id': r.id,
                'titre': r.titre,
                'ingredients': r.ingredientsIndex.join(', '),
              },
            )
            .toList();

        final results = await gemini.classifyDishTypes(input);
        updates.addAll(results);

        setState(() {
          _migrationDone = (i + chunk.length).clamp(0, toMigrate.length);
          _migrationStatus =
              '$_migrationDone / $_migrationTotal recettes classifiées…';
        });
      }

      // Écriture en lot dans Firestore
      await recipeRepo.batchUpdateDishTypes(updates);

      setState(() {
        _migrationStatus =
            'Migration terminée ! ${updates.length} recettes mises à jour.';
        _migrating = false;
      });
    } catch (e) {
      setState(() {
        _migrationStatus = 'Erreur : $e';
        _migrating = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final usersAsync = ref.watch(allUsersProvider);
    final currentUser = ref.watch(appUserProvider).value;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Administration')),
      body: ListView(
        children: [
          // ── Section Migration ──────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(16),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.restaurant_outlined,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Types de plat',
                          style: theme.textTheme.titleMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Classifie automatiquement les recettes existantes '
                      '(viande, poisson, dessert…) via Gemini.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_migrating) ...[
                      LinearProgressIndicator(
                        value: _migrationTotal > 0
                            ? _migrationDone / _migrationTotal
                            : null,
                      ),
                      const SizedBox(height: 8),
                    ],
                    if (_migrationStatus.isNotEmpty)
                      Text(
                        _migrationStatus,
                        style: theme.textTheme.bodySmall,
                      ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: _migrating ? null : _runMigration,
                      icon: const Icon(Icons.auto_fix_high_outlined),
                      label: const Text('Migrer les types de plat'),
                    ),
                  ],
                ),
              ),
            ),
          ),

          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Utilisateurs',
              style: theme.textTheme.titleMedium,
            ),
          ),

          // ── Liste des utilisateurs ─────────────────────────────────────
          usersAsync.when(
            loading: () =>
                const Center(child: CircularProgressIndicator()),
            error: (e, _) => Center(child: Text('Erreur : $e')),
            data: (users) {
              if (users.isEmpty) {
                return const Center(child: Text('Aucun utilisateur.'));
              }
              return Column(
                children: [
                  for (var i = 0; i < users.length; i++) ...[
                    _UserTile(
                      user: users[i],
                      isSelf: users[i].uid == currentUser?.uid,
                    ),
                    if (i < users.length - 1) const Divider(height: 1),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _UserTile extends ConsumerWidget {
  final AppUser user;
  final bool isSelf;
  const _UserTile({required this.user, required this.isSelf});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return ListTile(
      leading: _UserAvatar(user: user, radius: 22),
      title: Row(
        children: [
          Expanded(
            child: Text(
              user.displayName,
              style: theme.textTheme.bodyLarge?.copyWith(
                decoration: user.isRevoked
                    ? TextDecoration.lineThrough
                    : TextDecoration.none,
                color: user.isRevoked ? theme.disabledColor : null,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _RoleChip(role: user.role),
          if (user.isRevoked)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Chip(
                label: const Text('Révoqué'),
                backgroundColor: theme.colorScheme.errorContainer,
                labelStyle: TextStyle(
                  color: theme.colorScheme.onErrorContainer,
                  fontSize: 11,
                ),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
            ),
        ],
      ),
      subtitle: Text(user.email),
      trailing: isSelf
          ? const Tooltip(
              message: 'Votre compte',
              child: Icon(Icons.person, size: 20),
            )
          : _UserActionsMenu(user: user),
      onTap: () => showDialog(
        context: context,
        builder: (_) => _UserDetailDialog(user: user, isSelf: isSelf),
      ),
    );
  }
}

class _UserActionsMenu extends ConsumerWidget {
  final AppUser user;
  const _UserActionsMenu({required this.user});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(adminRepositoryProvider);

    return PopupMenuButton<_Action>(
      icon: const Icon(Icons.more_vert),
      onSelected: (action) => _handleAction(context, ref, repo, action),
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: _Action.setReader,
          child: ListTile(
            leading: Icon(Icons.visibility),
            title: Text('Lecteur'),
            dense: true,
          ),
        ),
        const PopupMenuItem(
          value: _Action.setEditor,
          child: ListTile(
            leading: Icon(Icons.edit),
            title: Text('Éditeur'),
            dense: true,
          ),
        ),
        const PopupMenuItem(
          value: _Action.setAdmin,
          child: ListTile(
            leading: Icon(Icons.admin_panel_settings),
            title: Text('Administrateur'),
            dense: true,
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: user.isRevoked ? _Action.unrevoke : _Action.revoke,
          child: ListTile(
            leading: Icon(
              user.isRevoked ? Icons.lock_open : Icons.block,
              color: user.isRevoked ? Colors.green : Colors.red,
            ),
            title: Text(
              user.isRevoked ? 'Rétablir l\'accès' : 'Révoquer l\'accès',
              style: TextStyle(
                color: user.isRevoked ? Colors.green : Colors.red,
              ),
            ),
            dense: true,
          ),
        ),
      ],
    );
  }

  Future<void> _handleAction(
    BuildContext context,
    WidgetRef ref,
    dynamic repo,
    _Action action,
  ) async {
    try {
      switch (action) {
        case _Action.setReader:
          await repo.updateRole(user.uid, UserRole.reader);
        case _Action.setEditor:
          await repo.updateRole(user.uid, UserRole.editor);
        case _Action.setAdmin:
          await _confirmSetAdmin(context, repo);
        case _Action.revoke:
          await _confirmRevoke(context, repo);
        case _Action.unrevoke:
          await repo.setRevoked(user.uid, revoked: false);
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Erreur : $e')));
      }
    }
  }

  Future<void> _confirmSetAdmin(BuildContext context, dynamic repo) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Promouvoir en administrateur ?'),
        content: Text(
          '${user.displayName} aura accès à toutes les fonctions d\'administration.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirmer'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await repo.updateRole(user.uid, UserRole.admin);
    }
  }

  Future<void> _confirmRevoke(BuildContext context, dynamic repo) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Révoquer l\'accès ?'),
        content: Text('${user.displayName} ne pourra plus se connecter.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Révoquer'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await repo.setRevoked(user.uid, revoked: true);
    }
  }
}

enum _Action { setReader, setEditor, setAdmin, revoke, unrevoke }

// ── Avatar utilisateur ────────────────────────────────────────────────────────

class _UserAvatar extends StatelessWidget {
  final AppUser user;
  final double radius;
  const _UserAvatar({required this.user, this.radius = 22});

  @override
  Widget build(BuildContext context) {
    final url = user.photoUrl;
    if (url != null && url.isNotEmpty) {
      return ClipOval(
        child: CachedNetworkImage(
          imageUrl: url,
          width: radius * 2,
          height: radius * 2,
          fit: BoxFit.cover,
          placeholder: (_, _) => _initials(context),
          errorWidget: (_, _, _) => _initials(context),
        ),
      );
    }
    return _initials(context);
  }

  Widget _initials(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      child: Text(
        user.displayName.isNotEmpty ? user.displayName[0].toUpperCase() : '?',
        style: TextStyle(fontSize: radius * 0.8),
      ),
    );
  }
}

// ── Dialogue de détail d'un utilisateur ───────────────────────────────────────

class _UserDetailDialog extends StatelessWidget {
  final AppUser user;
  final bool isSelf;
  const _UserDetailDialog({required this.user, required this.isSelf});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _UserAvatar(user: user, radius: 40),
            const SizedBox(height: 12),
            Text(
              user.displayName,
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            if (isSelf)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Votre compte',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            const SizedBox(height: 16),
            _DetailRow(Icons.email_outlined, 'Email', user.email),
            _DetailRow(
              Icons.admin_panel_settings_outlined,
              'Rôle',
              _roleLabel(user.role),
            ),
            _DetailRow(
              Icons.calendar_today_outlined,
              'Membre depuis',
              _fmt(user.createdAt),
            ),
            _DetailRow(
              Icons.access_time_outlined,
              'Dernière activité',
              _fmt(user.lastSeenAt),
            ),
            if (user.isRevoked)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Chip(
                  label: const Text('Accès révoqué'),
                  backgroundColor: theme.colorScheme.errorContainer,
                  labelStyle: TextStyle(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Fermer'),
        ),
      ],
    );
  }

  String _roleLabel(UserRole role) => switch (role) {
    UserRole.admin => 'Administrateur',
    UserRole.editor => 'Éditeur',
    UserRole.reader => 'Lecteur',
  };

  String _fmt(DateTime dt) =>
      '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  const _DetailRow(this.icon, this.label, this.value);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Text(
            '$label : ',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}

class _RoleChip extends StatelessWidget {
  final UserRole role;
  const _RoleChip({required this.role});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, bg, fg) = switch (role) {
      UserRole.admin => (
        'Admin',
        theme.colorScheme.errorContainer,
        theme.colorScheme.onErrorContainer,
      ),
      UserRole.editor => (
        'Éditeur',
        theme.colorScheme.primaryContainer,
        theme.colorScheme.onPrimaryContainer,
      ),
      UserRole.reader => (
        'Lecteur',
        theme.colorScheme.secondaryContainer,
        theme.colorScheme.onSecondaryContainer,
      ),
    };

    return Chip(
      label: Text(label),
      backgroundColor: bg,
      labelStyle: TextStyle(color: fg, fontSize: 11),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }
}
