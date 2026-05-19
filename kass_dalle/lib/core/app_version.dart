import 'package:package_info_plus/package_info_plus.dart';

/// Version de l'application, synchronisée automatiquement avec pubspec.yaml
/// via le bundle natif (package_info_plus).
///
/// Initialisée une seule fois au démarrage par [initAppVersion]. Utiliser
/// [kAppVersion] partout dans l'app — plus de constante en dur à maintenir.
String kAppVersion = '0.0.0';

Future<void> initAppVersion() async {
  try {
    final info = await PackageInfo.fromPlatform();
    kAppVersion = info.version;
  } catch (_) {
    // En cas d'échec (tests, env. exotique), on garde le défaut.
  }
}
