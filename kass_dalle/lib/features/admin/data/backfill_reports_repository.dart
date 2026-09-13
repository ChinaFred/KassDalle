import 'package:cloud_firestore/cloud_firestore.dart';

import '../domain/recipe_roles_backfill_report.dart';

/// Comptes rendus que les backfills laissent à côté de leur curseur.
///
/// Un backfill écrit `last_report` dans son document de point de contrôle
/// (`app_config/…_checkpoint`) à la fin de chaque passage. L'écran des
/// backfills le lit ici, pour qui a quitté la page avant la fin du traitement.
/// Lecture réservée aux administrateurs par les règles de sécurité, comme
/// l'écran lui-même.
class BackfillReportsRepository {
  final FirebaseFirestore _firestore;

  BackfillReportsRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  /// Même identifiant que `RECIPE_ROLES_CHECKPOINT_DOC_ID` côté serveur.
  static const recipeRolesCheckpointDocId = 'recipe_roles_backfill_checkpoint';

  /// Dernier compte rendu du backfill « Rôle des recettes dans un repas » ;
  /// `null` tant qu'aucun passage n'a fini depuis que la fonction l'écrit.
  Stream<RecipeRolesBackfillReport?> watchRecipeRolesReport() {
    return _firestore
        .collection('app_config')
        .doc(recipeRolesCheckpointDocId)
        .snapshots()
        .map((snap) {
          final raw = snap.data()?['last_report'];
          if (raw is! Map) return null;
          final report = Map<String, dynamic>.from(raw);
          final finishedAt = report['finished_at'];
          return RecipeRolesBackfillReport.fromMap(
            report,
            finishedAt: finishedAt is Timestamp ? finishedAt.toDate() : null,
          );
        });
  }
}
