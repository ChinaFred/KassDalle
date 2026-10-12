import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/error_reporting.dart';
import '../../../core/utils/platform_utils.dart';

/// Le mode d'ouverture d'une page trouvée sur le web.
///
/// Android et iOS : le navigateur intégré (Custom Tabs, SFSafariViewController),
/// au-dessus de l'application. Le retour arrière ramène à l'Explorer tel
/// qu'il était. Sans navigateur intégré ([inAppSupported] faux), le navigateur
/// de l'appareil. Web et ordinateur : le navigateur, comme avant — nouvel
/// onglet sur le web.
LaunchMode webPageLaunchModeFor({
  required TargetPlatform? host,
  required bool inAppSupported,
}) {
  final mobile = host == TargetPlatform.android || host == TargetPlatform.iOS;
  return mobile && inAppSupported
      ? LaunchMode.inAppBrowserView
      : LaunchMode.externalApplication;
}

/// Le mode d'ouverture sur cet appareil. Une question au plugin qui échoue
/// est signalée, et la page part dans le navigateur de l'appareil.
Future<LaunchMode> webPageLaunchMode() async {
  final host = PlatformUtils.hostPlatform;
  if (host != TargetPlatform.android && host != TargetPlatform.iOS) {
    return LaunchMode.externalApplication;
  }
  var supported = false;
  try {
    supported = await supportsLaunchMode(LaunchMode.inAppBrowserView);
  } catch (error, stackTrace) {
    reportUnexpectedError(
      feature: 'search.web.launchMode',
      error: error,
      stackTrace: stackTrace,
      context: {'host': '$host'},
    );
  }
  return webPageLaunchModeFor(host: host, inAppSupported: supported);
}

/// Ouvre [uri] dans le mode de [webPageLaunchMode]. Rend le mode employé,
/// ou `null` si la page n'a pas pu s'ouvrir. Les erreurs du plugin
/// remontent à l'appelant, qui les signale.
Future<LaunchMode?> openWebPage(Uri uri) async {
  final mode = await webPageLaunchMode();
  final opened = await launchUrl(uri, mode: mode);
  return opened ? mode : null;
}
