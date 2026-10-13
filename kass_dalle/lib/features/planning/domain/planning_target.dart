import '../../groups/domain/family_group.dart';
import 'planning_reach.dart';

/// Le planning où l'on planifie : le sien (« Mon planning »), ou celui d'un
/// groupe familial dont on est le propriétaire.
///
/// Un repas de groupe porte `group_id` ; son `uid` reste celui du
/// propriétaire, qui le cuisine. Seul le propriétaire planifie pour son
/// groupe : les règles Firestore le vérifient à chaque écriture.
class PlanningTarget {
  /// Le groupe, ou `null` pour « Mon planning ».
  final String? groupId;

  /// Le nom du groupe ; vide pour « Mon planning ».
  final String groupName;

  /// Les membres du groupe, propriétaire compris ; 0 pour « Mon planning ».
  final int memberCount;

  const PlanningTarget.personal()
    : groupId = null,
      groupName = '',
      memberCount = 0;

  const PlanningTarget.group({
    required String this.groupId,
    required this.groupName,
    required this.memberCount,
  });

  /// Le planning du groupe [group].
  factory PlanningTarget.ofGroup(FamilyGroup group) => PlanningTarget.group(
    groupId: group.id,
    groupName: group.name,
    memberCount: groupMemberCount(group),
  );

  bool get isGroup => groupId != null;

  /// « Mon planning », ou le nom du groupe.
  String get title => isGroup ? groupName : 'Mon planning';

  /// « Planning du groupe · 4 membres » ; rien pour « Mon planning ».
  String? get subtitle => isGroup
      ? 'Planning du groupe · $memberCount '
            'membre${memberCount > 1 ? 's' : ''}'
      : null;

  @override
  bool operator ==(Object other) =>
      other is PlanningTarget && other.groupId == groupId;

  @override
  int get hashCode => groupId.hashCode;
}

/// Les membres d'un groupe, propriétaire compris, comptés une fois.
int groupMemberCount(FamilyGroup group) =>
    {...group.memberIds, group.ownerId}.length;

/// Parts par défaut d'un repas de groupe : celles réglées pour ce groupe
/// (`planning_config/{propriétaire}.group_portions`), sinon le nombre de
/// membres.
int groupDefaultPortions({
  required Map<String, int> groupPortions,
  required FamilyGroup group,
}) {
  final set = groupPortions[group.id] ?? 0;
  return set > 0 ? set : groupMemberCount(group);
}

/// Les groupes où [myUid] planifie : ceux dont il est le propriétaire, que
/// le serveur ne masque pas, par ordre alphabétique de leur nom. Vide si
/// [canPlan] est faux : un propriétaire rétrogradé ne planifie plus.
List<FamilyGroup> ownedPlanningGroups({
  required List<FamilyGroup> groups,
  required String myUid,
  required bool canPlan,
  PlanningReach? reach,
}) {
  if (!canPlan) return const [];
  final owned = [
    for (final g in groups)
      if (g.ownerId == myUid && !(reach?.masks(g.id) ?? false)) g,
  ];
  owned.sort((a, b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.id.compareTo(b.id);
  });
  return owned;
}
