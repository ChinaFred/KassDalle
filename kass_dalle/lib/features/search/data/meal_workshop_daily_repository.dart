import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../../../core/services/error_report_service.dart';
import '../domain/meal_workshop_menu.dart';

/// Lit le compteur de tours du jour de l'atelier repas :
/// `meal_workshop_daily/{uid}_{AAAA-MM-JJ}` (jour UTC, comme le serveur),
/// `{uid, day, count, limit, updated_at}`, écrit par le serveur seul,
/// lisible par le compte.
///
/// Une seule lecture, à l'ouverture de l'atelier : ensuite, chaque tour rend
/// le compteur avec la réponse.
class MealWorkshopDailyRepository {
  final FirebaseFirestore _firestore;
  final ErrorReportService _errorReportService;

  MealWorkshopDailyRepository({
    FirebaseFirestore? firestore,
    ErrorReportService? errorReportService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _errorReportService =
           errorReportService ?? ErrorReportService(firestore: firestore);

  static const collection = 'meal_workshop_daily';

  /// Le compteur du jour de [uid], ou `null` quand il est inconnu : lecture
  /// en échec, ou document mal formé. Document absent : le plafond par
  /// défaut, entier. Une panne de lecture est rapportée et ne bloque pas
  /// l'atelier ; l'écran n'affiche alors aucun nombre restant avant la
  /// première réponse, jamais une valeur plausible.
  Future<WorkshopQuota?> remainingFor(String uid, {DateTime? now}) async {
    final day = workshopDayKey(now ?? DateTime.now());
    try {
      final snap = await _firestore
          .collection(collection)
          .doc('${uid}_$day')
          .get();
      return WorkshopQuota.fromDaily(snap.data());
    } catch (e, st) {
      unawaited(
        _errorReportService.reportError(
          feature: 'mealWorkshop.daily.read',
          error: e,
          stackTrace: st,
          context: {'uid': uid, 'day': day},
        ),
      );
      return null;
    }
  }
}
