import 'dart:async';

// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

import '../services/error_report_service.dart';

/// Télécharge [url] comme fichier en passant par un Blob (évite l'ouverture
/// dans un nouvel onglet sur le web). Retourne true si succès.
Future<bool> triggerWebDownload(String url, String filename) async {
  try {
    final request = html.HttpRequest();
    request.open('GET', url, async: true);
    request.responseType = 'blob';

    // ignore: unused_local_variable
    final completer = html.HttpRequest();
    final loadFuture = request.onLoad.first;
    request.send();
    await loadFuture;

    if (request.status != 200) return false;

    final blob = request.response as html.Blob;
    final objectUrl = html.Url.createObjectUrlFromBlob(blob);

    final anchor = html.AnchorElement(href: objectUrl)
      ..setAttribute('download', filename)
      ..style.display = 'none';

    html.document.body!.append(anchor);
    anchor.click();
    anchor.remove();
    html.Url.revokeObjectUrl(objectUrl);
    return true;
  } catch (e, st) {
    unawaited(
      ErrorReportService().reportError(
        feature: 'trigger_web_download',
        error: e,
        stackTrace: st,
        context: {'url': url, 'filename': filename},
      ),
    );
    return false;
  }
}

/// Déclenche le téléchargement d'un fichier via un simple lien <a download>.
/// Idéal pour les gros fichiers (APK) : n'charge pas le contenu en mémoire.
void triggerApkDownload(String url, String filename) {
  final anchor = html.AnchorElement(href: url)
    ..setAttribute('download', filename)
    ..style.display = 'none';
  html.document.body!.append(anchor);
  anchor.click();
  anchor.remove();
}
