import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/gemini_providers.dart';
import 'package:kass_dalle/core/services/gemini_service.dart';
import 'package:kass_dalle/features/recipes/domain/url_import.dart';
import 'package:kass_dalle/features/recipes/presentation/url_import/url_import_dialog.dart';

/// La boîte « Importer depuis un lien » : plafond à l'ouverture, messages
/// sans nombre inventé, doublon sans titre, adresse mal formée sous le champ.
class _FakeService extends GeminiService {
  _FakeService({required this.quota, required this.result});

  /// `null` : la lecture du compteur échoue.
  final UrlImportQuota? quota;
  final UrlImportResult result;

  @override
  Future<UrlImportQuota> getUrlImportQuota() async =>
      quota ?? (throw StateError('compteur illisible'));

  @override
  Future<UrlImportResult> importRecipeFromUrl(
    String url, {
    bool force = false,
  }) async => result;
}

Future<void> _pump(WidgetTester tester, _FakeService service) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [geminiServiceProvider.overrideWithValue(service)],
      child: const MaterialApp(home: Scaffold(body: UrlImportForm())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  const plenty = UrlImportQuota(limit: 10, used: 3, remaining: 7);

  testWidgets(
    'plafond atteint dès l\'ouverture : message et « Coller le texte »',
    (tester) async {
      await _pump(
        tester,
        _FakeService(
          quota: const UrlImportQuota(limit: 10, used: 10, remaining: 0),
          result: const UrlImportResult(status: UrlImportStatus.queued),
        ),
      );
      expect(find.textContaining('limite d\'imports par lien'), findsOneWidget);
      expect(find.textContaining('(10)'), findsOneWidget);
      expect(find.text('Coller le texte'), findsOneWidget);
      expect(find.text('Importer'), findsNothing);
    },
  );

  test('plafond sans valeur du serveur : pas de nombre', () {
    expect(
      urlImportQuotaMessage(null),
      'Vous avez atteint la limite d\'imports par lien pour aujourd\'hui. '
      'Le compteur repart demain.',
    );
    expect(urlImportQuotaMessage(10), contains('(10)'));
  });

  testWidgets('plafond atteint à l\'envoi : le plafond relu à l\'ouverture', (
    tester,
  ) async {
    await _pump(
      tester,
      _FakeService(
        quota: plenty,
        result: const UrlImportResult(status: UrlImportStatus.quotaExceeded),
      ),
    );
    expect(
      find.text('Il vous reste 7 imports par lien aujourd\'hui.'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextField), 'https://a.fr/r');
    await tester.tap(find.text('Importer'));
    await tester.pumpAndSettle();
    // Le plafond relu à l'ouverture (10) sert ; le texte n'invente rien d'autre.
    expect(find.textContaining('(10)'), findsOneWidget);
  });

  testWidgets('doublon sans titre', (tester) async {
    await _pump(
      tester,
      _FakeService(
        quota: plenty,
        result: const UrlImportResult(
          status: UrlImportStatus.duplicate,
          recipeId: 'r1',
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'https://a.fr/r');
    await tester.tap(find.text('Importer'));
    await tester.pumpAndSettle();
    expect(find.text('Cette page est déjà dans vos recettes.'), findsOneWidget);
    expect(find.text('Importer quand même'), findsOneWidget);
  });

  testWidgets('adresse mal formée : erreur sous le champ', (tester) async {
    await _pump(
      tester,
      _FakeService(
        quota: plenty,
        result: const UrlImportResult(status: UrlImportStatus.queued),
      ),
    );
    await tester.enterText(find.byType(TextField), 'marmiton.org');
    await tester.tap(find.text('Importer'));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(
      field.decoration?.errorText,
      'Cette adresse n\'est pas un lien web (http ou https).',
    );
  });
}
