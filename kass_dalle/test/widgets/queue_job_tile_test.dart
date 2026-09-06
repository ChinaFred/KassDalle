import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/features/processing/domain/processing_job.dart';
import 'package:kass_dalle/features/recipes/presentation/drafts/work_queue_widgets.dart';

/// Une ligne de traitement se distingue d'un brouillon par sa couleur.
///
/// En file ou en cours : fond secondaire et liseré secondaire à gauche.
/// En erreur ou rejeté : fond et liseré d'erreur. Terminé : rien, la ligne
/// n'est de toute façon plus listée.
void main() {
  final creation = DateTime(2026, 9, 6, 14, 0);

  ProcessingJob job(ProcessingJobStatus status, {String? currentStep}) =>
      ProcessingJob(
        id: 'j1',
        type: ProcessingJobType.recipeScan,
        status: status,
        createdBy: 'uid-1',
        createdAt: creation,
        updatedAt: creation,
        fileName: 'page_01.jpg',
        fileUrl: 'https://storage/page.jpg',
        currentStep: currentStep,
      );

  /// Rend le fond du `Material` le plus proche de la tuile, son liseré, et
  /// le jeu de couleurs du thème pour comparer.
  Future<(Color?, BorderSide, ColorScheme)> pompe(
    WidgetTester tester,
    ProcessingJob job,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: QueueJobTile(
            job: job,
            isSelected: false,
            isSelecting: false,
            onTap: () {},
            onLongPress: () {},
            onRetry: () {},
            onDelete: () {},
          ),
        ),
      ),
    );
    final tuile = find.byType(ListTile);
    final fond = tester.widget<Material>(
      find.ancestor(of: tuile, matching: find.byType(Material)).first,
    );
    final boite = tester.widget<DecoratedBox>(
      find.ancestor(of: tuile, matching: find.byType(DecoratedBox)).first,
    );
    final bord = (boite.decoration as BoxDecoration).border! as Border;
    final scheme = Theme.of(tester.element(tuile)).colorScheme;
    return (fond.color, bord.left, scheme);
  }

  testWidgets('un traitement en cours porte la teinte secondaire', (
    tester,
  ) async {
    final (fond, lisere, scheme) = await pompe(
      tester,
      job(ProcessingJobStatus.processing, currentStep: 'parse'),
    );
    expect(fond, scheme.secondaryContainer.withValues(alpha: 0.35));
    expect(lisere.color, scheme.secondary);
    expect(lisere.width, 4);
  });

  testWidgets('un traitement en file porte la même teinte', (tester) async {
    final (fond, lisere, scheme) = await pompe(
      tester,
      job(ProcessingJobStatus.queued),
    );
    expect(fond, scheme.secondaryContainer.withValues(alpha: 0.35));
    expect(lisere.color, scheme.secondary);
  });

  testWidgets('un traitement en erreur porte la teinte d\'erreur', (
    tester,
  ) async {
    final (fond, lisere, scheme) = await pompe(
      tester,
      job(ProcessingJobStatus.error),
    );
    expect(fond, scheme.errorContainer.withValues(alpha: 0.35));
    expect(lisere.color, scheme.error);
  });

  testWidgets('un traitement terminé ne porte rien', (tester) async {
    final (fond, lisere, _) = await pompe(
      tester,
      job(ProcessingJobStatus.done),
    );
    expect(fond, Colors.transparent);
    expect(lisere.color, Colors.transparent);
  });
}
