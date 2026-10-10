import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/presentation/auth_providers.dart';
import '../data/group_repository.dart';
import '../domain/family_group.dart';

final groupRepositoryProvider = Provider<GroupRepository>((ref) {
  return GroupRepository();
});

/// Groupes familiaux dont l'utilisateur connecté est membre.
final myGroupsProvider = StreamProvider<List<FamilyGroup>>((ref) {
  final uid = ref.watch(appUserProvider).value?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(groupRepositoryProvider).watchMyGroups(uid);
});

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
  final names = groups
      .where((g) => g.isMember(uid))
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
