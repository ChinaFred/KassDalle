import '../../auth/domain/app_user.dart';

/// Celui qui interroge la collection `recipes`.
///
/// Firestore refuse une requête entière dès que ses règles ne peuvent pas
/// prouver, à partir des seuls filtres, que chaque résultat possible est
/// lisible : une règle n'est pas un filtre. Une recette privée ne se lit que
/// par son créateur ou un administrateur, un brouillon partagé par un
/// éditeur. Les requêtes d'un livre ou d'un statut doivent donc porter
/// `is_private == false` ou `created_by == uid` selon qui les lance — c'est
/// ce que ce type décrit.
class RecipeViewer {
  final String uid;
  final bool isAdmin;

  /// Éditeur ou administrateur : relit les brouillons partagés des autres.
  final bool canEdit;

  const RecipeViewer({
    required this.uid,
    this.isAdmin = false,
    this.canEdit = false,
  });

  factory RecipeViewer.of(AppUser user) =>
      RecipeViewer(uid: user.uid, isAdmin: user.isAdmin, canEdit: user.canEdit);
}
