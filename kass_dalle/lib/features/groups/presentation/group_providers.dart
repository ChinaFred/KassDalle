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

/// UIDs des autres membres des groupes (sans l'uid courant).
final groupMemberIdsProvider = Provider<AsyncValue<Set<String>>>((ref) {
  final myUid = ref.watch(appUserProvider).value?.uid;
  final groups = ref.watch(myGroupsProvider);
  return groups.when(
    loading: () => const AsyncValue.loading(),
    error: AsyncValue.error,
    data: (groupList) {
      final ids = groupList.expand((g) => g.memberIds).toSet();
      if (myUid != null) ids.remove(myUid);
      return AsyncValue.data(ids);
    },
  );
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
