import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/groups/domain/member_email_search.dart';

/// Recherche d'un membre par adresse : quand la saisie part au serveur, et
/// comment sa réponse se lit.
void main() {
  group('isEmailLikeQuery / isCompleteEmailQuery', () {
    test('un nom reste une recherche par nom', () {
      expect(isEmailLikeQuery('Marie'), isFalse);
      expect(isCompleteEmailQuery('Marie'), isFalse);
    });

    test('dès le « @ », la recherche par nom s\'arrête', () {
      expect(isEmailLikeQuery('marie@'), isTrue);
      expect(isCompleteEmailQuery('marie@'), isFalse);
      expect(isCompleteEmailQuery('marie@gmail'), isFalse);
    });

    test('une adresse complète peut partir, espaces de bord compris', () {
      expect(isCompleteEmailQuery('marie.dupont@gmail.com'), isTrue);
      expect(isCompleteEmailQuery('  Marie@Example.fr '), isTrue);
    });

    test('deux adresses ou une espace interne ne partent pas', () {
      expect(isCompleteEmailQuery('a@b.fr, c@d.fr'), isFalse);
      expect(isCompleteEmailQuery('ma rie@gmail.com'), isFalse);
    });
  });

  group('memberFromSearchResponse', () {
    test('compte trouvé : identifiant et noms publics', () {
      final profile = memberFromSearchResponse({
        'found': true,
        'uid': 'u1',
        'displayName': 'Marie Dupont',
        'preferredName': 'Mamie',
      });
      expect(profile, isNotNull);
      expect(profile!.uid, 'u1');
      expect(profile.displayName, 'Marie Dupont');
      expect(profile.displayedName, 'Mamie');
    });

    test('sans nom préféré : le prénom Google', () {
      final profile = memberFromSearchResponse({
        'found': true,
        'uid': 'u1',
        'displayName': 'Marie Dupont',
        'preferredName': null,
      });
      expect(profile!.displayedName, 'Marie');
    });

    test('aucun compte', () {
      expect(memberFromSearchResponse({'found': false}), isNull);
    });

    test('réponse mal formée : rien à inviter', () {
      expect(memberFromSearchResponse({'found': true}), isNull);
      expect(memberFromSearchResponse({'found': true, 'uid': ''}), isNull);
      expect(memberFromSearchResponse({'found': 'true', 'uid': 'u1'}), isNull);
    });
  });

  test('le message du plafond est celui affiché', () {
    expect(
      MemberSearchLimitReached.message,
      'Trop de recherches aujourd\'hui. Réessayez demain.',
    );
  });
}
