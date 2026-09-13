import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/presentation/stylus_pad_text_field.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';

/// Enregistre les postes signalés, sans Firebase.
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

Widget _harness({
  required TextEditingController controller,
  StylusHandwritingProbe? probe,
  ValueChanged<String>? onChanged,
  ErrorReportService? errors,
  String? padTitle,
  bool enabled = true,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: StylusPadTextField(
          controller: controller,
          decoration: const InputDecoration(
            labelText: 'Remarque',
            hintText: 'Ex : moins de sel',
          ),
          maxLines: 4,
          handwritingProbe: probe ?? () async => true,
          onChanged: onChanged,
          errorReportService: errors,
          padTitle: padTitle,
          enabled: enabled,
        ),
      ),
    ),
  );
}

/// Pose et lève un pointeur de la sorte donnée au milieu du champ.
Future<void> _touch(WidgetTester tester, PointerDeviceKind kind) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byType(StylusPadTextField)),
    kind: kind,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

Finder get _pad => find.byKey(StylusPadTextField.padFieldKey);

void main() {
  testWidgets('un stylet posé sur le champ ouvre le pavé, qui partage le '
      'contrôleur', (tester) async {
    final controller = TextEditingController(text: 'Déjà là.');
    final changes = <String>[];
    await tester.pumpWidget(
      _harness(controller: controller, onChanged: changes.add),
    );
    expect(_pad, findsNothing);

    await _touch(tester, PointerDeviceKind.stylus);

    expect(_pad, findsOneWidget);
    expect(find.text('Terminé'), findsOneWidget);
    // Le titre du pavé reprend le libellé du champ : deux fois « Remarque ».
    expect(find.text('Remarque'), findsNWidgets(2));
    expect(find.text('Ex : moins de sel'), findsNWidgets(2));

    await tester.enterText(_pad, 'Déjà là. Moins de sel.');
    expect(controller.text, 'Déjà là. Moins de sel.');
    expect(changes, ['Déjà là. Moins de sel.']);

    await tester.tap(find.text('Terminé'));
    await tester.pumpAndSettle();
    expect(_pad, findsNothing);
    expect(controller.text, 'Déjà là. Moins de sel.');
  });

  testWidgets('le titre passé en paramètre prime sur le libellé', (
    tester,
  ) async {
    final controller = TextEditingController();
    await tester.pumpWidget(
      _harness(controller: controller, padTitle: 'Contraintes globales'),
    );
    await _touch(tester, PointerDeviceKind.stylus);
    expect(find.text('Contraintes globales'), findsOneWidget);
    expect(find.text('Remarque'), findsOneWidget);
  });

  testWidgets('un doigt n\'ouvre rien', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(_harness(controller: controller));
    await _touch(tester, PointerDeviceKind.touch);
    expect(_pad, findsNothing);
  });

  testWidgets('sans conversion sur l\'appareil, le stylet n\'ouvre rien', (
    tester,
  ) async {
    final controller = TextEditingController();
    final errors = _RecordingErrorReportService();
    await tester.pumpWidget(
      _harness(
        controller: controller,
        probe: () async => false,
        errors: errors,
      ),
    );
    await _touch(tester, PointerDeviceKind.stylus);
    expect(_pad, findsNothing);
    expect(errors.features, isEmpty);
  });

  testWidgets('une sonde qui échoue est signalée, et n\'ouvre rien', (
    tester,
  ) async {
    final controller = TextEditingController();
    final errors = _RecordingErrorReportService();
    await tester.pumpWidget(
      _harness(
        controller: controller,
        probe: () async =>
            throw PlatformException(code: 'error', message: 'sonde cassée'),
        errors: errors,
      ),
    );
    await _touch(tester, PointerDeviceKind.stylus);
    expect(_pad, findsNothing);
    expect(errors.features, ['stylus_pad_probe']);
  });

  testWidgets('un champ désactivé n\'ouvre rien', (tester) async {
    final controller = TextEditingController();
    await tester.pumpWidget(_harness(controller: controller, enabled: false));
    await _touch(tester, PointerDeviceKind.stylus);
    expect(_pad, findsNothing);
  });

  testWidgets('le champ d\'origine ne démarre pas l\'écriture système', (
    tester,
  ) async {
    final controller = TextEditingController();
    await tester.pumpWidget(_harness(controller: controller));
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.stylusHandwritingEnabled, isFalse);
  });

  // La plateforme simulée se remet à zéro dans le corps du test : le binding
  // vérifie ses invariants avant tout `tearDown`, et une variable de debug
  // encore posée fait échouer le test.
  group('sonde par défaut', () {
    testWidgets('sur Android, elle interroge Scribe', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final calls = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.scribe,
        (call) async {
          calls.add(call.method);
          return true;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.scribe,
          null,
        ),
      );
      final controller = TextEditingController();
      await tester.pumpWidget(
        _harness(controller: controller, probe: defaultStylusHandwritingProbe),
      );
      await _touch(tester, PointerDeviceKind.stylus);
      debugDefaultTargetPlatformOverride = null;
      expect(calls, ['Scribe.isFeatureAvailable']);
      expect(_pad, findsOneWidget);
    });

    testWidgets('sur un bureau, elle répond non sans rien interroger', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final controller = TextEditingController();
      final errors = _RecordingErrorReportService();
      await tester.pumpWidget(
        _harness(
          controller: controller,
          probe: defaultStylusHandwritingProbe,
          errors: errors,
        ),
      );
      await _touch(tester, PointerDeviceKind.stylus);
      debugDefaultTargetPlatformOverride = null;
      expect(_pad, findsNothing);
      expect(errors.features, isEmpty);
    });
  });
}
