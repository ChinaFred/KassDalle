import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../app_version.dart';

const _kHostingUrl = 'https://kassdale-6d948.web.app';

class AppUpdateInfo {
  final String latestVersion;
  final String apkUrl;
  const AppUpdateInfo({required this.latestVersion, required this.apkUrl});
}

/// Vérifie si une mise à jour est disponible (Android uniquement).
/// Retourne [AppUpdateInfo] si une nouvelle version est disponible, null sinon.
Future<AppUpdateInfo?> checkForAppUpdate() async {
  // Uniquement pertinent sur Android
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;

  try {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final res = await http
        .get(
          Uri.parse('$_kHostingUrl/version.json?t=$ts'),
          headers: {'Cache-Control': 'no-cache'},
        )
        .timeout(const Duration(seconds: 5));

    if (res.statusCode != 200) return null;

    final json = jsonDecode(res.body) as Map<String, dynamic>;
    final latest = json['version'] as String?;
    if (latest == null || latest.isEmpty) return null;

    if (_isNewer(latest, kAppVersion)) {
      return AppUpdateInfo(
        latestVersion: latest,
        apkUrl: '$_kHostingUrl/app-release.apk',
      );
    }
    return null;
  } catch (_) {
    return null;
  }
}

/// Retourne true si [server] est plus récent que [current].
bool _isNewer(String server, String current) {
  final s = _parseVersion(server);
  final c = _parseVersion(current);
  final len = s.length > c.length ? s.length : c.length;
  for (var i = 0; i < len; i++) {
    final sv = i < s.length ? s[i] : 0;
    final cv = i < c.length ? c[i] : 0;
    if (sv > cv) return true;
    if (sv < cv) return false;
  }
  return false;
}

List<int> _parseVersion(String v) {
  return v
      .split('.')
      .map((p) => int.tryParse(p.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
      .toList();
}
