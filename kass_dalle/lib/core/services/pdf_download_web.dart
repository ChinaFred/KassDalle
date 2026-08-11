import 'dart:typed_data';

import '../utils/web_download_web.dart';

/// Implémentation web : déclenche un téléchargement direct via `<a download>`.
///
/// La fabrication de l'ancre vit dans `web_download_web.dart`, avec l'autre
/// téléchargement web du projet. Ce fichier n'existe plus que pour dire ce qui
/// distingue le PDF du reste : son type MIME, et le fait que sur mobile il part
/// dans la feuille de partage native plutôt qu'en téléchargement (voir
/// `pdf_download_stub.dart`).
Future<void> downloadPdf(Uint8List bytes, String filename) async {
  downloadBytesAsFile(bytes, filename, mimeType: 'application/pdf');
}
