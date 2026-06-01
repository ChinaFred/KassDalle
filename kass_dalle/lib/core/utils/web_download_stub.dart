/// Stub non-web : le téléchargement via blob n'est pas disponible.
Future<bool> triggerWebDownload(String url, String filename) async {
  return false;
}

/// Stub non-web : aucune action.
void triggerApkDownload(String url, String filename) {}
