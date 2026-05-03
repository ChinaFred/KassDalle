import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/presentation/auth_providers.dart';
import '../data/group_repository.dart';
import '../domain/family_group.dart';

final groupRepositoryProvider = Provider<GroupRepository>((ref) {
  return GroupRepository();
});

/// Groupes familiaux dont l'utilisateur connecté est membre.
final myGroupsProvider = StreamProvider<List<FamilyGroup>>((ref) {
  final uid = ref.watch(appUserProvider).valueOrNull?.uid;
  if (uid == null) return const Stream.empty();
  return ref.watch(groupRepositoryProvider).watchMyGroups(uid);
});

/// UIDs des autres membres des groupes (sans l'uid courant).
final groupMemberIdsProvider = Provider<AsyncValue<Set<String>>>((ref) {
  final myUid = ref.watch(appUserProvider).valueOrNull?.uid;
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
  final myUid = ref.watch(appUserProvider).valueOrNull?.uid;
  if (myUid == null) return const AsyncValue.data([]);
  final memberIds = ref.watch(groupMemberIdsProvider);
  return memberIds.when(
    loading: () => const AsyncValue.loading(),
    error: AsyncValue.error,
    data: (ids) => AsyncValue.data([myUid, ...ids]),
  );
});
