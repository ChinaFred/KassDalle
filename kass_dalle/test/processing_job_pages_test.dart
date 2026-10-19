import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/processing/domain/processing_job.dart';

/// Pages d'un import (ticket #156) : 21 au plus, la première comprise.
void main() {
  test('21 pages passent, 22 sont refusées avec le nombre à retirer', () {
    expect(kMaxImportPages, 21);
    expect(tooManyPagesMessage(1), isNull);
    expect(tooManyPagesMessage(kMaxImportPages), isNull);
    expect(pagesOverLimit(21), 0);
    expect(pagesOverLimit(25), 4);
    expect(
      tooManyPagesMessage(23),
      "Un import compte 21 pages au plus. Retirez 2 pages pour lancer "
      "l'analyse.",
    );
    expect(removePagesInstruction(1), "Retirez 1 page pour lancer l'analyse.");
    // Une recette part en un seul import : aucune suggestion de découpe.
    expect(tooManyPagesMessage(30), isNot(contains('découp')));
  });

  test('la borne est celle de la règle processing_jobs', () {
    // `flutter test` tourne depuis kass_dalle/.
    final rules = File('firestore.rules').readAsStringSync();
    final match = RegExp(
      r'additional_file_urls\.size\(\) <= (\d+)',
    ).firstMatch(rules);
    expect(match, isNotNull);
    expect(int.parse(match!.group(1)!), kMaxAdditionalFileUrls);
  });
}
