import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// Version de l'application, synchronisée automatiquement avec pubspec.yaml.
///
/// Stratégie :
/// - Mobile/Desktop : on lit le bundle natif (package_info_plus).
/// - Web : on fetch directement `version.json` (généré à chaque
///   `flutter build web`), car package_info_plus retourne parfois "0.0.0" sur
///   web release.
///
/// Initialisée une seule fois au démarrage par [initAppVersion].
String kAppVersion = '...';

Future<void> initAppVersion() async {
  try {
    if (kIsWeb) {
      // Cache-bust pour ne jamais lire une vieille version.json mise en cache.
      final ts = DateTime.now().millisecondsSinceEpoch;
      final res = await http.get(Uri.parse('version.json?t=$ts'));
      if (res.statusCode == 200) {
        final json = jsonDecode(res.body) as Map<String, dynamic>;
        final v = json['version'];
        if (v is String && v.isNotEmpty) {
          kAppVersion = v;
          return;
        }
      }
    }
    final info = await PackageInfo.fromPlatform();
    if (info.version.isNotEmpty) kAppVersion = info.version;
  } catch (e) {
    debugPrint('[initAppVersion] error: $e');
  }
}
