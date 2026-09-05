/// Écriture de l'APK téléchargé — version des plateformes sans système de
/// fichiers (le web).
///
/// Aucune de ces fonctions n'est atteignable en pratique : `AppInstaller`
/// répond faux à `isSupported` partout ailleurs que sur Android natif, et le
/// téléchargement n'est jamais lancé. Elles existent pour que le fichier
/// compile, et elles lèvent plutôt que de mentir en silence.
Future<void> writeChunks(String path, Stream<List<int>> chunks) {
  throw UnsupportedError("Écrire un APK n'a pas de sens sur cette plateforme.");
}

Future<void> clearDirectory(String path) {
  throw UnsupportedError("Aucun système de fichiers sur cette plateforme.");
}

Future<int?> fileSize(String path) {
  throw UnsupportedError("Aucun système de fichiers sur cette plateforme.");
}
