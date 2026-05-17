class FamilyGroup {
  final String id;
  final String name;
  final String ownerId;

  /// UIDs de tous les membres, propriétaire inclus.
  final List<String> memberIds;

  final DateTime createdAt;

  const FamilyGroup({
    required this.id,
    required this.name,
    required this.ownerId,
    required this.memberIds,
    required this.createdAt,
  });

  factory FamilyGroup.fromFirestore(String id, Map<String, dynamic> data) {
    return FamilyGroup(
      id: id,
      name: data['name'] as String,
      ownerId: data['owner_id'] as String,
      memberIds: List<String>.from(data['member_ids'] as List? ?? []),
      createdAt: (data['created_at'] as dynamic).toDate() as DateTime,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'name': name,
      'owner_id': ownerId,
      'member_ids': memberIds,
      'created_at': createdAt,
    };
  }

  bool isOwner(String uid) => ownerId == uid;
  bool isMember(String uid) => memberIds.contains(uid);
}
