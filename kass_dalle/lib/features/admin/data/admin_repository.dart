import 'package:cloud_firestore/cloud_firestore.dart';
import '../../auth/domain/app_user.dart';

class AdminRepository {
  final FirebaseFirestore _firestore;

  AdminRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  /// Stream de tous les utilisateurs (tri côté client).
  ///
  /// Les comptes **en attente** passent devant : ce sont les seuls qui
  /// demandent une décision, et un compte qui attend en bas d'une liste
  /// chronologique attend longtemps. Le reste garde l'ordre d'arrivée.
  Stream<List<AppUser>> watchAllUsers() {
    return _firestore.collection('users').snapshots().map((snap) {
      final users = snap.docs
          .map((d) => AppUser.fromFirestore(d.data()))
          .toList();
      users.sort((a, b) {
        if (a.isPending != b.isPending) return a.isPending ? -1 : 1;
        return a.createdAt.compareTo(b.createdAt);
      });
      return users;
    });
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
