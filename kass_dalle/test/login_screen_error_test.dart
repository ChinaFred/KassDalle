import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:kass_dalle/core/services/error_report_service.dart';
import 'package:kass_dalle/features/admin/presentation/admin_providers.dart';
import 'package:kass_dalle/features/auth/data/auth_repository.dart';
import 'package:kass_dalle/features/auth/domain/app_user.dart';
import 'package:kass_dalle/features/auth/presentation/auth_providers.dart';
import 'package:kass_dalle/features/auth/presentation/login_screen.dart';

/// La connexion Google échoue toujours, avec un code technique.
class _FailingAuthRepository implements AuthRepository {
  @override
  Future<AppUser?> signInWithGoogle({bool forceAccountChooser = false}) async {
    throw FirebaseAuthException(
      code: 'internal-error',
      message: 'Exception: popup blocked by the browser',
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

void main() {
  testWidgets('une erreur Firebase n’affiche ni « Exception » ni le code', (
    tester,
  ) async {
    final reports = _FakeErrorReports();
    final router = GoRouter(
      routes: [GoRoute(path: '/', builder: (_, _) => const LoginScreen())],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authRepositoryProvider.overrideWithValue(_FailingAuthRepository()),
          errorReportServiceProvider.overrideWithValue(reports),
        ],
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continuer avec Google'));
    await tester.pumpAndSettle();

    expect(find.text(kLoginErrorAdvice), findsOneWidget);
    expect(find.text('Une erreur inattendue est survenue'), findsOneWidget);
    expect(find.textContaining('Exception'), findsNothing);
    expect(find.textContaining('internal-error'), findsNothing);
    expect(find.textContaining('popup'), findsNothing);
    // L'erreur technique part dans le rapport, pas à l'écran.
    expect(reports.features, contains('loginScreen.build'));
  });

  test('une connexion perdue garde son propre conseil', () {
    final error = loginError(
      FirebaseAuthException(code: 'network-request-failed'),
    );
    expect(error.title, 'Connexion perdue');
    expect(error.advice, isNot(kLoginErrorAdvice));
  });

  test('un refus d’accès renvoie à l’administrateur de la famille', () {
    final error = loginError(FirebaseAuthException(code: 'permission-denied'));
    expect(error.title, 'Accès refusé');
    expect(error.advice, kLoginErrorAdvice);
  });
}
