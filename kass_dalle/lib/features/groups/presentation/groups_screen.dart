import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/domain/user_profile.dart';
import '../../auth/presentation/auth_providers.dart';
import '../domain/family_group.dart';
import 'group_providers.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/theme/app_icon_size.dart';

class GroupsScreen extends ConsumerWidget {
  const GroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(myGroupsProvider);
    final myUid = ref.watch(appUserProvider).value?.uid ?? '';

    return Scaffold(
      appBar: AppBar(title: const Text('Groupes familiaux')),
      body: groupsAsync.when(
        loading: () => const AppLoadingState(),
        error: (e, _) => AppErrorState(
          error: e,
          onRetry: () => ref.invalidate(myGroupsProvider),
        ),
        data: (groups) {
          if (groups.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.group_outlined,
                    size: AppIconSize.hero,
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
            separatorBuilder: (_, _) => const Divider(height: 1),
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
  List<UserProfile> _searchResults = [];
  bool _searching = false;

  /// La saisie dont [_searchResults] est la réponse. `null` tant qu'aucune
  /// recherche n'a abouti : l'état vide ne s'affiche qu'après une réponse.
  String? _searchedQuery;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Recherche brute : les membres déjà présents sont écartés à l'affichage,
  /// contre la liste vivante du groupe et non contre un instantané figé.
  ///
  /// Une réponse qui arrive après une frappe plus récente est écartée : la
  /// liste et l'état vide correspondent toujours à la saisie affichée.
  Future<void> _search(String query) async {
    final q = query.trim();
    if (q.isEmpty) {
      setState(() {
        _searchResults = [];
        _searchedQuery = null;
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    try {
      final results = await ref.read(groupRepositoryProvider).searchUsers(q);
      if (!mounted || _searchController.text.trim() != q) return;
      setState(() {
        _searchResults = results;
        _searchedQuery = q;
        _searching = false;
      });
    } catch (e) {
      if (!mounted || _searchController.text.trim() != q) return;
      setState(() => _searching = false);
      context.showErrorSnackBar('Recherche impossible : $e');
    }
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _searchResults = [];
      _searchedQuery = null;
      _searching = false;
    });
  }

  Future<void> _addMember(FamilyGroup group, UserProfile user) async {
    try {
      await ref.read(groupRepositoryProvider).addMember(group.id, user.uid);
      if (!mounted) return;
      _clearSearch();
      context.showSuccessSnackBar('${user.displayedName} ajouté(e) au groupe');
    } catch (e) {
      if (!mounted) return;
      context.showErrorSnackBar('Ajout impossible : $e');
    }
  }

  /// Retire [uid] du groupe, après confirmation : le geste est à un appui
  /// du bouton voisin, et le membre perd aussitôt l'accès aux livres
  /// partagés par le groupe.
  Future<void> _removeMember(FamilyGroup group, String uid, String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Retirer du groupe'),
        content: Text('Retirer $name du groupe « ${group.name} » ?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Retirer'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(groupRepositoryProvider).removeMember(group.id, uid);
    } catch (e) {
      if (!mounted) return;
      context.showErrorSnackBar('Retrait impossible : $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Le groupe vivant, pas celui reçu à l'ouverture : un ajout ou un retrait
    // de membre se voit tout de suite dans la liste.
    final liveGroup = ref.watch(groupByIdProvider(widget.group.id));
    final group = liveGroup ?? widget.group;
    final isOwner = group.isOwner(widget.myUid);
    final candidates = _searchResults
        .where((u) => !group.memberIds.contains(u.uid))
        .toList();
    final typed = _searchController.text.trim();
    final searchDone =
        !_searching && typed.isNotEmpty && _searchedQuery == typed;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        group.name,
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
                    hintText: 'Rechercher un membre par son nom…',
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
                          tooltip: 'Effacer la recherche',
                          onPressed: _clearSearch,
                        ),
                    ],
                    onChanged: _search,
                  ),
                ),
                if (candidates.isNotEmpty) ...[
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
                      itemCount: candidates.length,
                      itemBuilder: (context, i) {
                        final user = candidates[i];
                        final name = user.displayedName;
                        return ListTile(
                          leading: CircleAvatar(
                            child: Text(name[0].toUpperCase()),
                          ),
                          title: Text(name),
                          subtitle: _fullNameSubtitle(user),
                          trailing: IconButton(
                            icon: const Icon(Icons.person_add_outlined),
                            tooltip: 'Ajouter au groupe',
                            onPressed: () => _addMember(group, user),
                          ),
                        );
                      },
                    ),
                  ),
                ],
                if (searchDone && candidates.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      _searchResults.isEmpty
                          ? 'Aucun membre trouvé pour « $typed ». La recherche '
                                'se fait par nom. Un compte en attente de '
                                'validation n\'apparaît qu\'une fois validé.'
                          : 'Les membres trouvés pour « $typed » sont déjà '
                                'dans le groupe.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
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
                  itemCount: group.memberIds.length,
                  itemBuilder: (context, i) {
                    final uid = group.memberIds[i];
                    return _MemberTile(
                      uid: uid,
                      isOwner: group.isOwner(uid),
                      canRemove: isOwner && uid != widget.myUid,
                      onRemove: (name) => _removeMember(group, uid, name),
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

/// Sous-titre d'un membre : son nom Google complet, quand il diffère du nom
/// affiché. Le même dans la recherche et dans la liste des membres.
Widget? _fullNameSubtitle(UserProfile? profile) {
  if (profile == null) return null;
  final full = profile.displayName.trim();
  if (full.isEmpty || full == profile.displayedName) return null;
  return Text(full);
}

class _MemberTile extends ConsumerWidget {
  final String uid;
  final bool isOwner;
  final bool canRemove;

  /// Reçoit le nom affiché, que la boîte de confirmation reprend.
  final ValueChanged<String> onRemove;

  const _MemberTile({
    required this.uid,
    required this.isOwner,
    required this.canRemove,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(memberNameProvider(uid)) ?? '…';
    final profile = ref.watch(userProfileProvider(uid)).value;

    return ListTile(
      leading: CircleAvatar(
        child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?'),
      ),
      title: Text(name),
      subtitle: _fullNameSubtitle(profile),
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
              onPressed: () => onRemove(name),
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
