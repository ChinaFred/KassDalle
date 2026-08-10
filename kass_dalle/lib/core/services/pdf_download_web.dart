import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Implémentation web : déclenche un téléchargement direct via `<a download>`.
///
/// Utilise `package:web` + `dart:js_interop` : `dart:html` est déprécié et
/// n'existe pas sur une compilation WebAssembly.
Future<void> downloadPdf(Uint8List bytes, String filename) async {
  final blob = web.Blob(
    <JSAny>[bytes.toJS].toJS,
    web.BlobPropertyBag(type: 'application/pdf'),
  );
  final url = web.URL.createObjectURL(blob);

  final anchor = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..setAttribute('download', filename)
    ..style.display = 'none';

  web.document.body!.appendChild(anchor);
  anchor.click();
  anchor.remove();
  web.URL.revokeObjectURL(url);
}
