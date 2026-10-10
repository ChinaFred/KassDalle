import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/error_report_service.dart';
import '../domain/planning_refusals.dart';

/// Lit et écrit la mémoire des refus du planning d'un compte :
/// `users/{uid}/preferences/planning_refusals`, un seul document.
///
/// Le titulaire l'écrit depuis l'application ; le serveur le lit à la
/// présélection, pour l'appelant seul. Rien n'est écrit dans la recette
/// partagée : un refus de l'un ne pèse pas pour un autre membre.
class PlanningRefusalsRepository {
  PlanningRefusalsRepository({
    FirebaseFirestore? firestore,
    ErrorReportService? errorReportService,
    DateTime Function()? clock,
  }) : _db = firestore ?? FirebaseFirestore.instance,
       _errorReportService =
           errorReportService ?? ErrorReportService(firestore: firestore),
       _clock = clock ?? DateTime.now;

  final FirebaseFirestore _db;
  final ErrorReportService _errorReportService;
  final DateTime Function() _clock;

  DocumentReference<Map<String, dynamic>> _doc(String uid) => _db
      .collection('users')
      .doc(uid)
      .collection('preferences')
      .doc('planning_refusals');

  /// Instant de référence des refus.
  DateTime now() => _clock();

  /// La mémoire, lue une fois. Une erreur remonte à l'appelant : l'écran
  /// la dit (« Liste des refus illisible »).
  Future<PlanningRefusals> load(String uid) async {
    final snap = await _doc(uid).get();
    return PlanningRefusals.fromFirestore(snap.data());
  }

  /// Ajoute les refus de [recipeIds], en transaction : les entrées expirées
  /// sortent, le compte d'un refus encore actif augmente.
  ///
  /// Jamais bloquant : un échec est remonté au rapport d'erreurs
  /// (`planning.recordRefusals`) et le geste de l'utilisateur continue. Rend
  /// `false` dans ce cas.
  Future<bool> record(String uid, Iterable<String> recipeIds) async {
    final ids = recipeIds.where((id) => id.isNotEmpty).toSet();
    if (ids.isEmpty) return true;
    try {
      final ref = _doc(uid);
      await _db.runTransaction((tx) async {
        final snap = await tx.get(ref);
        final next = PlanningRefusals.fromFirestore(
          snap.data(),
        ).record(ids, _clock());
        tx.set(ref, {
          'entries': next.entriesToFirestore(),
          'updated_at': FieldValue.serverTimestamp(),
        });
      });
      return true;
    } catch (e, stackTrace) {
      unawaited(
        _errorReportService.reportError(
          userId: uid,
          feature: 'planning.recordRefusals',
          error: e,
          stackTrace: stackTrace,
          context: {'recipe_ids': ids.take(20).toList(), 'count': ids.length},
        ),
      );
      return false;
    }
  }

  /// « Oublier mes refus » : supprime le document. Une erreur remonte à
  /// l'appelant, qui la dit et propose de réessayer.
  Future<void> clear(String uid) => _doc(uid).delete();
}
