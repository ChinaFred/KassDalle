import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/tickets/domain/ticket.dart';
import 'package:kass_dalle/features/tickets/domain/ticket_form.dart';

Ticket _createdAt(DateTime? created) => Ticket.fromMap('t', {
  'type': 'bug',
  'status': 'received',
  'created_at': created == null ? null : Timestamp.fromDate(created),
});

void main() {
  group('validateTicketForm', () {
    test('adresse e-mail dans le titre ou la description : refusée', () {
      final e = validateTicketForm(
        type: TicketType.bug,
        title: 'Contact jean@exemple.fr',
        description: 'Écrivez à marie.dupont@gmail.com svp',
      );
      expect(e.title, kTicketFormEmailMessage);
      expect(e.description, kTicketFormEmailMessage);
      expect(
        kTicketFormEmailMessage,
        "Retirez l'adresse e-mail : le ticket est publié sur un site public.",
      );
      // Une mention n'est pas une adresse.
      final ok = validateTicketForm(
        type: TicketType.bug,
        title: 'Merci @ChinaFred',
        description: 'Rien de privé ici.',
      );
      expect(ok.isValid, isTrue);
    });

    test('formulaire vide : trois fautes', () {
      final e = validateTicketForm(type: null, title: '', description: '  ');
      expect(e.isValid, isFalse);
      expect(e.type, 'Choisissez le type de ticket.');
      expect(e.title, 'Le titre doit faire au moins 5 caractères.');
      expect(e.description, isNotNull);
    });

    test('titre de quatre caractères après espaces retirés', () {
      final e = validateTicketForm(
        type: TicketType.bug,
        title: '  abcd  ',
        description: 'x',
      );
      expect(e.title, 'Le titre doit faire au moins 5 caractères.');
    });

    test('bornes hautes', () {
      final e = validateTicketForm(
        type: TicketType.bug,
        title: 'a' * 101,
        description: 'd' * 2001,
      );
      expect(e.title, isNotNull);
      expect(e.description, isNotNull);
    });

    test('formulaire correct', () {
      final e = validateTicketForm(
        type: TicketType.question,
        title: 'Cinq.',
        description: 'd' * 2000,
      );
      expect(e.isValid, isTrue);
    });
  });

  group('checkTicketScreenshot', () {
    final png = Uint8List.fromList([
      0x89,
      0x50,
      0x4E,
      0x47,
      0x0D,
      0x0A,
      0x1A,
      0x0A,
      0,
    ]);
    final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0]);

    test('PNG', () {
      final c = checkTicketScreenshot(png);
      expect(c.error, isNull);
      expect(c.screenshot!.extension, 'png');
      expect(c.screenshot!.contentType, 'image/png');
    });

    test('JPEG', () {
      final c = checkTicketScreenshot(jpeg);
      expect(c.screenshot!.extension, 'jpg');
      expect(c.screenshot!.contentType, 'image/jpeg');
    });

    test('ni PNG ni JPEG', () {
      final gif = Uint8List.fromList('GIF89a'.codeUnits);
      expect(
        checkTicketScreenshot(gif).error,
        'Seules les images PNG ou JPEG sont acceptées.',
      );
    });

    test('plus de 5 Mo', () {
      final big = Uint8List(kTicketScreenshotMaxBytes + 1)..setAll(0, png);
      expect(
        checkTicketScreenshot(big).error,
        'Cette image dépasse 5 Mo. Choisissez une image plus légère.',
      );
    });
  });

  test('chemin Storage de la capture', () {
    expect(
      ticketScreenshotPath(uid: 'u1', ticketId: 't9', extension: 'jpg'),
      'tickets/u1/t9/screenshot.jpg',
    );
  });

  group('jour de Paris', () {
    test('23 h 30 UTC en été : déjà le lendemain à Paris', () {
      expect(parisDayKey(DateTime.utc(2026, 7, 14, 22, 30)), '20260715');
    });

    test('23 h 30 UTC en hiver : le lendemain aussi (UTC+1)', () {
      expect(parisDayKey(DateTime.utc(2026, 1, 14, 23, 30)), '20260115');
    });

    test('22 h 30 UTC en hiver : encore le jour même', () {
      expect(parisDayKey(DateTime.utc(2026, 1, 14, 22, 30)), '20260114');
    });
  });

  group('Il vous reste N envois', () {
    final now = DateTime.utc(2026, 10, 13, 10);

    test('plafond lu moins les tickets du jour de Paris', () {
      final mine = [
        _createdAt(DateTime.utc(2026, 10, 13, 8)),
        _createdAt(
          DateTime.utc(2026, 10, 12, 21, 59),
        ), // 23 h 59 à Paris, la veille
        _createdAt(
          DateTime.utc(2026, 10, 12, 22, 1),
        ), // 0 h 01 à Paris, le jour même
        _createdAt(null), // horodatage serveur pas encore revenu
      ];
      expect(
        remainingTicketsToday(perMemberPerDay: 5, myTickets: mine, now: now),
        2,
      );
    });

    test('jamais négatif', () {
      final mine = List.generate(7, (_) => _createdAt(now));
      expect(
        remainingTicketsToday(perMemberPerDay: 5, myTickets: mine, now: now),
        0,
      );
    });

    test('sans plafond lu : le reste du dernier envoi, s\'il est du jour', () {
      expect(
        remainingTicketsToday(
          perMemberPerDay: null,
          myTickets: const [],
          now: now,
          lastServerRemaining: (day: '20261013', remaining: 1),
        ),
        1,
      );
      expect(
        remainingTicketsToday(
          perMemberPerDay: null,
          myTickets: const [],
          now: now,
          lastServerRemaining: (day: '20261012', remaining: 1),
        ),
        isNull,
      );
    });

    test('sans plafond ni envoi : rien à dire', () {
      expect(
        remainingTicketsToday(
          perMemberPerDay: null,
          myTickets: const [],
          now: now,
        ),
        isNull,
      );
    });

    test('annonce à partir de deux envois restants', () {
      expect(remainingTicketsNotice(3), isNull);
      expect(remainingTicketsNotice(null), isNull);
      expect(remainingTicketsNotice(2), 'Il vous reste 2 envois aujourd\'hui');
      expect(remainingTicketsNotice(1), 'Il vous reste 1 envoi aujourd\'hui');
      expect(
        remainingTicketsNotice(0),
        'Vous avez atteint le nombre de tickets permis aujourd\'hui. '
        'Réessayez demain.',
      );
    });
  });

  group('refus de submitTicket', () {
    test('plafond du membre, avec le nombre réel', () {
      final e = ticketSubmitErrorFrom(
        code: 'resource-exhausted',
        message: '',
        details: {'reason': 'member_daily_limit', 'limit': 5},
      );
      expect(e, isA<TicketMemberLimitReached>());
      expect(
        e.message,
        'Vous avez envoyé 5 tickets aujourd\'hui, réessayez demain.',
      );
    });

    test('plafond de la famille', () {
      final e = ticketSubmitErrorFrom(
        code: 'resource-exhausted',
        message: '',
        details: {'reason': 'global_daily_limit', 'limit': 30},
      );
      expect(
        e.message,
        'Trop de tickets ont été envoyés aujourd\'hui par la famille. Réessayez demain.',
      );
    });

    test('réseau', () {
      final e = ticketSubmitErrorFrom(
        code: 'unavailable',
        message: '',
        details: null,
      );
      expect(
        e.message,
        'Le ticket n\'est pas parti. Vérifiez la connexion, puis appuyez sur Envoyer.',
      );
    });

    test('autre refus : le message du serveur', () {
      final e = ticketSubmitErrorFrom(
        code: 'failed-precondition',
        message: 'Le réglage des tickets est illisible.',
        details: null,
      );
      expect(e, isA<TicketRefused>());
      expect(e.message, contains('Le réglage des tickets est illisible.'));
    });
  });

  group('TicketSubmitResult.fromMap', () {
    test('sortie du contrat', () {
      final r = TicketSubmitResult.fromMap({
        'ticketId': 'abc',
        'status': 'received',
        'remaining_today': 3,
      });
      expect(r.ticketId, 'abc');
      expect(r.status, TicketStatus.received);
      expect(r.remainingToday, 3);
    });

    test('administrateur : pas de reste', () {
      final r = TicketSubmitResult.fromMap({
        'ticketId': 'abc',
        'status': 'sending',
        'remaining_today': null,
      });
      expect(r.status, TicketStatus.sending);
      expect(r.remainingToday, isNull);
    });

    test('sans ticketId : FormatException', () {
      expect(() => TicketSubmitResult.fromMap({}), throwsFormatException);
    });
  });
}
