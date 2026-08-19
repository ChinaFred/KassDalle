import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/moderation/domain/moderation_entry.dart';

/// Où l'écran d'administration va chercher l'image à montrer.
///
/// Ce test existe parce qu'un administrateur s'est retrouvé devant une image
/// « à revoir » sans pouvoir la regarder : elle attend en quarantaine, dossier
/// alors lisible par son seul envoyeur. Décider sans voir la photo n'est pas
/// modérer, c'est deviner.
void main() {
  ModerationEntry entry({
    required String status,
    String? rejectedPath,
    String? quarantinePath,
    String? publishedUrl,
  }) {
    return ModerationEntry.fromMap('id', {
      'status': status,
      'uid': 'u1',
      'target_kind': 'draft_illustration',
      'decision_reason': 'no_signal',
      'rejected_path': rejectedPath,
      'quarantine_path': quarantinePath,
      'published_url': publishedUrl,
    });
  }

  group('previewPath', () {
    test('une image refusée se lit dans le dossier des refus', () {
      final e = entry(
        status: 'rejected',
        rejectedPath: 'rejected/u1/photo.jpg',
        quarantinePath: 'quarantine/u1/photo.jpg',
      );
      expect(e.previewPath, 'rejected/u1/photo.jpg');
    });

    test('une image à revoir se lit dans la quarantaine', () {
      // Le cas qui a motivé ce test : sans cette source, l'écran n'affichait
      // rien et la décision se prenait à l'aveugle.
      final e = entry(
        status: 'manual_review',
        quarantinePath: 'quarantine/u1/photo.jpg',
      );
      expect(e.previewPath, 'quarantine/u1/photo.jpg');
    });

    test('une image sans verdict se lit aussi dans la quarantaine', () {
      final e = entry(
        status: 'pending',
        quarantinePath: 'quarantine/u1/photo.jpg',
      );
      expect(e.previewPath, 'quarantine/u1/photo.jpg');
    });

    test('une image publiée n\'a pas besoin de cette source', () {
      // Elle a son URL : aller la relire dans un dossier de travail serait une
      // lecture de plus pour le même octet.
      final e = entry(
        status: 'approved',
        quarantinePath: 'quarantine/u1/photo.jpg',
        publishedUrl: 'https://exemple/photo.jpg',
      );
      expect(e.previewPath, isNull);
    });

    test('un refus antérieur à la conservation ne montre rien', () {
      // Son fichier a été supprimé. L'écran doit le DIRE plutôt que de laisser
      // un blanc, sans quoi la fonctionnalité passe pour cassée.
      final e = entry(
        status: 'rejected',
        quarantinePath: 'quarantine/u1/x.jpg',
      );
      expect(e.previewPath, isNull);
    });

    test('le dossier des refus l\'emporte quand les deux existent', () {
      final e = entry(
        status: 'manual_review',
        rejectedPath: 'rejected/u1/photo.jpg',
        quarantinePath: 'quarantine/u1/photo.jpg',
      );
      expect(e.previewPath, 'rejected/u1/photo.jpg');
    });
  });

  group('awaitsDecision', () {
    test('seule « à revoir » attend quelqu\'un', () {
      expect(entry(status: 'manual_review').awaitsDecision, isTrue);
      // « Sans verdict » attend le moteur, pas un humain : le badge et le
      // chargement d'office ne doivent pas s'y déclencher.
      expect(entry(status: 'pending').awaitsDecision, isFalse);
      expect(entry(status: 'rejected').awaitsDecision, isFalse);
      expect(entry(status: 'approved').awaitsDecision, isFalse);
    });
  });
}
