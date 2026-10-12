import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/domain/user_profile.dart';
import '../../auth/presentation/auth_providers.dart';
import '../domain/family_group.dart';
import '../domain/member_email_search.dart';
import 'group_providers.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/utils/context_extensions.dart';

class GroupsScreen extends ConsumerWidget {
  const GroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final groupsAsync = ref.watch(myGroupsProvider);
    final invitationsAsync = ref.watch(myInvitationsProvider);
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
          // Les invitations ont leur propre flux : en chargement, la section
          // n'apparaît pas ; en erreur, un encart, et le reste de l'écran sert.
          final invitations = invitationsAsync.value ?? const <FamilyGroup>[];
          if (groups.isEmpty &&
              invitations.isEmpty &&
              !invitationsAsync.hasError) {
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
            padding: const EdgeInsets.only(top: 8, bottom: 88),
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
                _GroupTile(group: groups[i], myUid: myUid),
              ],
            ],
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
      subtitle: Text(
        isOwner && group.invitedIds.isNotEmpty
            ? '${group.memberIds.length} membre(s) · '
                  '${group.invitedIds.length} invitation(s) en attente'
            : '${group.memberIds.length} membre(s)',
      ),
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
    // Une adresse ne se cherche pas à chaque frappe : elle part à la
    // validation ([_searchByEmail]), chaque recherche étant comptée.
    if (q.isEmpty || isEmailLikeQuery(q)) {
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

  /// Recherche par adresse exacte, sur validation de la saisie ou par le
  /// bouton dédié. Le résultat prend la place des résultats par nom : même
  /// liste, même bouton « Inviter dans le groupe », même filtrage des membres
  /// et des invités.
  Future<void> _searchByEmail(String groupId) async {
    final q = _searchController.text.trim();
    if (!isCompleteEmailQuery(q) || _searching) return;
    setState(() => _searching = true);
    try {
      final found = await ref
          .read(groupRepositoryProvider)
          .findMemberByEmail(groupId, q);
      if (!mounted || _searchController.text.trim() != q) return;
      setState(() {
        _searchResults = found == null ? [] : [found];
        _searchedQuery = q;
        _searching = false;
      });
    } on MemberSearchLimitReached {
      // Signalée au rapport d'erreurs par GroupRepository.
      if (!mounted) return;
      setState(() => _searching = false);
      context.showErrorSnackBar(MemberSearchLimitReached.message);
    } catch (_) {
      // Signalée au rapport d'erreurs par GroupRepository.
      if (!mounted) return;
      setState(() => _searching = false);
      context.showErrorSnackBar('Recherche impossible. Réessayez.');
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

  Future<void> _inviteMember(FamilyGroup group, UserProfile user) async {
    try {
      await ref.read(groupRepositoryProvider).inviteMember(group.id, user.uid);
      if (!mounted) return;
      _clearSearch();
      context.showSuccessSnackBar('Invitation envoyée à ${user.displayedName}');
    } catch (_) {
      // Signalée au rapport d'erreurs par GroupRepository.
      if (!mounted) return;
      context.showErrorSnackBar(
        'Impossible d\'envoyer l\'invitation. Réessayez.',
      );
    }
  }

  /// Sans confirmation : le geste se refait d'un appui.
  Future<void> _cancelInvitation(
    FamilyGroup group,
    String uid,
    String name,
  ) async {
    try {
      await ref.read(groupRepositoryProvider).withdrawInvitation(group.id, uid);
      if (!mounted) return;
      context.showSuccessSnackBar('Invitation de $name annulée');
    } catch (_) {
      // Signalée au rapport d'erreurs par GroupRepository.
      if (!mounted) return;
      context.showErrorSnackBar(
        'Impossible d\'annuler l\'invitation. Réessayez.',
      );
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
        .where((u) => !group.isMember(u.uid) && !group.isInvited(u.uid))
        .toList();
    final typed = _searchController.text.trim();
    final searchDone =
        !_searching && typed.isNotEmpty && _searchedQuery == typed;
    final emailQuery = isEmailLikeQuery(typed);
    final completeEmail = isCompleteEmailQuery(typed);
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
                    hintText: 'Rechercher une personne à inviter…',
                    leading: _searching
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search),
                    trailing: [
                      if (completeEmail)
                        IconButton(
                          icon: const Icon(Icons.arrow_forward),
                          tooltip: 'Chercher cette adresse',
                          onPressed: _searching
                              ? null
                              : () => _searchByEmail(group.id),
                        ),
                      if (_searchController.text.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.clear),
                          tooltip: 'Effacer la recherche',
                          onPressed: _clearSearch,
                        ),
                    ],
                    onChanged: _search,
                    onSubmitted: (_) => _searchByEmail(group.id),
                  ),
                ),
                if (emailQuery && !searchDone && !_searching)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      completeEmail
                          ? 'Validez la saisie ou appuyez sur la flèche pour '
                                'chercher cette adresse.'
                          : 'Saisissez l\'adresse e-mail complète.',
                      style: Theme.of(context).textTheme.bodySmall,
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
                            tooltip: 'Inviter dans le groupe',
                            onPressed: () => _inviteMember(group, user),
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
                          ? (emailQuery
                                ? 'Aucun compte pour cette adresse. Un compte '
                                      'en attente de validation n\'apparaît '
                                      'qu\'une fois validé.'
                                : 'Aucun membre trouvé pour « $typed ». '
                                      'Cherchez par nom, ou par adresse '
                                      'e-mail complète. Un compte en attente '
                                      'de validation n\'apparaît qu\'une fois '
                                      'validé.')
                          : 'Les personnes trouvées pour « $typed » sont déjà '
                                'membres ou invitées.',
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
                child: ListView(
                  controller: scrollController,
                  children: [
                    for (final uid in group.memberIds)
                      _MemberTile(
                        uid: uid,
                        isOwner: group.isOwner(uid),
                        canRemove: isOwner && uid != widget.myUid,
                        onRemove: (name) => _removeMember(group, uid, name),
                      ),
                    if (isOwner && group.invitedIds.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                          'Invitations en attente (${group.invitedIds.length})',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      for (final uid in group.invitedIds)
                        _InvitedTile(
                          uid: uid,
                          onCancel: (name) =>
                              _cancelInvitation(group, uid, name),
                        ),
                    ],
                  ],
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

/// Un compte invité, vu par le propriétaire, avec de quoi annuler.
class _InvitedTile extends ConsumerWidget {
  final String uid;

  /// Reçoit le nom affiché, que le message de confirmation reprend.
  final ValueChanged<String> onCancel;

  const _InvitedTile({required this.uid, required this.onCancel});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final known = ref.watch(memberNameProvider(uid));
    final name = known ?? '…';
    return ListTile(
      leading: CircleAvatar(
        child: known == null || known.isEmpty
            ? const Icon(Icons.person_outline)
            : Text(known[0].toUpperCase()),
      ),
      title: Text(name),
      subtitle: const Text('Invitation envoyée'),
      trailing: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Annuler l\'invitation',
        onPressed: () => onCancel(name),
      ),
    );
  }
}

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
