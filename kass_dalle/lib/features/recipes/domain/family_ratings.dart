import 'recipe_rating.dart';

/// Note d'un autre membre, telle que la fiche recette l'affiche.
class MemberRating {
  final String userId;
  final String name;
  final int rating;
  final DateTime updatedAt;

  const MemberRating({
    required this.userId,
    required this.name,
    required this.rating,
    required this.updatedAt,
  });
}

/// Notes de la famille sur une recette : celles des membres de mes groupes,
/// plus la mienne.
///
/// Valeur dérivée, jamais stockée : elle se recalcule à chaque lecture des
/// notes, des groupes et des profils.
class FamilyRatings {
  /// Notes des autres membres, la plus récente en tête. La mienne n'y figure
  /// pas : elle s'affiche dans « Ma note ».
  final List<MemberRating> others;

  /// Ma note, comptée dans [average] et [count].
  final int? mine;

  const FamilyRatings({required this.others, this.mine});

  /// Nombre de notes comptées : les autres membres, plus la mienne.
  int get count => others.length + (mine == null ? 0 : 1);

  /// Moyenne des notes comptées, `null` sans note d'un autre membre : seul,
  /// ma note n'a pas de moyenne à afficher.
  double? get average {
    if (others.isEmpty) return null;
    final sum = others.fold<int>(0, (s, r) => s + r.rating) + (mine ?? 0);
    return sum / count;
  }

  /// Assemble les notes de la famille.
  ///
  /// - [ratings] : toutes les notes de la recette, tous comptes confondus.
  /// - [memberIds] : les comptes qui partagent un groupe avec moi, moi exclu.
  ///   Une note hors de ce cercle n'est ni affichée ni comptée : un membre
  ///   sorti de mes groupes disparaît comme un compte supprimé.
  /// - [nameOf] : le nom d'un membre, ou `null` si son profil n'existe plus
  ///   (compte supprimé) — sa note est alors écartée.
  static FamilyRatings from({
    required List<RecipeRating> ratings,
    required String? myUid,
    required Set<String> memberIds,
    required String? Function(String uid) nameOf,
  }) {
    int? mine;
    final others = <MemberRating>[];
    for (final r in ratings) {
      if (r.userId == myUid) {
        mine = r.rating;
        continue;
      }
      if (!memberIds.contains(r.userId)) continue;
      final name = nameOf(r.userId);
      if (name == null) continue;
      others.add(
        MemberRating(
          userId: r.userId,
          name: name,
          rating: r.rating,
          updatedAt: r.updatedAt,
        ),
      );
    }
    others.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return FamilyRatings(others: others, mine: mine);
  }
}

/// Moyenne affichée : une décimale, virgule française, « ,0 » masqué.
String formatRatingAverage(double average) {
  final rounded = (average * 10).round() / 10;
  if (rounded == rounded.roundToDouble()) return rounded.toInt().toString();
  return rounded.toStringAsFixed(1).replaceAll('.', ',');
}
