import 'package:flutter/foundation.dart';

import '../../auth/domain/app_user.dart';

/// Celui qui interroge la collection `recipes`.
///
/// Firestore refuse une requête entière dès que ses règles ne peuvent pas
/// prouver, à partir des seuls filtres, que chaque résultat possible est
/// lisible : une règle n'est pas un filtre. Une recette privée ne se lit que
/// par son créateur ou un administrateur ; une recette partagée d'un autre,
/// que s'il partage un groupe avec le lecteur ; un brouillon partagé, que par
/// un éditeur. Les requêtes d'un livre ou d'un statut doivent donc porter
/// `created_by == uid`, ou `is_private == false` avec `created_by in` des
/// comptes de [groupPeers] — c'est ce que ce type décrit.
class RecipeViewer {
  final String uid;
  final bool isAdmin;

  /// Éditeur ou administrateur : relit les brouillons partagés des autres.
  final bool canEdit;

  /// Les autres comptes avec qui le lecteur partage un groupe, tels que les
  /// règles les lisent (`group_reach/{uid}`). Triés, sans le lecteur.
  final List<String> groupPeers;

  const RecipeViewer({
    required this.uid,
    this.isAdmin = false,
    this.canEdit = false,
    this.groupPeers = const [],
  });

  factory RecipeViewer.of(AppUser user, {Iterable<String> peers = const []}) =>
      RecipeViewer(
        uid: user.uid,
        isAdmin: user.isAdmin,
        canEdit: user.canEdit,
        groupPeers: (peers.where((id) => id != user.uid).toSet().toList()
          ..sort()),
      );

  // Égalité par valeur : le provider qui le construit se réévalue à chaque
  // émission de la portée, et chaque nouvelle instance relancerait les flux
  // Firestore des livres ouverts.
  @override
  bool operator ==(Object other) =>
      other is RecipeViewer &&
      other.uid == uid &&
      other.isAdmin == isAdmin &&
      other.canEdit == canEdit &&
      listEquals(other.groupPeers, groupPeers);

  @override
  int get hashCode =>
      Object.hash(uid, isAdmin, canEdit, Object.hashAll(groupPeers));
}
