import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../admin/domain/email_invitation.dart';
import '../../auth/domain/app_user.dart';
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

  /// Recherche par nom en cours.
  bool _searching = false;

  /// Recherche par adresse en cours. Distincte de [_searching] : la fin de
  /// l'une ne coupe pas l'indicateur de l'autre.
  bool _emailSearching = false;

  /// Le serveur a refusé une recherche par adresse pour plafond atteint.
  /// Vaut tant que la feuille est ouverte : la flèche disparaît et la
  /// validation ne part plus ; la recherche par nom reste possible.
  bool _limitReached = false;

  /// Échec de la recherche par adresse, et la saisie qu'il concerne : le
  /// message disparaît dès que la saisie change.
  String? _emailError;
  String? _emailErrorQuery;

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
    } catch (_) {
      if (!mounted || _searchController.text.trim() != q) return;
      setState(() => _searching = false);
      // Signalée au rapport d'erreurs par GroupRepository.
      context.showErrorSnackBar('Recherche impossible. Réessayez.');
    }
  }

  /// Recherche par adresse exacte, sur validation de la saisie ou par le
  /// bouton dédié. Le résultat prend la place des résultats par nom : même
  /// liste, même bouton « Inviter dans le groupe », même filtrage des membres
  /// et des invités.
  ///
  /// Une réponse qui arrive après une modification de la saisie est écartée,
  /// sauf le plafond, qui vaut pour toute la feuille.
  Future<void> _searchByEmail(String groupId) async {
    final q = _searchController.text.trim();
    if (!isCompleteEmailQuery(q) || _emailSearching || _limitReached) return;
    setState(() {
      _emailSearching = true;
      _emailError = null;
      _emailErrorQuery = null;
    });
    try {
      final found = await ref
          .read(groupRepositoryProvider)
          .findMemberByEmail(groupId, q);
      if (!mounted) return;
      setState(() {
        _emailSearching = false;
        if (_searchController.text.trim() != q) return;
        _searchResults = found == null ? [] : [found];
        _searchedQuery = q;
      });
    } on MemberSearchLimitReached {
      // Signalée au rapport d'erreurs par GroupRepository.
      if (!mounted) return;
      setState(() {
        _emailSearching = false;
        _limitReached = true;
      });
    } on MemberSearchRefused catch (e) {
      // Groupe supprimé, ou propriété perdue : le message du serveur dit
      // lequel. Signalée au rapport d'erreurs par GroupRepository.
      if (!mounted) return;
      setState(() {
        _emailSearching = false;
        if (_searchController.text.trim() != q) return;
        _searchResults = [];
        _searchedQuery = null;
        _emailError = e.message;
        _emailErrorQuery = q;
      });
    } catch (_) {
      // Signalée au rapport d'erreurs par GroupRepository.
      if (!mounted) return;
      setState(() {
        _emailSearching = false;
        if (_searchController.text.trim() != q) return;
        _searchResults = [];
        _searchedQuery = null;
        _emailError = 'Recherche impossible. Réessayez.';
        _emailErrorQuery = q;
      });
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
    } catch (_) {
      // Signalée au rapport d'erreurs par GroupRepository.
      if (!mounted) return;
      context.showErrorSnackBar('Retrait impossible. Réessayez.');
    }
  }

  @override
  Widget build(BuildContext context) {
    // Le groupe vivant, pas celui reçu à l'ouverture : un ajout ou un retrait
    // de membre se voit tout de suite dans la liste.
    final liveGroup = ref.watch(groupByIdProvider(widget.group.id));
    final group = liveGroup ?? widget.group;
    // Inviter : même condition que la règle `isManagement`, propriétaire et
    // éditeur. Annuler une invitation et retirer un membre : le propriétaire
    // quel que soit son rôle (`isShrinking`).
    final isOwner = group.isOwner(widget.myUid);
    final canManage = isOwner && ref.watch(canEditProvider);
    // Groupe en pause : son propriétaire n'est plus éditeur. Une portée
    // illisible ne marque rien (l'erreur est déjà au rapport).
    final paused =
        ref.watch(maskedGroupIdsProvider).value?.contains(group.id) ?? false;
    final candidates = _searchResults
        .where((u) => !group.isMember(u.uid) && !group.isInvited(u.uid))
        .toList();
    final typed = _searchController.text.trim();
    final searchDone =
        !_searching &&
        !_emailSearching &&
        typed.isNotEmpty &&
        _searchedQuery == typed;
    final emailQuery = isEmailLikeQuery(typed);
    final completeEmail = isCompleteEmailQuery(typed);
    final busy = _searching || _emailSearching;
    final colors = Theme.of(context).colorScheme;
    final smallText = Theme.of(context).textTheme.bodySmall;
    final emailAsync = isOwner
        ? ref.watch(groupEmailInvitationsProvider(group.id))
        : null;
    final emailPending = pendingEmailInvitations(
      emailAsync?.value ?? const [],
      DateTime.now(),
    );
    final emailError = emailAsync != null && emailAsync.hasError;
    final pendingCount = group.invitedIds.length + emailPending.length;
    // L'aide de la recherche par adresse, ou ce qui la remplace : recherche
    // en cours, plafond atteint, échec. `null` : rien à afficher, la réponse
    // (liste ou état vide) occupe la place.
    final String? emailHelp;
    var emailHelpIsError = false;
    if (!emailQuery) {
      emailHelp = null;
    } else if (_emailSearching) {
      emailHelp = 'Recherche en cours…';
    } else if (_limitReached) {
      emailHelp = MemberSearchLimitReached.message;
      emailHelpIsError = true;
    } else if (_emailError != null && _emailErrorQuery == typed) {
      emailHelp = _emailError;
      emailHelpIsError = true;
    } else if (searchDone) {
      emailHelp = null;
    } else if (completeEmail) {
      emailHelp =
          'Validez la saisie ou appuyez sur la flèche pour chercher cette '
          'adresse.';
    } else {
      emailHelp = 'Saisissez l\'adresse e-mail complète.';
    }
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
              if (canManage) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: SearchBar(
                    controller: _searchController,
                    hintText: 'Nom ou adresse e-mail complète',
                    leading: busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              semanticsLabel: 'Recherche en cours',
                            ),
                          )
                        : const Icon(Icons.search),
                    trailing: [
                      if (completeEmail && !_limitReached)
                        IconButton(
                          icon: const Icon(Icons.arrow_forward),
                          tooltip: 'Chercher cette adresse',
                          onPressed: _emailSearching
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
                if (emailHelp != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Semantics(
                      liveRegion: emailHelpIsError,
                      child: Text(
                        emailHelp,
                        style: emailHelpIsError
                            ? smallText?.copyWith(color: colors.error)
                            : smallText,
                      ),
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
                if (searchDone && candidates.isEmpty && emailHelp == null)
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
                          : (emailQuery
                                ? 'Ce compte est déjà membre du groupe ou '
                                      'invité.'
                                : 'Les personnes trouvées pour « $typed » '
                                      'sont déjà membres ou invitées.'),
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
              if (isOwner && !canManage)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      paused
                          ? 'Seul un éditeur invite de nouveaux membres et '
                                'renomme le groupe. Ce groupe est en pause : '
                                'son planning n\'apparaît plus tant que vous '
                                'n\'êtes pas éditeur.'
                          : 'Seul un éditeur invite de nouveaux membres et '
                                'renomme le groupe.',
                      style: smallText,
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
                    if (isOwner && (pendingCount > 0 || emailError)) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                          emailError && pendingCount == 0
                              ? 'Invitations en attente'
                              : 'Invitations en attente ($pendingCount)',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                      for (final uid in group.invitedIds)
                        _InvitedTile(
                          uid: uid,
                          onCancel: (name) =>
                              _cancelInvitation(group, uid, name),
                        ),
                      for (final invitation in emailPending)
                        _EmailInvitedTile(invitation: invitation),
                      if (emailError)
                        ListTile(
                          leading: const Icon(Icons.error_outline),
                          title: const Text(
                            'Invitations par e-mail indisponibles',
                          ),
                          trailing: TextButton(
                            onPressed: () => ref.invalidate(
                              groupEmailInvitationsProvider(group.id),
                            ),
                            child: const Text('Réessayer'),
                          ),
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

/// Une invitation par e-mail (personne sans compte), vue par le propriétaire.
/// Lecture seule : l'annulation et le renvoi restent dans Admin › Invitations.
class _EmailInvitedTile extends StatelessWidget {
  final EmailInvitation invitation;

  const _EmailInvitedTile({required this.invitation});

  @override
  Widget build(BuildContext context) {
    final failed =
        invitation.statusAt(DateTime.now()) == EmailInvitationStatus.sendFailed;
    final role = invitation.role == UserRole.editor ? 'éditeur' : 'lecteur';
    return ListTile(
      leading: const CircleAvatar(child: Icon(Icons.mail_outline)),
      title: Text(invitation.email),
      subtitle: Text(
        '${failed ? 'Envoi échoué' : 'Invitation envoyée par e-mail'} · $role',
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
