import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../services/error_report_service.dart';

/// Crée un `<a download>` invisible, le clique, puis le retire du DOM.
web.HTMLAnchorElement _makeDownloadAnchor(String href, String filename) {
  return web.document.createElement('a') as web.HTMLAnchorElement
    ..href = href
    ..setAttribute('download', filename)
    ..style.display = 'none';
}

void _clickAndDispose(web.HTMLAnchorElement anchor) {
  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
}

/// Déclenche le téléchargement d'octets déjà en mémoire.
///
/// Seul endroit du projet qui fabrique une ancre de téléchargement à partir
/// d'un Blob. L'export PDF en avait sa propre copie, à l'identique : deux
/// façons d'écrire la même manipulation de DOM, dont une seule aurait été
/// corrigée le jour où le navigateur change d'avis sur `revokeObjectURL`.
void downloadBytesAsFile(
  Uint8List bytes,
  String filename, {
  required String mimeType,
}) {
  final blob = web.Blob(
    <JSAny>[bytes.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  final url = web.URL.createObjectURL(blob);
  _clickAndDispose(_makeDownloadAnchor(url, filename));
  web.URL.revokeObjectURL(url);
}

/// Télécharge [url] comme fichier en passant par un Blob (évite l'ouverture
/// dans un nouvel onglet sur le web). Retourne true si succès.
///
/// Utilise `package:web` + `dart:js_interop` : `dart:html` est déprécié et
/// n'existe pas sur une compilation WebAssembly.
Future<bool> triggerWebDownload(String url, String filename) async {
  try {
    final request = web.XMLHttpRequest();
    request.open('GET', url, true);
    request.responseType = 'blob';

    final completed = Completer<void>();
    request.addEventListener(
      'load',
      ((web.Event _) {
        if (!completed.isCompleted) completed.complete();
      }).toJS,
    );
    request.addEventListener(
      'error',
      ((web.Event _) {
        if (!completed.isCompleted) {
          completed.completeError(
            StateError('Échec réseau lors du téléchargement de $filename'),
          );
        }
      }).toJS,
    );

    request.send();
    await completed.future;

    if (request.status != 200) return false;

    final blob = request.response as web.Blob;
    final objectUrl = web.URL.createObjectURL(blob);
    _clickAndDispose(_makeDownloadAnchor(objectUrl, filename));
    web.URL.revokeObjectURL(objectUrl);
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

/// Déclenche le téléchargement d'un fichier via un simple lien `<a download>`.
/// Idéal pour les gros fichiers (APK) : ne charge pas le contenu en mémoire.
void triggerApkDownload(String url, String filename) {
  _clickAndDispose(_makeDownloadAnchor(url, filename));
}
