import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/books_archive_export.dart';
import 'package:kass_dalle/features/books/presentation/export_my_books_flow.dart';

void main() {
  group('zipBookPdfs', () {
    test('range un PDF par livre, octets intacts', () {
      final zip = zipBookPdfs([
        (filename: 'Tartes.pdf', bytes: Uint8List.fromList([1, 2, 3])),
        (filename: 'Soupes.pdf', bytes: Uint8List.fromList([4, 5])),
      ]);
      final archive = ZipDecoder().decodeBytes(zip);
      expect(archive.files.map((f) => f.name), ['Tartes.pdf', 'Soupes.pdf']);
      expect(archive.files.first.content, [1, 2, 3]);
      expect(archive.files.last.content, [4, 5]);
    });

    test('deux livres du même titre ne s\'écrasent pas', () {
      final zip = zipBookPdfs([
        (filename: 'Tartes.pdf', bytes: Uint8List.fromList([1])),
        (filename: 'tartes.pdf', bytes: Uint8List.fromList([2])),
        (filename: 'Tartes.pdf', bytes: Uint8List.fromList([3])),
      ]);
      final names = ZipDecoder().decodeBytes(zip).files.map((f) => f.name);
      expect(names, ['Tartes.pdf', 'tartes (2).pdf', 'Tartes (3).pdf']);
    });
  });

  test('uniqueArchiveName garde un nom libre tel quel', () {
    expect(uniqueArchiveName('Pains.pdf', {'tartes.pdf'}), 'Pains.pdf');
    expect(uniqueArchiveName('livre', {'livre'}), 'livre (2)');
  });

  test('libraryArchiveFilename est daté du jour', () {
    expect(
      libraryArchiveFilename(DateTime(2026, 3, 7)),
      'Bibliotheque_2026-03-07.zip',
    );
  });

  test('exportReport ne cite que les nombres non nuls', () {
    expect(exportReport(exported: 1, empty: 0, failed: 0), '1 livre exporté');
    expect(
      exportReport(exported: 8, empty: 2, failed: 1),
      '8 livres exportés, 2 sans page validée, 1 en erreur',
    );
    expect(
      exportReport(exported: 3, empty: 1, failed: 0),
      '3 livres exportés, 1 sans page validée',
    );
  });
}
