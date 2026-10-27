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

  group('looksLikeEmailFragment', () {
    test('un début d\'adresse sans @ est reconnu', () {
      expect(looksLikeEmailFragment('olivier.davreux.lbe'), isTrue);
      expect(looksLikeEmailFragment('marie75'), isTrue);
    });

    test('un nom ou une adresse avec @ ne l\'est pas', () {
      expect(looksLikeEmailFragment('Marie'), isFalse);
      expect(looksLikeEmailFragment('marie.dupont@gmail.com'), isFalse);
      expect(looksLikeEmailFragment(''), isFalse);
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

  test('groupe supprimé ou propriété perdue : le message du serveur', () {
    expect(
      memberSearchRefusalMessage('not-found', "Ce groupe n'existe plus."),
      "Ce groupe n'existe plus.",
    );
    expect(
      memberSearchRefusalMessage(
        'permission-denied',
        "Seul le propriétaire du groupe peut y inviter quelqu'un.",
      ),
      "Seul le propriétaire du groupe peut y inviter quelqu'un.",
    );
    // Autres erreurs, ou message vide : message générique de l'écran.
    expect(memberSearchRefusalMessage('internal', 'Boom'), isNull);
    expect(memberSearchRefusalMessage('unavailable', null), isNull);
    expect(memberSearchRefusalMessage('not-found', '  '), isNull);
    expect(memberSearchRefusalMessage('permission-denied', null), isNull);
  });
}
