import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/recipes/domain/family_ratings.dart';
import 'package:kass_dalle/features/recipes/domain/recipe_rating.dart';

RecipeRating _r(String uid, int rating, int day) => RecipeRating(
  userId: uid,
  recipeId: 'r1',
  rating: rating,
  updatedAt: DateTime(2026, 3, day),
);

FamilyRatings _family(
  List<RecipeRating> ratings, {
  Set<String> members = const {'a', 'b'},
  Map<String, String?> names = const {'a': 'Claire', 'b': 'Paul'},
}) => FamilyRatings.from(
  ratings: ratings,
  myUid: 'me',
  memberIds: members,
  nameOf: (uid) => names[uid],
);

void main() {
  group('FamilyRatings', () {
    test('moyenne et nombre comptent ma note, la liste ne la répète pas', () {
      final f = _family([_r('a', 8, 1), _r('b', 6, 2), _r('me', 7, 3)]);
      expect(f.count, 3);
      expect(f.average, 7);
      expect(f.mine, 7);
      expect(f.others.map((m) => m.userId), ['b', 'a']);
    });

    test('sans note des autres membres, pas de moyenne', () {
      expect(_family([_r('me', 9, 1)]).average, isNull);
      expect(_family(const []).average, isNull);
    });

    test('une note à 0 compte dans la moyenne', () {
      final f = _family([_r('a', 0, 1), _r('b', 6, 2)]);
      expect(f.count, 2);
      expect(f.average, 3);
    });

    test('un compte hors de mes groupes est écarté', () {
      final f = _family([_r('a', 8, 1), _r('stranger', 2, 2)]);
      expect(f.others.map((m) => m.userId), ['a']);
      expect(f.average, 8);
    });

    test('un compte sans profil (supprimé) est écarté', () {
      final f = _family(
        [_r('a', 8, 1), _r('b', 2, 2)],
        names: const {'a': 'Claire', 'b': null},
      );
      expect(f.others.map((m) => m.name), ['Claire']);
      expect(f.count, 1);
    });
  });

  group('formatRatingAverage', () {
    test('masque « ,0 »', () => expect(formatRatingAverage(7), '7'));
    test('une décimale, virgule', () {
      expect(formatRatingAverage(7.5), '7,5');
      expect(formatRatingAverage(20 / 3), '6,7');
    });
    test('arrondi vers l’entier', () => expect(formatRatingAverage(7.96), '8'));
  });
}
