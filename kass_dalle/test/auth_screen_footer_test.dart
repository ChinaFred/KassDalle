import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kass_dalle/core/app_links.dart';
import 'package:kass_dalle/core/app_version.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/features/admin/presentation/admin_providers.dart';
import 'package:kass_dalle/features/auth/data/auth_repository.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/auth/presentation/auth_screen_footer.dart';
import 'package:kass_dalle/features/auth/presentation/login_screen.dart';
import 'package:kass_dalle/features/auth/presentation/pending_approval_screen.dart';

/// La connexion automatique des builds de débogage n'aboutit pas : l'écran
/// reste affiché.
class _IdleAuthRepository implements AuthRepository {
  @override
  Future<AppUser?> signInWithGoogle({bool forceAccountChooser = false}) async =>
      null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeErrorReports extends Fake implements ErrorReportService {}

/// Les règles de confidentialité et les conditions d'utilisation se lisent
/// depuis l'écran de connexion, avant d'accorder l'accès au compte Google :
/// l'écran de connexion et la salle d'attente portent les deux liens,
/// au-dessus du numéro de version.
void main() {
  void expectFooter() {
    expect(find.text(kPrivacyPolicyLabel), findsOneWidget);
    expect(find.text(kTermsOfUseLabel), findsOneWidget);
    expect(find.text('v$kAppVersion'), findsOneWidget);
  }

  test('les deux pages sont des fichiers statiques du site', () {
    expect(
      kPrivacyPolicyUrl,
      'https://kassdale-6d948.web.app/confidentialite.html',
    );
    expect(kTermsOfUseUrl, 'https://kassdale-6d948.web.app/conditions.html');
  });

  testWidgets('l’écran de connexion porte les deux liens', (tester) async {
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => const LoginScreen())],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(_IdleAuthRepository()),
          errorReportServiceProvider.overrideWithValue(_FakeErrorReports()),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    expectFooter();
  });

  testWidgets('la salle d’attente porte les deux liens', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [appUserProvider.overrideWith((ref) => Stream.value(null))],
        child: const MaterialApp(home: PendingApprovalScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expectFooter();
  });
}
