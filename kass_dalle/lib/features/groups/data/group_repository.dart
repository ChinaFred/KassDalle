import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/error_report_service.dart';
import '../../auth/domain/user_profile.dart';
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

  /// Recherche des membres à inviter, par nom (filtrage côté client).
  ///
  /// Lit les profils publics (`user_profiles`), pas `users` : le document d'un
  /// compte, adresse comprise, ne se lit plus que par son titulaire et par un
  /// administrateur (v0.23.14). La recherche par adresse a disparu avec : la
  /// servir aurait demandé d'exposer les adresses, ou une Cloud Function de
  /// plus. Un compte en attente n'a pas de profil, et n'apparaît donc pas.
  /// Plafonné à 200 profils : une famille en compte quelques dizaines.
  Future<List<UserProfile>> searchUsers(String query) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    try {
      final snap = await _firestore
          .collection('user_profiles')
          .limit(200)
          .get();
      return snap.docs
          .map((d) => UserProfile.fromFirestore(d.id, d.data()))
          .where(
            (p) =>
                p.displayName.toLowerCase().contains(q) ||
                p.displayedName.toLowerCase().contains(q),
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
