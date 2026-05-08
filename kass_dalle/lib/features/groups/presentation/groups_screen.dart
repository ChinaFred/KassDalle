import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/domain/app_user.dart';
import '../../auth/presentation/auth_providers.dart';
import '../domain/family_group.dart';
import 'group_providers.dart';

class GroupsScreen extends ConsumerWidget {
  const GroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(myGroupsProvider);
    final myUid = ref.watch(appUserProvider).valueOrNull?.uid ?? '';

    return Scaffold(
      appBar: AppBar(title: const Text('Groupes familiaux')),
      body: groupsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e')),
        data: (groups) {
          if (groups.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.group_outlined,
                    size: 64,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Aucun groupe familial',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () => _showCreateGroupDialog(context, ref),
                    icon: const Icon(Icons.add),
                    label: const Text('Créer un groupe'),
                  ),
                ],
              ),
            );
          }

          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: groups.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) =>
                _GroupTile(group: groups[i], myUid: myUid),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showCreateGroupDialog(context, ref),
        icon: const Icon(Icons.add),
        label: const Text('Créer un groupe'),
      ),
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

  const _GroupTile({required this.group, required this.myUid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isOwner = group.isOwner(myUid);
    return ListTile(
      leading: CircleAvatar(child: Text(group.name[0].toUpperCase())),
      title: Text(group.name),
      subtitle: Text('${group.memberIds.length} membre(s)'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isOwner)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Renommer',
              onPressed: () => _showRenameDialog(context, ref, group),
            ),
          PopupMenuButton<_GroupAction>(
            onSelected: (action) async {
              switch (action) {
                case _GroupAction.manageMembers:
                  _showManageMembersSheet(context, ref, group);
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
              const PopupMenuItem(
                value: _GroupAction.manageMembers,
                child: ListTile(
                  leading: Icon(Icons.people_outline),
                  title: Text('Gérer les membres'),
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
      onTap: () => _showManageMembersSheet(context, ref, group),
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

  void _showManageMembersSheet(
    BuildContext context,
    WidgetRef ref,
    FamilyGroup group,
  ) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ManageMembersSheet(group: group, myUid: myUid),
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
    await ref.read(groupRepositoryProvider).removeMember(group.id, myUid);
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
    await ref.read(groupRepositoryProvider).deleteGroup(group.id);
  }
}

enum _GroupAction { manageMembers, leave, delete }

// ── Feuille de gestion des membres ────────────────────────────────────────────

class _ManageMembersSheet extends ConsumerStatefulWidget {
  final FamilyGroup group;
  final String myUid;

  const _ManageMembersSheet({required this.group, required this.myUid});

  @override
  ConsumerState<_ManageMembersSheet> createState() =>
      _ManageMembersSheetState();
}

class _ManageMembersSheetState extends ConsumerState<_ManageMembersSheet> {
  final TextEditingController _searchController = TextEditingController();
  List<AppUser> _searchResults = [];
  bool _searching = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _searchResults = []);
      return;
    }
    setState(() => _searching = true);
    final results = await ref
        .read(groupRepositoryProvider)
        .searchUsers(query.trim());
    if (mounted) {
      setState(() {
        // Exclude current members
        _searchResults = results
            .where((u) => !widget.group.memberIds.contains(u.uid))
            .toList();
        _searching = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isOwner = widget.group.isOwner(widget.myUid);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.group.name,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                  ],
                ),
              ),
              if (isOwner) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SearchBar(
                    controller: _searchController,
                    hintText: 'Rechercher un utilisateur à inviter…',
                    leading: _searching
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search),
                    trailing: [
                      if (_searchController.text.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _searchResults = []);
                          },
                        ),
                    ],
                    onChanged: _search,
                  ),
                ),
                if (_searchResults.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    constraints: const BoxConstraints(maxHeight: 200),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: _searchResults.length,
                      itemBuilder: (context, i) {
                        final user = _searchResults[i];
                        return ListTile(
                          leading: CircleAvatar(
                            child: Text(user.displayName[0].toUpperCase()),
                          ),
                          title: Text(user.displayName),
                          subtitle: Text(user.email),
                          trailing: IconButton(
                            icon: const Icon(Icons.person_add_outlined),
                            tooltip: 'Ajouter au groupe',
                            onPressed: () async {
                              await ref
                                  .read(groupRepositoryProvider)
                                  .addMember(widget.group.id, user.uid);
                              _searchController.clear();
                              setState(() => _searchResults = []);
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      '${user.displayName} ajouté(e) au groupe',
                                    ),
                                  ),
                                );
                              }
                            },
                          ),
                        );
                      },
                    ),
                  ),
                ],
                const SizedBox(height: 8),
              ],
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Membres',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: scrollController,
                  itemCount: widget.group.memberIds.length,
                  itemBuilder: (context, i) {
                    final uid = widget.group.memberIds[i];
                    return _MemberTile(
                      uid: uid,
                      isOwner: widget.group.isOwner(uid),
                      canRemove: isOwner && uid != widget.myUid,
                      onRemove: () async {
                        await ref
                            .read(groupRepositoryProvider)
                            .removeMember(widget.group.id, uid);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MemberTile extends ConsumerWidget {
  final String uid;
  final bool isOwner;
  final bool canRemove;
  final VoidCallback onRemove;

  const _MemberTile({
    required this.uid,
    required this.isOwner,
    required this.canRemove,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(userByUidProvider(uid));
    final user = userAsync.valueOrNull;
    final name = user?.displayName ?? '…';
    final email = user?.email ?? '';

    return ListTile(
      leading: CircleAvatar(
        child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?'),
      ),
      title: Text(name),
      subtitle: Text(email),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isOwner)
            Chip(
              label: const Text('Propriétaire'),
              labelStyle: Theme.of(context).textTheme.labelSmall,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
          if (canRemove)
            IconButton(
              icon: const Icon(Icons.person_remove_outlined),
              tooltip: 'Retirer du groupe',
              onPressed: onRemove,
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
      final myUid = ref.read(appUserProvider).valueOrNull?.uid;
      if (myUid == null) return;
      await ref.read(groupRepositoryProvider).createGroup(name, myUid);
      if (context.mounted) Navigator.pop(context);
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
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
