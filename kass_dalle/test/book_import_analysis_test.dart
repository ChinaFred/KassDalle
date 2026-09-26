import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:kass_dalle/features/recipes/data/book_import_analysis.dart';
import 'package:kass_dalle/features/recipes/data/scan_state.dart';

void main() {
  setUpAll(() async {
    await initializeDateFormatting('fr_FR');
  });

  group('BookImportAnalysis.fromMap', () {
    test('lit la réponse du serveur, coût estimé compris', () {
      final analysis = BookImportAnalysis.fromMap({
        'kind': 'pdf',
        'sizeBytes': 52428800,
        'pages': 312,
        'characters': null,
        'windows': 104,
        'titre': 'Le Riz Jaune',
        'auteur': 'Thaï Liou',
        'costPerWindowUsd': 0.14,
        'estimatedCostUsd': 14.56,
        'referenceScans': 15,
        'usdToEur': 0.92,
      });
      expect(analysis.kind, 'pdf');
      expect(analysis.pages, 312);
      expect(analysis.windows, 104);
      expect(analysis.estimatedCostUsd, closeTo(14.56, 1e-9));
      expect(analysis.referenceScans, 15);
      expect(analysis.usdToEur, closeTo(0.92, 1e-9));
    });

    test('un coût absent reste absent, il ne devient jamais zéro', () {
      final analysis = BookImportAnalysis.fromMap({
        'kind': 'epub',
        'sizeBytes': 1024,
        'windows': 12,
        'characters': 70000,
        'estimatedCostUsd': null,
        'costPerWindowUsd': null,
        'usdToEur': null,
      });
      expect(analysis.estimatedCostUsd, isNull);
      expect(analysis.costPerWindowUsd, isNull);
      expect(analysis.usdToEur, isNull);
      expect(analysis.referenceScans, 0);
    });
  });

  group('libellés', () {
    test('un PDF se dit en pages, avec le pluriel', () {
      const one = BookImportAnalysis(
        kind: 'pdf',
        sizeBytes: 0,
        windows: 1,
        pages: 1,
      );
      const many = BookImportAnalysis(
        kind: 'pdf',
        sizeBytes: 0,
        windows: 4,
        pages: 312,
      );
      expect(one.contentLabel, '1 page');
      expect(many.contentLabel, contains('312 pages'));
    });

    test('un texte se dit en caractères arrondis au millier', () {
      const analysis = BookImportAnalysis(
        kind: 'epub',
        sizeBytes: 0,
        windows: 12,
        characters: 71830,
      );
      expect(analysis.contentLabel, contains('72'));
      expect(analysis.contentLabel, contains('caractères'));
    });

    test('la taille se dit en Mo', () {
      const analysis = BookImportAnalysis(
        kind: 'pdf',
        sizeBytes: 44564480,
        windows: 1,
        pages: 3,
      );
      expect(analysis.sizeLabel, '42,5 Mo');
    });
  });

  group('ScanState — livre', () {
    test(
      'la lecture d\'un livre occupe l\'écran, la confirmation le libère',
      () {
        const reading = ScanState(
          status: ScanStatus.readingBook,
          bookStep: 'Envoi',
        );
        expect(reading.isRunning, isTrue);
        expect(reading.statusLabel, 'Envoi…');

        const waiting = ScanState(status: ScanStatus.pendingBookConfirmation);
        expect(waiting.isRunning, isFalse);
      },
    );

    test('clearBook efface l\'étape et l\'analyse', () {
      const analysis = BookImportAnalysis(
        kind: 'pdf',
        sizeBytes: 1,
        windows: 1,
        pages: 3,
      );
      final withBook = const ScanState().copyWith(
        status: ScanStatus.pendingBookConfirmation,
        bookStep: 'Lecture du livre',
        bookAnalysis: analysis,
      );
      expect(withBook.bookAnalysis, isNotNull);

      final cleared = withBook.copyWith(clearBook: true);
      expect(cleared.bookAnalysis, isNull);
      expect(cleared.bookStep, isNull);
    });

    test(
      'une valeur passée avec clearBook reste : elle décrit l\'étape qui suit',
      () {
        const analysis = BookImportAnalysis(
          kind: 'pdf',
          sizeBytes: 1,
          windows: 1,
          pages: 3,
        );
        final restarted = const ScanState()
            .copyWith(
              status: ScanStatus.pendingBookConfirmation,
              bookAnalysis: analysis,
            )
            .copyWith(
              status: ScanStatus.readingBook,
              bookStep: 'Envoi',
              clearBook: true,
            );
        expect(restarted.bookStep, 'Envoi');
        expect(restarted.bookAnalysis, isNull);
        expect(restarted.statusLabel, 'Envoi…');
      },
    );
  });

  group('plafond de l\'import', () {
    test('lit le plafond proposé et la nature de la mesure', () {
      final analysis = BookImportAnalysis.fromMap({
        'kind': 'pdf',
        'sizeBytes': 1,
        'windows': 77,
        'estimatedCostUsd': 12.4,
        'costPerWindowUsd': 0.161,
        'referenceScans': 1,
        'referenceKind': 'books',
        'suggestedBudgetUsd': 19,
        'usdToEur': 0.88,
      });
      expect(analysis.suggestedBudgetUsd, 19.0);
      expect(analysis.referenceKind, 'books');
    });

    test('un plafond proposé absent reste absent : le champ reste vide', () {
      final analysis = BookImportAnalysis.fromMap({
        'kind': 'epub',
        'sizeBytes': 1,
        'windows': 3,
      });
      expect(analysis.suggestedBudgetUsd, isNull);
      expect(analysis.referenceKind, isNull);
    });

    test('la saisie accepte la virgule comme le point', () {
      expect(parseBudgetInput('12,5'), 12.5);
      expect(parseBudgetInput('12.5'), 12.5);
      expect(parseBudgetInput(' 30 '), 30.0);
      expect(parseBudgetInput('1 500'), 1500.0);
    });

    test('zéro, un négatif, du texte ou du vide ne sont pas un plafond', () {
      expect(parseBudgetInput(''), isNull);
      expect(parseBudgetInput('   '), isNull);
      expect(parseBudgetInput('0'), isNull);
      expect(parseBudgetInput('-5'), isNull);
      expect(parseBudgetInput('beaucoup'), isNull);
      expect(parseBudgetInput('1,2,3'), isNull);
      expect(parseBudgetInput('Infinity'), isNull);
      expect(parseBudgetInput('NaN'), isNull);
    });

    test('le plafond proposé s\'écrit sans décimale inutile', () {
      expect(formatBudgetInput(30), '30');
      expect(formatBudgetInput(12.5), '12,50');
      expect(parseBudgetInput(formatBudgetInput(12.5)), 12.5);
    });
  });
}
