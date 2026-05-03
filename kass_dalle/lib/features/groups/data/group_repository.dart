import 'package:cloud_firestore/cloud_firestore.dart';

import '../../auth/domain/app_user.dart';
import '../domain/family_group.dart';

class GroupRepository {
  final FirebaseFirestore _firestore;

  GroupRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('groups');

  // ── Lecture ─────────────────────────────────────────────────────────────────

  /// Groupes dont [uid] est membre.
  Stream<List<FamilyGroup>> watchMyGroups(String uid) {
    return _col.where('member_ids', arrayContains: uid).snapshots().map((snap) {
      final list = snap.docs
          .map((d) => FamilyGroup.fromFirestore(d.id, d.data()))
          .toList();
      list.sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return list;
    });
  }

  // ── Écriture ─────────────────────────────────────────────────────────────────

  /// Crée un nouveau groupe avec [ownerUid] comme seul membre.
  Future<String> createGroup(String name, String ownerUid) async {
    final ref = await _col.add({
      'name': name.trim(),
      'owner_id': ownerUid,
      'member_ids': [ownerUid],
      'created_at': Timestamp.fromDate(DateTime.now()),
    });
    return ref.id;
  }

  /// Ajoute [uid] au groupe.
  Future<void> addMember(String groupId, String uid) async {
    await _col.doc(groupId).update({
      'member_ids': FieldValue.arrayUnion([uid]),
    });
  }

  /// Retire [uid] du groupe.
  Future<void> removeMember(String groupId, String uid) async {
    await _col.doc(groupId).update({
      'member_ids': FieldValue.arrayRemove([uid]),
    });
  }

  /// Renomme le groupe.
  Future<void> renameGroup(String groupId, String newName) async {
    await _col.doc(groupId).update({'name': newName.trim()});
  }

  /// Supprime le groupe.
  Future<void> deleteGroup(String groupId) async {
    await _col.doc(groupId).delete();
  }

  // ── Recherche d'utilisateurs ─────────────────────────────────────────────────

  /// Recherche des utilisateurs par nom ou email (filtrage client-side).
  Future<List<AppUser>> searchUsers(String query) async {
    if (query.trim().isEmpty) return [];
    final snap = await _firestore.collection('users').limit(200).get();
    final q = query.trim().toLowerCase();
    return snap.docs
        .map((d) => AppUser.fromFirestore(d.data()))
        .where(
          (u) =>
              u.displayName.toLowerCase().contains(q) ||
              u.email.toLowerCase().contains(q),
        )
        .toList();
  }
}
