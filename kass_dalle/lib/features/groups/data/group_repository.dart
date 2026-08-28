import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/error_report_service.dart';
import '../../auth/domain/app_user.dart';
import '../domain/family_group.dart';

class GroupRepository {
  final FirebaseFirestore _firestore;
  final ErrorReportService _errorReportService;

  GroupRepository({
    FirebaseFirestore? firestore,
    ErrorReportService? errorReportService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       // Le rapport d'erreur suit le Firestore du repository : en test, il
       // écrit dans le Firestore de test au lieu d'exiger l'App réelle.
       _errorReportService =
           errorReportService ?? ErrorReportService(firestore: firestore);

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

  // Chaque écriture signale son échec puis le relance : l'écran a besoin de
  // l'erreur pour la dire à l'utilisateur, et le rapport garde la trace. Une
  // écriture de groupe qui échoue sans bruit laisse la liste inchangée, sans
  // rien pour distinguer le refus de la lenteur.

  /// Crée un nouveau groupe avec [ownerUid] comme seul membre.
  Future<String> createGroup(String name, String ownerUid) async {
    try {
      final ref = await _col.add({
        'name': name.trim(),
        'owner_id': ownerUid,
        'member_ids': [ownerUid],
        'created_at': Timestamp.fromDate(DateTime.now()),
      });
      return ref.id;
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'group_create',
        error: e,
        stackTrace: st,
        context: {'owner_id': ownerUid},
      );
      rethrow;
    }
  }

  /// Ajoute [uid] au groupe.
  Future<void> addMember(String groupId, String uid) async {
    try {
      await _col.doc(groupId).update({
        'member_ids': FieldValue.arrayUnion([uid]),
      });
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'group_add_member',
        error: e,
        stackTrace: st,
        context: {'group_id': groupId, 'member_uid': uid},
      );
      rethrow;
    }
  }

  /// Retire [uid] du groupe.
  Future<void> removeMember(String groupId, String uid) async {
    try {
      await _col.doc(groupId).update({
        'member_ids': FieldValue.arrayRemove([uid]),
      });
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'group_remove_member',
        error: e,
        stackTrace: st,
        context: {'group_id': groupId, 'member_uid': uid},
      );
      rethrow;
    }
  }

  /// Renomme le groupe.
  Future<void> renameGroup(String groupId, String newName) async {
    try {
      await _col.doc(groupId).update({'name': newName.trim()});
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'group_rename',
        error: e,
        stackTrace: st,
        context: {'group_id': groupId},
      );
      rethrow;
    }
  }

  /// Supprime le groupe.
  Future<void> deleteGroup(String groupId) async {
    try {
      await _col.doc(groupId).delete();
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'group_delete',
        error: e,
        stackTrace: st,
        context: {'group_id': groupId},
      );
      rethrow;
    }
  }

  // ── Recherche d'utilisateurs ─────────────────────────────────────────────────

  /// Recherche des utilisateurs par nom ou email (filtrage client-side).
  Future<List<AppUser>> searchUsers(String query) async {
    if (query.trim().isEmpty) return [];
    try {
      final snap = await _firestore.collection('users').limit(200).get();
      final q = query.trim().toLowerCase();
      return snap.docs
          .map((d) => AppUser.fromFirestore(d.data()))
          .where(
            (u) =>
                u.displayName.toLowerCase().contains(q) ||
                u.displayedName.toLowerCase().contains(q) ||
                u.email.toLowerCase().contains(q),
          )
          .toList();
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'group_search_users',
        error: e,
        stackTrace: st,
      );
      rethrow;
    }
  }
}
