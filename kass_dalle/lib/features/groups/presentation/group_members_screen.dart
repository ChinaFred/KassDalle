import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/widgets/app_states.dart';
import '../../admin/domain/email_invitation.dart';
import '../../auth/domain/app_user.dart';
import '../../auth/domain/user_profile.dart';
import '../../auth/presentation/auth_providers.dart';
import '../domain/family_group.dart';
import '../domain/member_email_search.dart';
import 'group_providers.dart';

/// Page de gestion des membres d'un groupe (`/groups/:groupId`).
///
/// Le propriétaire éditeur invite et annule ; il retire un membre quel que
/// soit son rôle. Les autres membres voient la liste seule.
class GroupMembersScreen extends ConsumerStatefulWidget {
  final String groupId;

  const GroupMembersScreen({super.key, required this.groupId});

  @override
  ConsumerState<GroupMembersScreen> createState() => _GroupMembersScreenState();
}

class _GroupMembersScreenState extends ConsumerState<GroupMembersScreen> {
  /// Le groupe a été lu au moins une fois : sa disparition (retrait,
  /// suppression) ramène alors à la liste au lieu d'afficher « introuvable ».
  bool _seen = false;

  final TextEditingController _searchController = TextEditingController();
  List<UserProfile> _searchResults = [];

  /// Recherche par nom en cours.
  bool _searching = false;

  /// Recherche par adresse en cours. Distincte de [_searching] : la fin de
  /// l'une ne coupe pas l'indicateur de l'autre.
  bool _emailSearching = false;

  /// Le serveur a refusé une recherche par adresse pour plafond atteint.
  /// Vaut tant que la page est ouverte : la flèche disparaît et la
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
  /// sauf le plafond, qui vaut pour toute la page.
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
    final groupsAsync = ref.watch(myGroupsProvider);
    final liveGroup = ref.watch(groupByIdProvider(widget.groupId));
    final myUid = ref.watch(appUserProvider).value?.uid ?? '';
    if (liveGroup == null) {
      if (groupsAsync.isLoading && !groupsAsync.hasValue) {
        return Scaffold(
          appBar: AppBar(leading: const _BackToGroupsButton()),
          body: const AppLoadingState(),
        );
      }
      if (groupsAsync.hasError && !groupsAsync.hasValue) {
        return Scaffold(
          appBar: AppBar(leading: const _BackToGroupsButton()),
          body: AppErrorState(
            error: groupsAsync.error,
            onRetry: () => ref.invalidate(myGroupsProvider),
          ),
        );
      }
      if (_seen) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) context.go(AppRoutes.groups);
        });
        return const Scaffold(body: AppLoadingState());
      }
      return Scaffold(
        appBar: AppBar(leading: const _BackToGroupsButton()),
        body: AppEmptyState(
          icon: Icons.group_off_outlined,
          title: 'Groupe introuvable',
          message:
              'Ce groupe n\'existe plus, ou vous n\'en faites plus partie.',
          action: FilledButton(
            onPressed: () => context.go(AppRoutes.groups),
            child: const Text('Retour aux groupes'),
          ),
        ),
      );
    }
    _seen = true;
    final group = liveGroup;
    // Inviter : même condition que la règle `isManagement`, propriétaire et
    // éditeur. Annuler une invitation et retirer un membre : le propriétaire
    // quel que soit son rôle (`isShrinking`).
    final isOwner = group.isOwner(myUid);
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
    return Scaffold(
      appBar: AppBar(
        leading: const _BackToGroupsButton(),
        title: Text(group.name),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            children: [
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
                  children: [
                    for (final uid in group.memberIds)
                      _MemberTile(
                        uid: uid,
                        isOwner: group.isOwner(uid),
                        canRemove: isOwner && uid != myUid,
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
        ),
      ),
    );
  }
}

/// Flèche de retour vers `/groups`, même quand la page est ouverte par un
/// lien direct, sans historique.
class _BackToGroupsButton extends StatelessWidget {
  const _BackToGroupsButton();

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const BackButtonIcon(),
      tooltip: 'Retour aux groupes',
      onPressed: () =>
          context.canPop() ? context.pop() : context.go(AppRoutes.groups),
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
