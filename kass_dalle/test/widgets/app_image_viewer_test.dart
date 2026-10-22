import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/presentation/app_image_viewer.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';

/// PNG d'un pixel transparent : une image lisible, sans réseau.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

List<AppViewerImage> _images(int n) => [
  for (var i = 0; i < n; i++)
    AppViewerImage.memory(_png, semanticLabel: 'Illustration'),
];

/// Ouvre la visionneuse depuis un bouton, comme le font les écrans.
Future<void> _open(
  WidgetTester tester, {
  required List<AppViewerImage> images,
  int initialIndex = 0,
  String? title,
  String itemLabel = 'Image',
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [isAdminProvider.overrideWithValue(false)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppImageViewer(
                context,
                images: images,
                initialIndex: initialIndex,
                title: title,
                itemLabel: itemLabel,
              ),
              child: const Text('Ouvrir'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Ouvrir'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('« Fermer » ferme la visionneuse', (tester) async {
    await _open(tester, images: _images(1), title: 'Couverture');

    expect(find.byType(AppImageViewer), findsOneWidget);
    expect(find.text('Couverture'), findsOneWidget);
    // Une seule image : pas de compteur, pas de flèches.
    expect(find.text('1 / 1'), findsNothing);
    expect(find.byIcon(Icons.chevron_left), findsNothing);

    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(find.byType(AppImageViewer), findsNothing);
  });

  testWidgets('Échap ferme la visionneuse', (tester) async {
    await _open(tester, images: _images(2));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byType(AppImageViewer), findsNothing);
  });

  testWidgets('le compteur suit l\'image ouverte et se lit « 2 sur 3 »', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _open(
      tester,
      images: _images(3),
      initialIndex: 1,
      title: 'Illustrations',
      itemLabel: 'Illustration',
    );

    expect(find.text('Illustrations'), findsOneWidget);
    expect(find.text('2 / 3'), findsOneWidget);
    expect(find.bySemanticsLabel('Illustration 2 sur 3'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('les flèches changent d\'image et se désactivent aux bouts', (
    tester,
  ) async {
    await _open(tester, images: _images(3), itemLabel: 'Illustration');

    IconButton arrow(String tooltip) => tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip(tooltip),
        matching: find.byType(IconButton),
      ),
    );

    expect(find.text('1 / 3'), findsOneWidget);
    expect(arrow('Illustration précédente').onPressed, isNull);
    expect(arrow('Illustration suivante').onPressed, isNotNull);

    await tester.tap(find.byTooltip('Illustration suivante'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);

    await tester.tap(find.byTooltip('Illustration suivante'));
    await tester.pumpAndSettle();
    expect(find.text('3 / 3'), findsOneWidget);
    expect(arrow('Illustration suivante').onPressed, isNull);
    expect(arrow('Illustration précédente').onPressed, isNotNull);

    await tester.tap(find.byTooltip('Illustration précédente'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
  });

  testWidgets('les touches ← et → changent d\'image, sans dépasser les bouts', (
    tester,
  ) async {
    await _open(tester, images: _images(2));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);
  });

  testWidgets('le double appui zoome, et changer d\'image remet le zoom à 1', (
    tester,
  ) async {
    await _open(tester, images: _images(2));

    double scale() => tester
        .widget<InteractiveViewer>(find.byType(InteractiveViewer).first)
        .transformationController!
        .value
        .getMaxScaleOnAxis();

    final center = tester.getCenter(find.byType(InteractiveViewer).first);
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    expect(scale(), closeTo(kAppImageViewerDoubleTapScale, 0.001));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(scale(), closeTo(1, 0.001));
  });

  testWidgets('le glissement change d\'image, sauf quand l\'image est zoomée', (
    tester,
  ) async {
    await _open(tester, images: _images(2));
    final viewer = find.byType(PageView);

    final center = tester.getCenter(find.byType(InteractiveViewer).first);
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    await tester.fling(viewer, const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('1 / 2'), findsOneWidget);

    // Double appui : retour à 1×, le glissement change de page.
    await tester.tapAt(center);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(center);
    await tester.pumpAndSettle();
    await tester.fling(viewer, const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(find.text('2 / 2'), findsOneWidget);
  });

  testWidgets('une URL refusée affiche « Image indisponible. » sans bouton', (
    tester,
  ) async {
    await _open(
      tester,
      images: const [AppViewerImage.network('https://example.com/x.png')],
    );

    expect(find.text(kAppImageViewerErrorTitle), findsOneWidget);
    expect(find.text('Réessayer'), findsNothing);
    // Hors du zoom : un double appui n'agrandit pas le texte.
    expect(find.byType(InteractiveViewer), findsNothing);
  });

  testWidgets('des octets illisibles affichent « Image indisponible. »', (
    tester,
  ) async {
    await _open(
      tester,
      images: [
        AppViewerImage.memory(Uint8List.fromList(const [1, 2, 3, 4])),
      ],
    );
    // Le décodage est un vrai travail asynchrone, hors de l'horloge simulée.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();

    expect(find.text(kAppImageViewerErrorTitle), findsOneWidget);
    expect(find.text('Réessayer'), findsNothing);
    // Hors du zoom : un double appui n'agrandit pas le texte.
    expect(find.byType(InteractiveViewer), findsNothing);
  });
}
