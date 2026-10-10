import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/error_report_service.dart';
import '../domain/user_profile.dart';

/// Lecture des profils publics (`user_profiles/{uid}`).
///
/// Écrits par le serveur seul ; le client ne fait que les lire.
class UserProfileRepository {
  final FirebaseFirestore _firestore;
  final ErrorReportService _errorReportService;

  UserProfileRepository({
    FirebaseFirestore? firestore,
    ErrorReportService? errorReportService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _errorReportService =
           errorReportService ?? ErrorReportService(firestore: firestore);

  CollectionReference<Map<String, dynamic>> get _col =>
      _firestore.collection('user_profiles');

  /// Le profil public de [uid], ou `null` s'il n'existe pas encore.
  ///
  /// Une lecture en panne est rapportée et relancée : [memberNameProvider]
  /// affiche alors [UserProfile.fallbackName] (« Membre »).
  Future<UserProfile?> getProfile(String uid) async {
    try {
      final doc = await _col.doc(uid).get();
      final data = doc.data();
      if (data == null) return null;
      return UserProfile.fromFirestore(doc.id, data);
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'user_profile_get',
        error: e,
        stackTrace: st,
        context: {'uid': uid},
      );
      rethrow;
    }
  }
}
