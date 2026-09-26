import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/processing/domain/processing_job.dart';

/// Le titre lu par l'IA remplace le nom de fichier sur la ligne de suivi.
///
/// Il est posé par le serveur après la transcription, jamais par le client :
/// `toFirestore` ne l'écrit que s'il existe, pour qu'une création de job ne
/// porte pas un champ vide.
void main() {
  final creation = DateTime(2026, 9, 6, 14, 0);

  Map<String, dynamic> document({String? titre}) => {
    'type': 'recipeScan',
    'status': 'processing',
    'created_by': 'uid-1',
    'created_at': Timestamp.fromDate(creation),
    'updated_at': Timestamp.fromDate(creation),
    'file_name': 'page_1757160000000_01.jpg',
    'file_url': 'https://storage/page.jpg',
    'titre': ?titre,
  };

  group('ProcessingJob.titre', () {
    test('absent tant que la page n\'est pas lue', () {
      final job = ProcessingJob.fromFirestore('j1', document());
      expect(job.titre, isNull);
      expect(job.toFirestore().containsKey('titre'), isFalse);
    });

    test('lu depuis le document une fois posé par le serveur', () {
      final job = ProcessingJob.fromFirestore(
        'j1',
        document(titre: 'Tarte aux pommes'),
      );
      expect(job.titre, 'Tarte aux pommes');
      expect(job.toFirestore()['titre'], 'Tarte aux pommes');
    });

    test('conservé par copyWith, qui ne le prend pas en argument', () {
      final job = ProcessingJob.fromFirestore(
        'j1',
        document(titre: 'Tarte aux pommes'),
      );
      expect(
        job.copyWith(status: ProcessingJobStatus.error).titre,
        'Tarte aux pommes',
      );
    });
  });

  group('ProcessingJob.budgetLimitUsd', () {
    Map<String, dynamic> livre({num? plafond}) => {
      ...document(),
      'type': 'bookDocumentScan',
      'budget_limit_usd': ?plafond,
    };

    test('absent d\'un job ordinaire : rien n\'est écrit', () {
      final job = ProcessingJob.fromFirestore('j1', document());
      expect(job.budgetLimitUsd, isNull);
      expect(job.toFirestore().containsKey('budget_limit_usd'), isFalse);
    });

    test('lu depuis le document d\'un livre, entier ou décimal', () {
      expect(
        ProcessingJob.fromFirestore('j1', livre(plafond: 30)).budgetLimitUsd,
        30.0,
      );
      expect(
        ProcessingJob.fromFirestore('j1', livre(plafond: 12.5)).budgetLimitUsd,
        12.5,
      );
    });

    test(
      'écrit à la création du job du livre, pour que le serveur le pose',
      () {
        final job = ProcessingJob.fromFirestore('j1', livre(plafond: 30));
        expect(job.toFirestore()['budget_limit_usd'], 30.0);
      },
    );

    test('conservé par copyWith', () {
      final job = ProcessingJob.fromFirestore('j1', livre(plafond: 30));
      expect(
        job.copyWith(status: ProcessingJobStatus.error).budgetLimitUsd,
        30.0,
      );
    });
  });
}
