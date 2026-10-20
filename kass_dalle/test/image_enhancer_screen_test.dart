import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:kass_dalle/core/presentation/image_enhancer_processing.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/core/presentation/image_enhancer_screen.dart';

class _RecordingErrorReportService extends ErrorReportService {
  final features = <String>[];

  @override
  Future<String> reportError({
    String? userId,
    String? jobId,
    required String feature,
    required Object error,
    StackTrace? stackTrace,
    Map<String, dynamic> context = const {},
  }) async {
    features.add(feature);
    return 'report';
  }
}

/// Retoucheur d'image : les échecs de correction, d'envoi et d'ouverture
/// gardent l'écran utilisable et se disent sans texte d'exception (#180).
void main() {
  final photo = Uint8List.fromList(
    img.encodePng(img.Image(width: 16, height: 16)),
  );
  final corrigee = Uint8List.fromList([1, 2, 3, 4]);

  /// Le décodage et l'analyse tournent hors du temps simulé du test.
  Future<void> settleReal(WidgetTester tester) async {
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  late _RecordingErrorReportService reporter;

  setUp(() => reporter = _RecordingErrorReportService());

  Future<void> pumpEnhancer(
    WidgetTester tester, {
    required Uint8List bytes,
    required Future<void> Function(Uint8List?) onResult,
    Future<Uint8List> Function(WarpParams params)? warp,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ImageEnhancerScreen(
          imageBytes: bytes,
          mode: EnhancerMode.color,
          onResult: onResult,
          warp: warp,
          errorReporter: reporter,
        ),
      ),
    );
    await settleReal(tester);
  }

  testWidgets('correction impossible : écran ouvert, rien n\'est remis, '
      'message avec « Réessayer »', (tester) async {
    final results = <Uint8List?>[];
    var warps = 0;
    await pumpEnhancer(
      tester,
      bytes: photo,
      onResult: (b) async => results.add(b),
      warp: (_) async {
        warps++;
        if (warps == 1) throw StateError('isolat perdu');
        return corrigee;
      },
    );
    await tester.tap(find.text('Enregistrer'));
    await settleReal(tester);

    expect(results, isEmpty);
    expect(find.byType(ImageEnhancerScreen), findsOneWidget);
    expect(
      find.text('La correction n\'a pas pu être appliquée.'),
      findsOneWidget,
    );
    expect(find.textContaining('isolat perdu'), findsNothing);
    expect(reporter.features, contains('imageEnhancerScreen.confirm'));

    await tester.tap(find.text('Réessayer'));
    await settleReal(tester);
    expect(warps, 2);
    expect(results, [corrigee]);
  });

  testWidgets('envoi impossible puis « Réessayer » : la même photo corrigée, '
      'sans refaire la correction', (tester) async {
    final results = <Uint8List?>[];
    var sends = 0;
    var warps = 0;
    await pumpEnhancer(
      tester,
      bytes: photo,
      onResult: (b) async {
        sends++;
        if (sends == 1) throw StateError('réseau');
        results.add(b);
      },
      warp: (_) async {
        warps++;
        return corrigee;
      },
    );
    await tester.tap(find.text('Enregistrer'));
    await settleReal(tester);

    expect(find.textContaining('Envoi impossible : '), findsOneWidget);
    expect(find.textContaining('réseau'), findsNothing);
    expect(results, isEmpty);
    expect(reporter.features, contains('imageEnhancerScreen.deliverResult'));

    await tester.tap(find.text('Réessayer'));
    await settleReal(tester);
    expect(results, [corrigee]);
    expect(identical(results.single, corrigee), isTrue);
    expect(warps, 1);
  });

  testWidgets('envoi refusé (accès refusé) : pas de « Réessayer »', (
    tester,
  ) async {
    await pumpEnhancer(
      tester,
      bytes: photo,
      onResult: (_) async => throw FirebaseException(
        plugin: 'firebase_storage',
        code: 'permission-denied',
      ),
      warp: (_) async => corrigee,
    );
    await tester.tap(find.text('Enregistrer'));
    await settleReal(tester);

    expect(find.text('Envoi impossible : Accès refusé'), findsOneWidget);
    expect(find.text('Réessayer'), findsNothing);
  });

  testWidgets('photo illisible : message sans texte d\'exception, puis '
      'fermeture', (tester) async {
    final results = <Uint8List?>[];
    await pumpEnhancer(
      tester,
      bytes: Uint8List.fromList([0, 1, 2, 3]),
      onResult: (b) async => results.add(b),
    );

    expect(
      find.text(
        'Cette photo ne peut pas être ouverte. Choisissez-en une autre.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Exception'), findsNothing);
    expect(results, [null]);
    expect(reporter.features, contains('imageEnhancerScreen.loadImage'));
  });
}
