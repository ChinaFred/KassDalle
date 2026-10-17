import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../auth/presentation/auth_providers.dart';
import '../domain/family_group.dart';
import 'group_providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/utils/context_extensions.dart';

class GroupsScreen extends ConsumerWidget {
  const GroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(myGroupsProvider);
    final invitationsAsync = ref.watch(myInvitationsProvider);
    // Les groupes en pause (propriétaire qui n'est plus éditeur) restent
    // listés, marqués « En pause » : leur propriétaire en retire des membres
    // ou les supprime, un membre les quitte. Une portée illisible ne marque
    // rien (l'erreur est déjà au rapport).
    final maskedAsync = ref.watch(maskedGroupIdsProvider);
    final pausedIds = maskedAsync.value ?? const <String>{};
    final myUid = ref.watch(appUserProvider).value?.uid ?? '';
    // Créer un groupe demande le rôle éditeur (règle `create` de `groups`) :
    // un lecteur rejoint un groupe sur invitation d'un proche.
    final canCreate = ref.watch(canEditProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Groupes familiaux')),
      body: (!maskedAsync.hasValue && !maskedAsync.hasError)
          ? const AppLoadingState()
          : groupsAsync.when(
              loading: () => const AppLoadingState(),
              error: (e, _) => AppErrorState(
                error: e,
                onRetry: () => ref.invalidate(myGroupsProvider),
              ),
              data: (groups) {
                // Les invitations ont leur propre flux : en chargement, la section
                // n'apparaît pas ; en erreur, un encart, et le reste de l'écran sert.
                final invitations =
                    invitationsAsync.value ?? const <FamilyGroup>[];
                if (groups.isEmpty &&
                    invitations.isEmpty &&
                    !invitationsAsync.hasError) {
                  if (!canCreate) {
                    return const AppEmptyState(
                      icon: Icons.group_outlined,
                      title: 'Aucun groupe familial',
                      message:
                          'Vous rejoignez un groupe sur invitation d\'un proche. '
                          'Ses invitations apparaîtront ici.',
                    );
                  }
                  return AppEmptyState(
                    icon: Icons.group_outlined,
                    title: 'Aucun groupe familial',
                    message:
                        'Créez un groupe, ou attendez qu\'un proche vous invite '
                        'dans le sien. Ses invitations apparaîtront ici.',
                    action: FilledButton.icon(
                      onPressed: () => _showCreateGroupDialog(context, ref),
                      icon: const Icon(Icons.add),
                      label: const Text('Créer un groupe'),
                    ),
                  );
                }

                final textTheme = Theme.of(context).textTheme;
                Widget header(String text) => Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(text, style: textTheme.titleSmall),
                );

                return ListView(
                  padding: EdgeInsets.only(top: 8, bottom: canCreate ? 88 : 16),
                  children: [
                    if (invitationsAsync.hasError)
                      AppErrorState(
                        compact: true,
                        error: invitationsAsync.error,
                        title: 'Invitations illisibles',
                        onRetry: () => ref.invalidate(myInvitationsProvider),
                      ),
                    if (invitations.isNotEmpty) ...[
                      header('Invitations reçues'),
                      for (final group in invitations)
                        _InvitationCard(group: group, myUid: myUid),
                      header('Mes groupes'),
                    ],
                    if (groups.isEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                        child: Text(
                          'Vous ne faites partie d\'aucun groupe pour l\'instant.',
                          style: textTheme.bodySmall,
                        ),
                      ),
                    for (var i = 0; i < groups.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      _GroupTile(
                        group: groups[i],
                        myUid: myUid,
                        paused: pausedIds.contains(groups[i].id),
                      ),
                    ],
                  ],
                );
              },
            ),
      floatingActionButton: canCreate
          ? FloatingActionButton.extended(
              onPressed: () => _showCreateGroupDialog(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('Créer un groupe'),
            )
          : null,
    );
  }

  void _showCreateGroupDialog(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (_) => _CreateGroupDialog(ref: ref),
    );
  }
}

// ── Tuile d'un groupe ──────────────────────────────────────────────────────────

class _GroupTile extends ConsumerWidget {
  final FamilyGroup group;
  final String myUid;

  /// Le propriétaire n'est plus éditeur : le groupe est masqué dans le
  /// planning, et la tuile le dit (« En pause · … »).
  final bool paused;

  const _GroupTile({
    required this.group,
    required this.myUid,
    this.paused = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOwner = group.isOwner(myUid);
    // Renommer demande aussi le rôle éditeur (`isManagement` de
    // `firestore.rules`) : un lecteur propriétaire d'un groupe créé avant
    // v0.23.54 ne garde que ce qui réduit son groupe.
    final canManage = isOwner && ref.watch(canEditProvider);
    // Les invitations par e-mail ne se lisent que pour un groupe possédé :
    // la règle Firestore refuse la requête à un autre membre.
    final emailPending = isOwner
        ? pendingEmailInvitations(
            ref.watch(groupEmailInvitationsProvider(group.id)).value ??
                const [],
            DateTime.now(),
          ).length
        : 0;
    final pendingCount = group.invitedIds.length + emailPending;
    return ListTile(
      leading: CircleAvatar(child: Text(group.name[0].toUpperCase())),
      title: Text(group.name),
      subtitle: Text(
        [
          if (paused) 'En pause',
          '${group.memberIds.length} membre(s)',
          if (isOwner && pendingCount > 0)
            '$pendingCount invitation(s) en attente',
        ].join(' · '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canManage)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Renommer',
              onPressed: () => _showRenameDialog(context, ref, group),
            ),
          PopupMenuButton<_GroupAction>(
            onSelected: (action) async {
              switch (action) {
                case _GroupAction.manageMembers:
                  context.push(AppRoutes.groupMembersPath(group.id));
                  break;
                case _GroupAction.leave:
                  await _leaveGroup(context, ref, group);
                  break;
                case _GroupAction.delete:
                  await _deleteGroup(context, ref, group);
                  break;
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: _GroupAction.manageMembers,
                child: ListTile(
                  leading: const Icon(Icons.people_outline),
                  title: Text(
                    isOwner ? 'Gérer les membres' : 'Voir les membres',
                  ),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (!isOwner)
                const PopupMenuItem(
                  value: _GroupAction.leave,
                  child: ListTile(
                    leading: Icon(Icons.exit_to_app),
                    title: Text('Quitter le groupe'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              if (isOwner)
                const PopupMenuItem(
                  value: _GroupAction.delete,
                  child: ListTile(
                    leading: Icon(Icons.delete_outline),
                    title: Text('Supprimer le groupe'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
            ],
          ),
        ],
      ),
      onTap: () => context.push(AppRoutes.groupMembersPath(group.id)),
    );
  }

  void _showRenameDialog(
    BuildContext context,
    WidgetRef ref,
    FamilyGroup group,
  ) {
    showDialog<void>(
      context: context,
      builder: (_) => _RenameGroupDialog(group: group, ref: ref),
    );
  }

  Future<void> _leaveGroup(
    BuildContext context,
    WidgetRef ref,
    FamilyGroup group,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Quitter "${group.name}" ?'),
        content: const Text(
          'Vous ne verrez plus les livres et recettes de ce groupe.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Quitter'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(groupRepositoryProvider).removeMember(group.id, myUid);
    } catch (e) {
      if (context.mounted) context.showErrorSnackBar('Sortie impossible : $e');
    }
  }

  Future<void> _deleteGroup(
    BuildContext context,
    WidgetRef ref,
    FamilyGroup group,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Supprimer "${group.name}" ?'),
        content: const Text(
          'Tous les membres perdront accès aux livres partagés via ce groupe.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      await ref.read(groupRepositoryProvider).deleteGroup(group.id);
    } catch (e) {
      if (context.mounted) {
        context.showErrorSnackBar('Suppression impossible : $e');
      }
    }
  }
}

enum _GroupAction { manageMembers, leave, delete }

// ── Invitation reçue ───────────────────────────────────────────────────────────

/// Une invitation dans un groupe, vue par l'invité.
///
/// Accepter demande une confirmation qui dit ce qui sera partagé : entrer
/// dans un groupe ouvre ses livres et recettes non privés aux autres membres.
/// Refuser part sans confirmation : un refus n'expose rien, et le
/// propriétaire peut réinviter.
class _InvitationCard extends ConsumerStatefulWidget {
  final FamilyGroup group;
  final String myUid;

  const _InvitationCard({required this.group, required this.myUid});

  @override
  ConsumerState<_InvitationCard> createState() => _InvitationCardState();
}

class _InvitationCardState extends ConsumerState<_InvitationCard> {
  /// Une réponse est en cours : les deux boutons sont désactivés, sans quoi
  /// un double appui enverrait une seconde écriture que la règle refuserait.
  bool _busy = false;

  FamilyGroup get group => widget.group;

  String _sharingNotice() {
    final n = group.memberIds.length;
    final who = n == 1
        ? 'Le membre de ce groupe verra'
        : 'Les $n membres de ce groupe verront';
    return '$who vos livres et recettes, sauf ceux que vous avez rendus '
        'privés. Vous verrez aussi les ${n == 1 ? 'siens' : 'leurs'}. '
        'Vous pourrez quitter le groupe à tout moment.';
  }

  Future<void> _respond(
    Future<void> Function() write, {
    required String success,
    required String failure,
  }) async {
    setState(() => _busy = true);
    try {
      await write();
      if (!mounted) return;
      context.showSuccessSnackBar(success);
    } catch (_) {
      // Signalée au rapport d'erreurs par GroupRepository.
      if (!mounted) return;
      context.showErrorSnackBar(failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Rejoindre « ${group.name} » ?'),
        content: Text(_sharingNotice()),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Rejoindre'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _respond(
      () => ref
          .read(groupRepositoryProvider)
          .acceptInvitation(group.id, widget.myUid),
      success: 'Vous avez rejoint « ${group.name} »',
      failure: 'Impossible de rejoindre le groupe. Réessayez.',
    );
  }

  Future<void> _refuse() => _respond(
    () => ref
        .read(groupRepositoryProvider)
        .withdrawInvitation(group.id, widget.myUid),
    success: 'Invitation refusée',
    failure: 'Impossible de refuser l\'invitation. Réessayez.',
  );

  @override
  Widget build(BuildContext context) {
    final owner = ref.watch(memberNameProvider(group.ownerId));
    final members = '${group.memberIds.length} membre(s)';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ListTile(
            leading: CircleAvatar(
              child: Text(
                group.name.isNotEmpty ? group.name[0].toUpperCase() : '?',
              ),
            ),
            title: Text(group.name),
            subtitle: Text(
              owner == null ? members : '$members · invitation de $owner',
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            child: OverflowBar(
              alignment: MainAxisAlignment.end,
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _busy ? null : _refuse,
                  child: const Text('Refuser'),
                ),
                FilledButton(
                  onPressed: _busy ? null : _accept,
                  child: const Text('Accepter'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Dialog création de groupe ──────────────────────────────────────────────────

class _CreateGroupDialog extends ConsumerStatefulWidget {
  final WidgetRef ref;
  const _CreateGroupDialog({required this.ref});

  @override
  ConsumerState<_CreateGroupDialog> createState() => _CreateGroupDialogState();
}

class _CreateGroupDialogState extends ConsumerState<_CreateGroupDialog> {
  final _controller = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Créer un groupe familial'),
      content: TextField(
        controller: _controller,
        // Les règles Firestore refusent un nom de plus de 60 caractères.
        maxLength: 60,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Nom du groupe',
          hintText: 'ex : Famille Dupont',
        ),
        onSubmitted: (_) => _save(context),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _saving ? null : () => _save(context),
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Créer'),
        ),
      ],
    );
  }

  Future<void> _save(BuildContext context) async {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    setState(() => _saving = true);
    try {
      final myUid = ref.read(appUserProvider).value?.uid;
      if (myUid == null) return;
      await ref.read(groupRepositoryProvider).createGroup(name, myUid);
      if (context.mounted) Navigator.pop(context);
    } catch (e) {
      if (context.mounted) {
        context.showErrorSnackBar('Création impossible : $e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

// ── Dialog renommage ───────────────────────────────────────────────────────────

class _RenameGroupDialog extends ConsumerStatefulWidget {
  final FamilyGroup group;
  final WidgetRef ref;
  const _RenameGroupDialog({required this.group, required this.ref});

  @override
  ConsumerState<_RenameGroupDialog> createState() => _RenameGroupDialogState();
}

class _RenameGroupDialogState extends ConsumerState<_RenameGroupDialog> {
  late final TextEditingController _controller;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.group.name);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Renommer le groupe'),
      content: TextField(
        controller: _controller,
        // Les règles Firestore refusent un nom de plus de 60 caractères.
        maxLength: 60,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Nouveau nom'),
        onSubmitted: (_) => _save(context),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: _saving ? null : () => _save(context),
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }

  Future<void> _save(BuildContext context) async {
    final name = _controller.text.trim();
    if (name.isEmpty) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(groupRepositoryProvider)
          .renameGroup(widget.group.id, name);
      if (context.mounted) Navigator.pop(context);
    } catch (e) {
      if (context.mounted) {
        context.showErrorSnackBar('Renommage impossible : $e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
