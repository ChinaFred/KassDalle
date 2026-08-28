/// D'où vient une bibliothèque, et sous quel nom son propriétaire s'annonce.
///
/// Deux règles se croisent ici. Le nom préféré remplace le nom du compte
/// Google — sans lui, « Livres de Frédéric Kassbi » et « Livres de Marie
/// Kassbi » ne se distinguent qu'au deuxième mot. Et la phrase d'origine dit
/// par quel groupe familial le livre arrive : un livre lu sans savoir de qui
/// il vient est un livre qu'on croit sien.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/books/domain/library_origin.dart';

AppUser _user({required String displayName, String? preferredName}) {
  final now = DateTime(2026, 1, 1);
  return AppUser(
    uid: 'u1',
    email: 'frederic.kassbi@example.com',
    displayName: displayName,
    preferredName: preferredName,
    role: UserRole.editor,
    createdAt: now,
    lastSeenAt: now,
  );
}

void main() {
  group('nom préféré', () {
    test('par défaut, le prénom du compte Google', () {
      expect(_user(displayName: 'Frédéric Kassbi').displayedName, 'Frédéric');
    });

    test('le nom choisi prime sur le nom Google', () {
      expect(
        _user(
          displayName: 'Frédéric Kassbi',
          preferredName: 'Fred',
        ).displayedName,
        'Fred',
      );
    });

    test('un nom choisi vide ou blanc retombe sur le prénom', () {
      expect(
        _user(
          displayName: 'Frédéric Kassbi',
          preferredName: '   ',
        ).displayedName,
        'Frédéric',
      );
    });

    test('un nom Google vide se rabat sur la partie locale de l\'adresse', () {
      expect(_user(displayName: '  ').displayedName, 'frederic.kassbi');
    });

    test('les espaces multiples ne rendent pas un prénom vide', () {
      expect(_user(displayName: '  Marie   Kassbi ').displayedName, 'Marie');
    });
  });

  group('origine d\'une bibliothèque', () {
    test('la mienne se nomme sans détour', () {
      expect(
        libraryOriginLabel(isMine: true, ownerName: 'Fred', groupNames: []),
        'Ma bibliothèque',
      );
    });

    test('celle d\'un autre nomme le groupe et la personne', () {
      expect(
        libraryOriginLabel(
          isMine: false,
          ownerName: 'Fred',
          groupNames: ['Les Kassbi'],
        ),
        'Issu du groupe familial « Les Kassbi », au travers de Fred',
      );
    });

    test('deux groupes partagés se disent au pluriel', () {
      expect(
        libraryOriginLabel(
          isMine: false,
          ownerName: 'Fred',
          groupNames: ['Les Kassbi', 'Voisins'],
        ),
        'Issu des groupes familiaux « Les Kassbi » et « Voisins », '
        'au travers de Fred',
      );
    });

    test('sans groupe partagé, la personne suffit', () {
      expect(
        libraryOriginLabel(
          isMine: false,
          ownerName: 'Fred',
          groupNames: ['   '],
        ),
        'Bibliothèque de Fred',
      );
    });

    test('sans nom, on se tait plutôt que d\'écrire une phrase creuse', () {
      expect(
        libraryOriginLabel(
          isMine: false,
          ownerName: null,
          groupNames: ['Les Kassbi'],
        ),
        isNull,
      );
    });
  });
}
