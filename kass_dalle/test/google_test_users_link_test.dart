import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/features/admin/presentation/admin_providers.dart';
import 'package:kass_dalle/features/admin/presentation/google_test_users_link.dart';

/// Enregistre les postes signalés, sans Firebase.
class _RecordingErrorReportService extends ErrorReportService {
  final reports = <({String feature, Map<String, dynamic> context})>[];

  @override
  Future<String> reportError({
    String? userId,
    String? jobId,
    required String feature,
    required Object error,
    StackTrace? stackTrace,
    Map<String, dynamic> context = const {},
  }) async {
    reports.add((feature: feature, context: context));
    return 'report';
  }
}

void main() {
  late _RecordingErrorReportService errors;
  late List<Uri> opened;
  late bool openResult;
  String? copied;

  setUp(() {
    errors = _RecordingErrorReportService();
    opened = [];
    openResult = true;
    copied = null;
  });

  Future<void> pumpLink(WidgetTester tester, String email) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          errorReportServiceProvider.overrideWithValue(errors),
          openGoogleConsoleProvider.overrideWithValue((uri) async {
            opened.add(uri);
            return openResult;
          }),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: GoogleTestUsersLink(
              emailController: TextEditingController(text: email),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('adresse valide : copiée en minuscules, page ouverte', (
    tester,
  ) async {
    await pumpLink(tester, ' Nina@Exemple.fr ');
    await tester.tap(find.text(GoogleTestUsersLink.button));
    await tester.pumpAndSettle();
    expect(copied, 'nina@exemple.fr');
    expect(opened, [Uri.parse(kGoogleTestUsersUrl)]);
    expect(
      kGoogleTestUsersUrl,
      'https://console.cloud.google.com/auth/audience?project=kassdale-6d948',
    );
    expect(
      find.text(GoogleTestUsersLink.copied('nina@exemple.fr')),
      findsOneWidget,
    );
    expect(errors.reports, isEmpty);
  });

  testWidgets('adresse vide : page ouverte sans copie', (tester) async {
    await pumpLink(tester, '');
    await tester.tap(find.text(GoogleTestUsersLink.button));
    await tester.pumpAndSettle();
    expect(copied, isNull);
    expect(opened, hasLength(1));
    expect(find.text(GoogleTestUsersLink.noEmail), findsOneWidget);
  });

  testWidgets('ouverture refusée : rapport sans adresse, lien affiché', (
    tester,
  ) async {
    openResult = false;
    await pumpLink(tester, 'nina@exemple.fr');
    await tester.tap(find.text(GoogleTestUsersLink.button));
    await tester.pumpAndSettle();
    expect(find.text(GoogleTestUsersLink.openFailure), findsOneWidget);
    expect(find.text(kGoogleTestUsersUrl), findsOneWidget);
    final report = errors.reports.single;
    expect(report.feature, 'admin.consoleLink');
    expect(report.context.toString(), isNot(contains('nina')));
  });
}
