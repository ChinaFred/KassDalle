import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/error_report_service.dart';
import '../domain/search_models.dart';

/// Lit et écrit la préférence de l'écran Explorer d'un lecteur :
/// `users/{uid}/preferences/explore_filters`.
///
/// Même mécanisme que le périmètre du planning (`recipe_search_scope`) : une
/// préférence de lecteur, sous son compte, jamais dans un document partagé.
class ExplorePreferencesRepository {
  final FirebaseFirestore _firestore;
  final ErrorReportService _errorReportService;

  ExplorePreferencesRepository({
    FirebaseFirestore? firestore,
    ErrorReportService? errorReportService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _errorReportService =
           errorReportService ?? ErrorReportService(firestore: firestore);

  DocumentReference<Map<String, dynamic>> _doc(String uid) => _firestore
      .collection('users')
      .doc(uid)
      .collection('preferences')
      .doc('explore_filters');

  /// La préférence enregistrée, ou les valeurs par défaut si rien n'est
  /// enregistré. Une lecture en échec est rapportée et rend aussi les valeurs
  /// par défaut : l'écran reste utilisable, les filtres repartent de zéro.
  Future<ExplorePreferences> load(String uid) async {
    try {
      final data = (await _doc(uid).get()).data();
      return data == null
          ? ExplorePreferences.defaults
          : ExplorePreferences.fromMap(data);
    } catch (e, st) {
      unawaited(
        _errorReportService.reportError(
          feature: 'explore_preferences_load',
          error: e,
          stackTrace: st,
          context: {'uid': uid},
        ),
      );
      return ExplorePreferences.defaults;
    }
  }

  /// Enregistre la préférence. Un échec est rapporté et ne remonte pas :
  /// l'écran garde le filtre choisi, seul le souvenir est perdu.
  Future<void> save(String uid, ExplorePreferences prefs) async {
    try {
      await _doc(
        uid,
      ).set({...prefs.toMap(), 'updated_at': FieldValue.serverTimestamp()});
    } catch (e, st) {
      unawaited(
        _errorReportService.reportError(
          feature: 'explore_preferences_save',
          error: e,
          stackTrace: st,
          context: {'uid': uid},
        ),
      );
    }
  }
}
