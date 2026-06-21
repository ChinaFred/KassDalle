import 'dart:async';

import '../services/error_report_service.dart';

// Utilitaire de téléchargement de fichier.
//
// Sur le web : fetch le fichier comme Blob et déclenche un vrai téléchargement
// (évite l'ouverture dans un nouvel onglet avec launchUrl).
// Sur les autres plateformes : retourne false → l'appelant utilise launchUrl.
export 'web_download_stub.dart'
    if (dart.library.html) 'web_download_web.dart';

/// Extrait un nom de fichier lisible depuis une URL Firebase Storage.
///
/// URL format :
/// https://firebasestorage.googleapis.com/v0/b/…/o/uploads%2Fuid%2Fname.jpg?alt=media&token=…
String filenameFromStorageUrl(String url, {String fallback = 'document'}) {
  try {
    final uri = Uri.parse(url);
    // Le segment de chemin encodé est après /o/
    final oIndex = uri.path.indexOf('/o/');
    if (oIndex < 0) return fallback;
    final encoded = uri.path.substring(oIndex + 3);
    final decoded = Uri.decodeComponent(encoded);
    // Prend uniquement le dernier segment (nom de fichier)
    return decoded.split('/').last;
  } catch (e, st) {
    unawaited(
      ErrorReportService().reportError(
        feature: 'filename_from_storage_url',
        error: e,
        stackTrace: st,
        context: {'url': url, 'fallback': fallback},
      ),
    );
    return fallback;
  }
}
