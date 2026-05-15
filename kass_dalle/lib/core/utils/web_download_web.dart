// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;

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
  } catch (_) {
    return false;
  }
}
