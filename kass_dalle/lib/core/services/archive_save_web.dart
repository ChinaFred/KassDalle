import 'dart:typed_data';

import '../utils/web_download_web.dart';

/// Implémentation web : téléchargement direct via `<a download>`.
Future<bool> saveArchive(Uint8List bytes, String filename) async {
  downloadBytesAsFile(bytes, filename, mimeType: 'application/zip');
  return true;
}
