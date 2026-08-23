/// Les préférences d'un compte, stockées avec lui.
///
/// Dans Firestore et non sur l'appareil : une préférence est un choix de
/// personne, pas de machine. Elle suit le compte du téléphone au navigateur, et
/// survit à une réinstallation.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/error_report_service.dart';

/// Ce qu'un compte a choisi une fois pour toutes.
class UserPreferences {
  /// Extraire les illustrations des pages importées, par défaut.
  ///
  /// C'est un **défaut**, pas un verrou : l'écran d'import porte la case à
  /// cocher, et l'utilisateur la change import par import sans que ce choix
  /// remonte ici.
  final bool importIllustrations;

  const UserPreferences({this.importIllustrations = true});

  UserPreferences copyWith({bool? importIllustrations}) => UserPreferences(
    importIllustrations: importIllustrations ?? this.importIllustrations,
  );

  static UserPreferences fromMap(Map<String, dynamic>? data) {
    if (data == null) return const UserPreferences();
    final value = data['import_illustrations'];
    return UserPreferences(importIllustrations: value is bool ? value : true);
  }
}

class UserPreferencesRepository {
  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  final ErrorReportService _errorReportService;

  UserPreferencesRepository({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    ErrorReportService? errorReportService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth ?? FirebaseAuth.instance,
       _errorReportService = errorReportService ?? ErrorReportService();

  DocumentReference<Map<String, dynamic>>? get _document {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return null;
    return _firestore.collection('users').doc(uid);
  }

  /// Lit les préférences, ou le défaut si la lecture échoue.
  ///
  /// Un défaut d'affichage ne doit pas empêcher d'importer : on repart de la
  /// valeur par défaut, mais l'échec part dans les rapports d'erreurs.
  Future<UserPreferences> load() async {
    final document = _document;
    if (document == null) return const UserPreferences();
    try {
      final snapshot = await document.get();
      return UserPreferences.fromMap(snapshot.data());
    } catch (error, stackTrace) {
      await _errorReportService.reportError(
        feature: 'account.loadPreferences',
        error: error,
        stackTrace: stackTrace,
      );
      return const UserPreferences();
    }
  }

  /// Enregistre le défaut d'extraction des illustrations.
  Future<void> setImportIllustrations(bool value) async {
    final document = _document;
    if (document == null) return;
    await document.set({
      'import_illustrations': value,
    }, SetOptions(merge: true));
  }
}

final userPreferencesRepositoryProvider = Provider<UserPreferencesRepository>(
  (ref) => UserPreferencesRepository(),
);

/// Les préférences du compte connecté, relues à la demande.
final userPreferencesProvider = FutureProvider<UserPreferences>(
  (ref) => ref.read(userPreferencesRepositoryProvider).load(),
);
