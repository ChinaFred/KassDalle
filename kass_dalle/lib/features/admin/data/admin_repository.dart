import 'package:cloud_firestore/cloud_firestore.dart';
import '../../../core/services/error_report_service.dart';
import '../../auth/domain/app_user.dart';

class AdminRepository {
  final FirebaseFirestore _firestore;
  final ErrorReportService _errorReportService;

  /// Documents illisibles déjà signalés : chaque instantané relit toute la
  /// collection, et un même document ne doit pas produire un rapport par
  /// instantané.
  final Set<String> _reportedUnreadable = {};

  AdminRepository({
    FirebaseFirestore? firestore,
    ErrorReportService? errorReportService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _errorReportService = errorReportService ?? ErrorReportService();

  /// Stream de tous les utilisateurs (tri côté client).
  ///
  /// Les comptes **en attente** passent devant : ce sont les seuls qui
  /// demandent une décision, et un compte qui attend en bas d'une liste
  /// chronologique attend longtemps. Le reste garde l'ordre d'arrivée.
  ///
  /// L'uid d'un compte est l'identifiant de son document, jamais le champ
  /// `uid` qu'il porte : ce champ est écrit par le client, et l'écran agit
  /// sur `user.uid` (rôle, révocation). Un compte en attente qui y aurait
  /// mis l'uid d'un éditeur faisait révoquer l'éditeur (ticket #162).
  Stream<List<AppUser>> watchAllUsers() {
    return _firestore.collection('users').snapshots().map((snap) {
      final users = <AppUser>[];
      for (final d in snap.docs) {
        final user = _readUser(d);
        if (user != null) users.add(user);
      }
      users.sort((a, b) {
        if (a.isPending != b.isPending) return a.isPending ? -1 : 1;
        return a.createdAt.compareTo(b.createdAt);
      });
      return users;
    });
  }

  /// Lit un compte, ou `null` si son document est mal formé (champ absent
  /// ou d'un mauvais type). Un seul document illisible faisait tomber la
  /// liste entière en erreur pour tous les administrateurs : il est sauté,
  /// signalé une fois, et la liste continue avec les autres.
  AppUser? _readUser(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    try {
      return AppUser.fromFirestore({...d.data(), 'uid': d.id});
    } catch (e, st) {
      if (_reportedUnreadable.add(d.id)) {
        _errorReportService
            .reportError(
              feature: 'admin.watchAllUsers',
              error: e,
              stackTrace: st,
              context: {'doc_id': d.id},
            )
            .ignore();
      }
      return null;
    }
  }

  /// Change le rôle d'un utilisateur.
  Future<void> updateRole(String uid, UserRole role) async {
    await _firestore.collection('users').doc(uid).update({'role': role.name});
  }

  /// Révoque ou rétablit l'accès d'un utilisateur.
  Future<void> setRevoked(String uid, {required bool revoked}) async {
    await _firestore.collection('users').doc(uid).update({
      'is_revoked': revoked,
    });
  }
}
