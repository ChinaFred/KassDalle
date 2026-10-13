/// Ce que l'utilisateur peut lire des plannings d'autrui :
/// `planning_reach/{uid}`, tenu par le serveur seul.
///
/// - [uids] : les comptes dont il lit le planning personnel, partagé avec un
///   de ses groupes ;
/// - [groupIds] : les groupes actifs dont il est membre, propriétaire
///   compris, dont il lit le planning de groupe ;
/// - [maskedGroupIds] : les groupes dont il est membre et que leur
///   propriétaire, qui n'est plus éditeur, masque. Les écrans des groupes ne
///   les listent plus.
///
/// Un document antérieur au planning de groupe n'a que `uids` : [groupIds] et
/// [maskedGroupIds] valent alors `null` (« inconnu »), et rien n'est masqué.
class PlanningReach {
  final Set<String> uids;
  final Set<String>? groupIds;
  final Set<String>? maskedGroupIds;

  const PlanningReach({
    this.uids = const {},
    this.groupIds,
    this.maskedGroupIds,
  });

  /// Aucun document : rien à lire, rien de masqué.
  static const empty = PlanningReach(groupIds: {}, maskedGroupIds: {});

  /// Lit le document. Jamais [myUid] dans [uids] ; une valeur mal formée est
  /// ignorée.
  factory PlanningReach.fromMap(Map<String, dynamic>? data, String myUid) {
    if (data == null) return empty;
    Set<String>? ids(Object? raw) => raw is List
        ? raw.whereType<String>().where((id) => id.isNotEmpty).toSet()
        : null;
    return PlanningReach(
      uids: (ids(data['uids']) ?? const <String>{})
          .where((id) => id != myUid)
          .toSet(),
      groupIds: ids(data['group_ids']),
      maskedGroupIds: ids(data['masked_group_ids']),
    );
  }

  /// Le planning du groupe [groupId] se lit-il ?
  bool readsGroup(String groupId) => groupIds?.contains(groupId) ?? false;

  /// Le groupe [groupId] est-il masqué (propriétaire rétrogradé) ?
  bool masks(String groupId) => maskedGroupIds?.contains(groupId) ?? false;

  /// Aucun planning d'autrui ne se lit : ni personnel partagé, ni de groupe.
  bool get isEmpty => uids.isEmpty && (groupIds?.isEmpty ?? true);

  @override
  bool operator ==(Object other) =>
      other is PlanningReach &&
      _sameSet(other.uids, uids) &&
      _sameSet(other.groupIds, groupIds) &&
      _sameSet(other.maskedGroupIds, maskedGroupIds);

  @override
  int get hashCode => Object.hash(
    Object.hashAllUnordered(uids),
    groupIds == null ? null : Object.hashAllUnordered(groupIds!),
    maskedGroupIds == null ? null : Object.hashAllUnordered(maskedGroupIds!),
  );

  static bool _sameSet(Set<String>? a, Set<String>? b) {
    if (a == null || b == null) return a == b;
    return a.length == b.length && a.containsAll(b);
  }
}
