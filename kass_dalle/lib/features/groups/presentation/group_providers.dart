import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../admin/domain/email_invitation.dart';
import '../../admin/presentation/admin_providers.dart'
    show invitationsRepositoryProvider;
import '../../auth/presentation/auth_providers.dart';
import '../data/group_repository.dart';
import '../domain/family_group.dart';

final groupRepositoryProvider = Provider<GroupRepository>((ref) {
  return GroupRepository();
});

/// Groupes familiaux dont l'utilisateur connecté est membre, groupes en
/// pause compris (voir [myPausedGroupsProvider]).
final myGroupsProvider = StreamProvider<List<FamilyGroup>>((ref) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(groupRepositoryProvider).watchMyGroups(uid);
});

/// Identifiants des groupes de l'utilisateur connecté qui sont « en pause » :
/// leur propriétaire n'est plus éditeur (`planning_reach.masked_group_ids`).
final maskedGroupIdsProvider = StreamProvider<Set<String>>((ref) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(groupRepositoryProvider).watchMaskedGroupIds(uid);
});

/// Les groupes de l'utilisateur connecté qui sont en pause, les siens comme
/// ceux d'un autre propriétaire. En chargement tant que les deux lectures ne
/// sont pas arrivées, en erreur si l'une échoue : un écran ne choisit pas un
/// état vide sur une réponse partielle.
final myPausedGroupsProvider = Provider<AsyncValue<List<FamilyGroup>>>((ref) {
  final groups = ref.watch(myGroupsProvider);
  final masked = ref.watch(maskedGroupIdsProvider);
  if (groups.hasError && !groups.hasValue) {
    return AsyncError(groups.error!, groups.stackTrace ?? StackTrace.empty);
  }
  if (masked.hasError && !masked.hasValue) {
    return AsyncError(masked.error!, masked.stackTrace ?? StackTrace.empty);
  }
  if (!groups.hasValue || !masked.hasValue) return const AsyncLoading();
  final ids = masked.value!;
  return AsyncData([
    for (final g in groups.value!)
      if (ids.contains(g.id)) g,
  ]);
});

/// « Votre groupe Famille Dupont est en pause. », ou « Vos groupes A et B
/// sont en pause. » ; `null` sans groupe en pause.
String? pausedGroupsTitle(List<FamilyGroup> paused) {
  if (paused.isEmpty) return null;
  final names = paused.map((g) => g.name).toList()..sort();
  if (names.length == 1) return 'Votre groupe ${names.single} est en pause.';
  final head = names.sublist(0, names.length - 1).join(', ');
  return 'Vos groupes $head et ${names.last} sont en pause.';
}

/// Ce qui suit le titre d'un groupe en pause que l'on possède.
String pausedGroupsMessage(int count) => count > 1
    ? 'Ils reviendront quand vous serez de nouveau éditeur.'
    : 'Il reviendra quand vous serez de nouveau éditeur.';

/// Pour un membre, sous le titre « Le groupe Famille Dupont est en pause. » :
/// « Marie, qui en est propriétaire, n'a plus le rôle d'éditeur. Il reviendra
/// quand Marie retrouvera ce rôle. »
String pausedMemberGroupMessage(String ownerName) =>
    '$ownerName, qui en est propriétaire, n\'a plus le rôle d\'éditeur. '
    'Il reviendra quand $ownerName retrouvera ce rôle.';

/// Pour un membre de plusieurs groupes en pause : « Vos groupes A et B sont
/// en pause : leurs propriétaires n'ont plus le rôle d'éditeur. » ; `null`
/// avec moins de deux groupes.
String? pausedMemberGroupsTitle(List<FamilyGroup> paused) {
  if (paused.length < 2) return null;
  final title = pausedGroupsTitle(paused)!;
  return '${title.substring(0, title.length - 1)} : leurs propriétaires '
      'n\'ont plus le rôle d\'éditeur.';
}

/// Groupes qui invitent l'utilisateur connecté et attendent sa réponse.
final myInvitationsProvider = StreamProvider<List<FamilyGroup>>((ref) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(groupRepositoryProvider).watchMyInvitations(uid);
});

/// Nombre d'invitations en attente, pour le badge du menu compte.
final pendingInvitationsCountProvider = Provider<int>((ref) {
  return ref.watch(myInvitationsProvider).value?.length ?? 0;
});

/// Un groupe précis, suivi en direct.
///
/// La feuille de gestion des membres recevait le groupe par valeur, figé à
/// l'ouverture : ajouter un membre écrivait bien dans Firestore, mais la liste
/// affichée restait celle du premier instant. L'ajout semblait avoir échoué.
/// En passant par ce provider, la feuille lit la même source que l'écran, et
/// la compensation de latence de Firestore rend le nouveau membre visible
/// avant même l'aller-retour serveur.
final groupByIdProvider = Provider.family<FamilyGroup?, String>((ref, id) {
  final groups = ref.watch(myGroupsProvider).value;
  if (groups == null) return null;
  for (final group in groups) {
    if (group.id == id) return group;
  }
  return null;
});

/// Portée des groupes de l'utilisateur connecté, lue sur `group_reach/{uid}`.
final groupReachProvider = StreamProvider<Set<String>>((ref) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(groupRepositoryProvider).watchReach(uid);
});

/// UIDs des autres membres des groupes (sans l'uid courant).
///
/// Lus sur la portée (`group_reach`) et non sur les groupes : ce sont les
/// comptes que les règles Firestore laissent lire. Un membre que les groupes
/// viennent de recevoir n'y figure qu'une fois le déclencheur passé, une
/// seconde plus tard ; le nommer plus tôt ferait refuser toute la requête.
final groupMemberIdsProvider = Provider<AsyncValue<Set<String>>>((ref) {
  return ref.watch(groupReachProvider);
});

/// Noms des groupes familiaux qui me relient à [uid].
///
/// Vide si nous n'en partageons aucun — c'est le cas d'un administrateur qui
/// ouvre le livre d'un membre sans être de sa famille. La liste est triée pour
/// que la phrase affichée ne change pas d'ordre d'un rendu à l'autre.
final sharedGroupNamesProvider = Provider.family<List<String>, String>((
  ref,
  uid,
) {
  final groups = ref.watch(myGroupsProvider).value ?? const <FamilyGroup>[];
  // Un groupe en pause ne partage plus rien : il n'est pas cité.
  final paused = ref.watch(maskedGroupIdsProvider).value ?? const <String>{};
  final names = groups
      .where((g) => g.isMember(uid) && !paused.contains(g.id))
      .map((g) => g.name)
      .toList();
  names.sort();
  return names;
});

/// Tous les UIDs visibles : mon uid + UIDs de tous mes groupes.
final visibleUserIdsProvider = Provider<AsyncValue<List<String>>>((ref) {
  final myUid = ref.watch(appUserProvider).value?.uid;
  if (myUid == null) return const AsyncValue.data([]);
  final memberIds = ref.watch(groupMemberIdsProvider);
  return memberIds.when(
    loading: () => const AsyncValue.loading(),
    error: AsyncValue.error,
    data: (ids) => AsyncValue.data([myUid, ...ids]),
  );
});

/// Invitations par e-mail d'un groupe, lues par son propriétaire seul : la
/// règle Firestore refuse la requête à tout autre compte non administrateur.
/// L'appelant ne l'observe que si l'utilisateur possède le groupe.
final groupEmailInvitationsProvider = StreamProvider.autoDispose
    .family<List<EmailInvitation>, String>((ref, groupId) {
      return ref
          .watch(invitationsRepositoryProvider)
          .watchGroupInvitations(groupId);
    });

/// Les invitations par e-mail encore en attente (envoyée, ou envoi échoué
/// non expiré), les plus anciennes d'abord. Une acceptée, annulée ou
/// expirée n'y figure pas.
List<EmailInvitation> pendingEmailInvitations(
  List<EmailInvitation> all,
  DateTime now,
) {
  final pending = all.where((i) => i.statusAt(now).isPending).toList();
  pending.sort((a, b) {
    final x = a.createdAt, y = b.createdAt;
    if (x == null && y == null) return a.email.compareTo(b.email);
    if (x == null) return 1;
    if (y == null) return -1;
    return x.compareTo(y);
  });
  return pending;
}
