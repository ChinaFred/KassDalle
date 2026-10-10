class FamilyGroup {
  final String id;
  final String name;
  final String ownerId;

  /// UIDs de tous les membres, propriétaire inclus.
  final List<String> memberIds;

  /// UIDs des comptes invités qui n'ont pas encore répondu. Un invité n'est
  /// pas membre : il lit ce document pour décider, mais aucun livre ni
  /// aucune recette du groupe tant qu'il n'a pas accepté.
  final List<String> invitedIds;

  final DateTime createdAt;

  const FamilyGroup({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.memberIds,
    this.invitedIds = const [],
    required this.createdAt,
  });

  factory FamilyGroup.fromFirestore(String id, Map<String, dynamic> data) {
    return FamilyGroup(
      id: id,
      name: data['name'] as String,
      ownerId: data['owner_id'] as String,
      memberIds: List<String>.from(data['member_ids'] as List? ?? []),
      invitedIds: List<String>.from(data['invited_ids'] as List? ?? []),
      createdAt: (data['created_at'] as dynamic).toDate() as DateTime,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      'owner_id': ownerId,
      'member_ids': memberIds,
      'invited_ids': invitedIds,
      'created_at': createdAt,
    };
  }

  bool isOwner(String uid) => ownerId == uid;
  bool isMember(String uid) => memberIds.contains(uid);
  bool isInvited(String uid) => invitedIds.contains(uid);
}
