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
      find.text(
        'Correction non appliquée. Une erreur inattendue est survenue.',
      ),
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

    expect(
      find.text('Photo non envoyée. Une erreur inattendue est survenue.'),
      findsOneWidget,
    );
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

    expect(find.text('Photo non envoyée. Accès refusé.'), findsOneWidget);
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
      find.text('Photo non ouverte. Choisissez-en une autre.'),
      findsOneWidget,
    );
    expect(find.textContaining('Exception'), findsNothing);
    expect(results, [null]);
    expect(reporter.features, contains('imageEnhancerScreen.loadImage'));
  });

  group('cadre de recadrage au toucher (#211)', () {
    Future<void> pumpCrop(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: ImageEnhancerScreen(
            imageBytes: photo,
            mode: EnhancerMode.crop,
            onResult: (_) async {},
            errorReporter: reporter,
          ),
        ),
      );
      await settleReal(tester);
      await tester.tap(find.text('Recadrer'));
      await tester.pump();
    }

    Offset origin(WidgetTester tester) => tester.getTopLeft(
      find.byWidgetPredicate(
        (w) => w is CustomPaint && w.painter is QuadOverlayPainter,
      ),
    );

    QuadOverlayPainter painter(WidgetTester tester) {
      final paints = tester.widgetList<CustomPaint>(find.byType(CustomPaint));
      return paints.map((p) => p.painter).whereType<QuadOverlayPainter>().first;
    }

    testWidgets('marge autour de l\'image et coin qui ne saute pas', (
      tester,
    ) async {
      await pumpCrop(tester);
      final q = painter(tester);
      expect(q.fitted.left, greaterThanOrEqualTo(24));
      expect(q.fitted.right, lessThanOrEqualTo(400 - 24));

      final o = origin(tester);
      final corner =
          o +
          Offset(
            q.fitted.left + q.corners[0].dx * q.fitted.width,
            q.fitted.top + q.corners[0].dy * q.fitted.height,
          );
      // Le doigt saisit à 20 px du coin, puis bouge de 10 px : le coin suit
      // le déplacement sans passer sous le doigt.
      final gesture = await tester.startGesture(corner + const Offset(20, 0));
      await gesture.moveBy(const Offset(40, 0));
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump();
      final after = painter(tester);
      final moved = Offset(
        after.fitted.left + after.corners[0].dx * after.fitted.width,
        after.fitted.top + after.corners[0].dy * after.fitted.height,
      );
      // Sans écart conservé, le coin sauterait sous le doigt (+70 px).
      expect(moved.dx - corner.dx, lessThan(30));
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
    });

    testWidgets('un coin se pose sur le bord de l\'image', (tester) async {
      await pumpCrop(tester);
      final q = painter(tester);
      final o = origin(tester);
      final corner =
          o +
          Offset(
            q.fitted.left + q.corners[0].dx * q.fitted.width,
            q.fitted.top + q.corners[0].dy * q.fitted.height,
          );
      final gesture = await tester.startGesture(corner);
      await gesture.moveTo(o + const Offset(40, 40));
      await gesture.moveTo(o + const Offset(2, 2));
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
      expect(painter(tester).corners[0], const Offset(0, 0));
    });

    testWidgets('toucher loin de tout coin : le plus proche est saisi', (
      tester,
    ) async {
      await pumpCrop(tester);
      final q = painter(tester);
      final o = origin(tester);
      final centre = o + q.fitted.center;
      final gesture = await tester.startGesture(centre);
      await gesture.moveBy(const Offset(-30, -30));
      await gesture.moveBy(const Offset(-10, -10));
      await tester.pump();
      expect(painter(tester).corners[0], isNot(q.corners[0]));
      await gesture.up();
      await tester.pump(const Duration(seconds: 1));
    });
  });
}
