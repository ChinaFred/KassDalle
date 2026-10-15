import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'core/presentation/app_feedback.dart';
import 'core/presentation/splash_greeting.dart';
import 'core/app_version.dart';
import 'core/services/app_check.dart';
import 'core/services/error_report_service.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/theme/theme_mode_preference.dart';
import 'features/auth/data/auth_repository.dart';
import 'features/recipes/presentation/recipe_providers.dart';
import 'core/widgets/provider_retry.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // Avant tout appel : le jeton d'attestation doit être disponible quand la
  // première callable part, sans quoi elle serait comptée non attestée.
  await activateAppCheck();
  await initializeDateFormatting('fr', null);
  await initAppVersion();

  final errorReportService = ErrorReportService();

  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    unawaited(
      errorReportService.reportError(
        feature: 'flutter_error',
        error: details.exception,
        stackTrace: details.stack,
        context: {
          if (details.library != null) 'library': details.library,
          if (details.context != null)
            'context': details.context?.toDescription(),
        },
      ),
    );
  };

  PlatformDispatcher.instance.onError = (error, stackTrace) {
    unawaited(
      errorReportService.reportError(
        feature: 'platform_error',
        error: error,
        stackTrace: stackTrace,
        context: {'source': 'PlatformDispatcher.instance.onError'},
      ),
    );
    return true;
  };

  if (!kIsWeb) {
    await GoogleSignIn.instance.initialize();
  } else {
    // Retour d'une connexion par redirection : crée ou met à jour le
    // document du compte. Les erreurs sont rapportées par la méthode.
    unawaited(AuthRepository().completeRedirectSignIn());
  }

  runZonedGuarded(
    () {
      runApp(
        const ProviderScope(retry: appProviderRetry, child: KassDalleApp()),
      );
    },
    (error, stackTrace) {
      unawaited(
        errorReportService.reportError(
          feature: 'zone_error',
          error: error,
          stackTrace: stackTrace,
          context: {'source': 'runZonedGuarded'},
        ),
      );
    },
  );
}

class KassDalleApp extends ConsumerWidget {
  const KassDalleApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    // Réglage de l'appareil (Préférences › Apparence). Suit l'appareil tant
    // qu'il n'est pas lu.
    final themeMode = ref.watch(themeModeProvider).value ?? ThemeMode.system;
    // Écouté dès le démarrage : un partage Android qui ouvre l'application
    // avant la connexion attend la session dans ce provider.
    ref.listen(pendingSharedTextProvider, (_, _) {});

    return MaterialApp.router(
      title: "Kass'dalle",
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      // L'application est écrite en français ; les widgets fournis par Flutter
      // (sélecteur de date, menus de sélection de texte, tooltips de barre
      // d'app) parlaient anglais faute de délégués. Le français est imposé et
      // reste la seule langue proposée : la traduire ne fait pas partie du
      // projet, prétendre suivre la langue du téléphone non plus.
      locale: const Locale('fr'),
      supportedLocales: const [Locale('fr')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: router,
      builder: (context, child) =>
          SplashGreeting(child: child ?? const SizedBox.shrink()),
      scaffoldMessengerKey: appScaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
    );
  }
}
