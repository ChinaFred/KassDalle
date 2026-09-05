import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'error_report_service.dart';

/// Pont vers l'installateur d'applications d'Android.
///
/// Kass'Dalle n'est pas distribuée par un magasin : elle télécharge son propre
/// APK et le donne à installer au système. Trois gestes ne peuvent se faire
/// qu'en natif — désigner un dossier accessible au FileProvider, lire
/// l'autorisation « installer des applications inconnues », ouvrir
/// l'installateur.
///
/// Sur toute autre plateforme, chaque méthode répond « non » sans lever
/// d'erreur : le web se met à jour au rechargement, et iOS n'autorise aucune
/// installation hors App Store. L'appelant n'a donc pas à connaître la
/// plateforme, il lit [isSupported].
class AppInstaller {
  static const MethodChannel _defaultChannel = MethodChannel(
    'dev.kassbi.kass_dalle/app_installer',
  );

  final MethodChannel _channel;
  final ErrorReportService _errorReportService;

  AppInstaller({MethodChannel? channel, ErrorReportService? errorReportService})
    : _channel = channel ?? _defaultChannel,
      _errorReportService = errorReportService ?? ErrorReportService();

  /// Vrai uniquement sur l'application Android native.
  bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Dossier où écrire l'APK téléchargé, ou null si le système le refuse.
  ///
  /// C'est le seul chemin déclaré dans `res/xml/file_paths.xml` : un APK écrit
  /// ailleurs ne pourra pas être passé à l'installateur.
  Future<String?> downloadDir() =>
      _call<String>('downloadDir', feature: 'app_installer_download_dir');

  /// Vrai si l'utilisateur a déjà accordé « installer des applications
  /// inconnues » à Kass'Dalle. Faux tant qu'il ne l'a pas fait : lancer
  /// l'installation dans cet état ouvre un écran de refus.
  Future<bool> canRequestInstall() async {
    if (!isSupported) return false;
    final ok = await _call<bool>(
      'canRequestInstall',
      feature: 'app_installer_can_request',
    );
    return ok ?? false;
  }

  /// Ouvre le réglage système de l'autorisation. Retourne faux si l'écran
  /// n'existe pas (Android 7 et antérieurs) ou n'a pas pu s'ouvrir.
  Future<bool> openInstallSettings() async {
    if (!isSupported) return false;
    final ok = await _call<bool>(
      'openInstallSettings',
      feature: 'app_installer_open_settings',
    );
    return ok ?? false;
  }

  /// Passe l'APK à l'installateur du système, qui affiche son propre écran de
  /// confirmation. Retourne faux si l'intent n'a pas pu partir.
  Future<bool> installApk(String path) async {
    if (!isSupported) return false;
    final ok = await _call<bool>(
      'installApk',
      arguments: {'path': path},
      feature: 'app_installer_install',
      context: {'apk_path': path},
    );
    return ok ?? false;
  }

  Future<T?> _call<T>(
    String method, {
    Map<String, dynamic>? arguments,
    required String feature,
    Map<String, dynamic>? context,
  }) async {
    if (!isSupported) return null;
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: feature,
        error: e,
        stackTrace: st,
        context: {'method': method, ...?context},
      );
      return null;
    }
  }
}
