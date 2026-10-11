import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/core/services/gemini_providers.dart';
import 'package:kass_dalle/core/services/gemini_service.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/recipes/data/share_intent_source.dart';
import 'package:kass_dalle/features/recipes/domain/url_import.dart';
import 'package:kass_dalle/features/recipes/presentation/recipe_providers.dart';
import 'package:kass_dalle/features/recipes/presentation/url_import/shared_link_import_host.dart';
import 'package:kass_dalle/features/recipes/presentation/url_import/url_import_dialog.dart';

/// Import d'un lien venu d'ailleurs : adresse tirée d'un texte (presse-papiers
/// au retour de Google, partage Android), boîte d'import pré-remplie, et
/// réponse selon le rôle.
/// Le canal natif de `MainActivity`, simulé : [initial] est le partage en
/// attente rendu (puis effacé) par `getInitialSharedText`, [push] imite un
/// partage reçu pendant que l'application tourne (`onSharedText`).
class _FakeShareChannel {
  _FakeShareChannel({this.initial, this.missing = false}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (missing) throw MissingPluginException();
          if (call.method != 'getInitialSharedText') return null;
          initialCalls++;
          final text = initial;
          initial = null;
          return text;
        });
  }

  static const channel = MethodChannel(ShareIntentSource.channelName);

  String? initial;
  final bool missing;
  int initialCalls = 0;

  Future<void> push(String? text) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          ShareIntentSource.channelName,
          const StandardMethodCodec().encodeMethodCall(
            MethodCall('onSharedText', text),
          ),
          (_) {},
        );
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

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
    return 'id';
  }
}

AppUser _user(UserRole role) => AppUser(
  uid: 'u1',
  email: 'u1@example.com',
  displayName: 'U1',
  role: role,
  createdAt: DateTime(2026, 1, 1),
  lastSeenAt: DateTime(2026, 1, 1),
);

class _FakeService extends GeminiService {
  final imported = <String>[];

  @override
  Future<UrlImportQuota> getUrlImportQuota() async =>
      const UrlImportQuota(limit: 10, used: 0, remaining: 10);

  @override
  Future<UrlImportResult> importRecipeFromUrl(
    String url, {
    bool force = false,
  }) async {
    imported.add(url);
    return const UrlImportResult(status: UrlImportStatus.queued);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('adresse tirée d\'un texte', () {
    test('la première adresse web, ponctuation finale retirée', () {
      expect(
        firstWebLink(
          'Blanquette de veau https://www.marmiton.org/recettes/b.aspx, top',
        ).toString(),
        'https://www.marmiton.org/recettes/b.aspx',
      );
      expect(
        firstWebLink('(voir https://site.fr/r).').toString(),
        'https://site.fr/r',
      );
      expect(
        firstWebLink('ftp://a.fr puis http://b.fr/x').toString(),
        'http://b.fr/x',
      );
    });

    test('pas d\'adresse web : null', () {
      expect(firstWebLink(null), isNull);
      expect(firstWebLink(''), isNull);
      expect(firstWebLink('marmiton.org/recette'), isNull);
      expect(firstWebLink('https://'), isNull);
    });

    test('libellé court : domaine sans www, début du chemin', () {
      expect(
        shortLinkLabel(
          Uri.parse('https://www.marmiton.org/recettes/blanquette-de-veau'),
        ),
        'marmiton.org/recettes/blanq…',
      );
      expect(shortLinkLabel(Uri.parse('https://site.fr/')), 'site.fr');
      expect(shortLinkLabel(Uri.parse('https://site.fr/r?x=1')), 'site.fr/r');
    });
  });

  group('partage reçu', () {
    test('selon le rôle et le texte', () {
      final editor = resolveSharedText(
        'Regarde https://site.fr/r',
        canEdit: true,
      );
      expect(editor.outcome, SharedTextOutcome.import);
      expect(editor.url.toString(), 'https://site.fr/r');
      expect(
        resolveSharedText('https://site.fr/r', canEdit: false).outcome,
        SharedTextOutcome.editorsOnly,
      );
      expect(
        resolveSharedText('du texte seul', canEdit: true).outcome,
        SharedTextOutcome.noWebLink,
      );
    });

    test('la source rend le partage du démarrage, puis les suivants', () async {
      final native = _FakeShareChannel(initial: 'https://a.fr/1');
      addTearDown(native.dispose);
      final source = ShareIntentSource(enabled: true);
      final received = <String>[];
      final sub = source.sharedTexts().listen(received.add);
      await pumpEventQueue();
      await native.push('  https://b.fr/2  ');
      await native.push(null);
      await pumpEventQueue();
      expect(received, ['https://a.fr/1', 'https://b.fr/2', '']);
      // Le partage du démarrage a été pris une fois, et effacé côté natif.
      expect(native.initialCalls, 1);
      expect(native.initial, isNull);
      await sub.cancel();
    });

    test('aucun partage en attente : rien n\'est émis', () async {
      final native = _FakeShareChannel();
      addTearDown(native.dispose);
      final received = <String>[];
      final sub = ShareIntentSource(
        enabled: true,
      ).sharedTexts().listen(received.add);
      await pumpEventQueue();
      expect(received, isEmpty);
      expect(native.initialCalls, 1);
      await sub.cancel();
    });

    test('Android sans réponse du code natif : panne remontée', () async {
      final native = _FakeShareChannel(missing: true);
      addTearDown(native.dispose);
      final reports = _RecordingErrorReportService();
      final received = <String>[];
      final errors = <Object>[];
      final sub = ShareIntentSource(
        enabled: true,
        errorReportService: reports,
      ).sharedTexts().listen(received.add, onError: errors.add);
      await pumpEventQueue();
      expect(received, isEmpty);
      expect(errors, isEmpty);
      expect(reports.features, ['shareIntent.receive']);
      await sub.cancel();
    });

    test('hors Android, rien', () async {
      final native = _FakeShareChannel(initial: 'https://a.fr/1');
      addTearDown(native.dispose);
      final source = ShareIntentSource(enabled: false);
      expect(await source.sharedTexts().isEmpty, isTrue);
      expect(native.initialCalls, 0);
    });
  });

  Future<_FakeService> pumpHost(
    WidgetTester tester, {
    required String shared,
    Stream<AppUser?>? account,
    UserRole role = UserRole.editor,
  }) async {
    final service = _FakeService();
    final native = _FakeShareChannel(initial: shared);
    addTearDown(native.dispose);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(
            body: SharedLinkImportHost(child: Text('Écran courant')),
          ),
        ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          geminiServiceProvider.overrideWithValue(service),
          appUserProvider.overrideWith(
            (ref) => account ?? Stream.value(_user(role)),
          ),
          shareIntentSourceProvider.overrideWithValue(
            ShareIntentSource(enabled: true),
          ),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
    return service;
  }

  String? pending(WidgetTester tester) => ProviderScope.containerOf(
    tester.element(find.text('Écran courant')),
  ).read(pendingSharedTextProvider);

  testWidgets(
    'éditeur : la boîte d\'import s\'ouvre, adresse posée, rien ne part',
    (tester) async {
      final service = await pumpHost(
        tester,
        shared: 'Blanquette https://site.fr/blanquette',
      );
      expect(find.text('Importer depuis un lien'), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'https://site.fr/blanquette');
      // L'hôte de test est un bureau : le focus est posé, Entrée envoie.
      // Sur un téléphone, il ne l'est pas (pas de clavier qui surgit).
      expect(field.autofocus, isTrue);
      expect(service.imported, isEmpty);
      await tester.tap(find.text('Importer'));
      await tester.pumpAndSettle();
      expect(service.imported, ['https://site.fr/blanquette']);
    },
  );

  testWidgets('lecteur : import réservé aux éditeurs', (tester) async {
    await pumpHost(tester, shared: 'https://site.fr/r', role: UserRole.reader);
    expect(find.text('Import réservé aux éditeurs'), findsOneWidget);
    expect(find.text('Importer depuis un lien'), findsNothing);
    await tester.tap(find.text('Fermer'));
    await tester.pumpAndSettle();
    expect(find.text('Import réservé aux éditeurs'), findsNothing);
  });

  testWidgets('partage sans adresse web : message d\'erreur', (tester) async {
    await pumpHost(tester, shared: 'une liste de courses');
    expect(
      find.text('Ce partage ne contient pas d\'adresse web.'),
      findsOneWidget,
    );
    expect(find.text('Importer depuis un lien'), findsNothing);
  });

  group('partage reçu pendant la lecture du compte', () {
    testWidgets('éditeur : la boîte s\'ouvre une fois le compte lu', (
      tester,
    ) async {
      final account = StreamController<AppUser?>();
      addTearDown(account.close);
      await pumpHost(
        tester,
        shared: 'https://site.fr/r',
        account: account.stream,
      );
      // Compte en lecture : ni refus, ni boîte, le texte attend.
      expect(find.text('Import réservé aux éditeurs'), findsNothing);
      expect(find.text('Importer depuis un lien'), findsNothing);
      expect(pending(tester), 'https://site.fr/r');
      account.add(_user(UserRole.editor));
      await tester.pumpAndSettle();
      expect(find.text('Importer depuis un lien'), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'https://site.fr/r');
      expect(find.text('Import réservé aux éditeurs'), findsNothing);
    });

    testWidgets('lecteur : le refus s\'affiche une fois le compte lu', (
      tester,
    ) async {
      final account = StreamController<AppUser?>();
      addTearDown(account.close);
      await pumpHost(
        tester,
        shared: 'https://site.fr/r',
        account: account.stream,
      );
      expect(find.text('Import réservé aux éditeurs'), findsNothing);
      account.add(_user(UserRole.reader));
      await tester.pumpAndSettle();
      expect(find.text('Import réservé aux éditeurs'), findsOneWidget);
      expect(find.text('Importer depuis un lien'), findsNothing);
    });

    testWidgets('personne de connecté : le texte reste en attente', (
      tester,
    ) async {
      final account = StreamController<AppUser?>();
      addTearDown(account.close);
      await pumpHost(
        tester,
        shared: 'https://site.fr/r',
        account: account.stream,
      );
      account.add(null);
      await tester.pumpAndSettle();
      expect(find.text('Import réservé aux éditeurs'), findsNothing);
      expect(find.text('Importer depuis un lien'), findsNothing);
      expect(pending(tester), 'https://site.fr/r');
      // La connexion arrive : le partage est traité.
      account.add(_user(UserRole.editor));
      await tester.pumpAndSettle();
      expect(find.text('Importer depuis un lien'), findsOneWidget);
    });
  });

  testWidgets('boîte ouverte sans adresse : le champ prend le focus', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [geminiServiceProvider.overrideWithValue(_FakeService())],
        child: const MaterialApp(home: Scaffold(body: UrlImportForm())),
      ),
    );
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.autofocus, isTrue);
    expect(field.controller!.text, isEmpty);
  });
}
