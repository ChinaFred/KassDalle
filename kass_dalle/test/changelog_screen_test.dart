import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/app_version.dart';
import 'package:kass_dalle/core/presentation/changelog_screen.dart';
import 'package:kass_dalle/core/services/changelog_service.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/features/admin/presentation/admin_providers.dart';

const _json = '''
{"versions":[
 {"version":"0.2.3","date":"2026-10-17","text":"Texte **trois**."},
 {"version":"0.2.1","date":"2026-10-01","text":"Texte un."}
]}''';

class _FakeErrorReports extends Fake implements ErrorReportService {
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

final _reports = _FakeErrorReports();

Widget _app(Future<String> Function() load) => ProviderScope(
  retry: (_, _) => null,
  overrides: [
    changelogLoaderProvider.overrideWithValue(load),
    errorReportServiceProvider.overrideWithValue(_reports),
  ],
  child: const MaterialApp(home: ChangelogScreen()),
);

void main() {
  test('parseChangelog lit les versions dans l\'ordre du fichier', () {
    final entries = parseChangelog(_json);
    expect(entries.map((e) => e.version), ['0.2.3', '0.2.1']);
    expect(entries.first.date, DateTime(2026, 10, 17));
  });

  test('parseChangelog refuse une entrée tronquée', () {
    expect(
      () => parseChangelog('{"versions":[{"version":"0.2.3"}]}'),
      throwsA(isA<TypeError>()),
    );
  });

  testWidgets('liste les versions et repère la version installée', (
    tester,
  ) async {
    kAppVersion = '0.2.3';
    await tester.pumpWidget(_app(() async => _json));
    await tester.pumpAndSettle();

    expect(find.text('v0.2.3'), findsOneWidget);
    expect(find.text('17 octobre 2026'), findsOneWidget);
    expect(find.text('v0.2.1'), findsOneWidget);
    expect(find.text('1er octobre 2026'), findsOneWidget);
    expect(find.text('Installée'), findsOneWidget);
  });

  testWidgets('un asset illisible affiche l\'erreur et Réessayer', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      _app(() async {
        calls++;
        return 'pas du json';
      }),
    );
    await tester.pumpAndSettle();

    expect(find.text('Impossible d\'afficher les nouveautés.'), findsOneWidget);
    expect(find.text('Réessayer'), findsOneWidget);

    await tester.tap(find.text('Réessayer'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(_reports.features, ['changelog.load', 'changelog.load']);
  });
}
