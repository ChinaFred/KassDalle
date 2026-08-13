import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'core/presentation/app_feedback.dart';
import 'core/app_version.dart';
import 'core/services/error_report_service.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/widgets/provider_retry.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
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
  }

  runZonedGuarded(
    () {
      runApp(
        const ProviderScope(
          retry: appProviderRetry,
          child: KassDalleApp(),
        ),
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

    return MaterialApp.router(
      title: "Kass'dalle",
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
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
      scaffoldMessengerKey: appScaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
    );
  }
}
