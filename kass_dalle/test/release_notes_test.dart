import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/release_notes.dart';

void main() {
  group('parseReleaseNotes', () {
    test('lit version, date et texte', () {
      final notes = parseReleaseNotes(
        '{"versions":[{"version":"0.23.98","date":"2026-10-17","text":"Clore."},'
        '{"version":"0.23.97","date":null,"text":"Doublons."}]}',
      );
      expect(notes, hasLength(2));
      expect(notes.first.version, '0.23.98');
      expect(notes.first.date, DateTime(2026, 10, 17));
      expect(notes.first.text, 'Clore.');
      expect(notes.last.date, isNull);
    });

    test('refuse une liste vide', () {
      expect(
        () => parseReleaseNotes('{"versions":[]}'),
        throwsA(isA<FormatException>()),
      );
    });

    test('refuse une entrée sans texte', () {
      expect(
        () => parseReleaseNotes(
          '{"versions":[{"version":"0.23.98","date":"2026-10-17","text":""}]}',
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('refuse un document qui n’est pas un objet', () {
      expect(() => parseReleaseNotes('[]'), throwsA(isA<FormatException>()));
    });
  });

  test("l'asset embarqué contient six versions", () {
    final notes = parseReleaseNotes(
      File(kReleaseNotesAsset).readAsStringSync(),
    );
    expect(notes, hasLength(6));
  });
}
