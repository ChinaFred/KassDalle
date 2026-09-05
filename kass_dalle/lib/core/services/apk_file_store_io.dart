import 'dart:io';

/// Écriture de l'APK téléchargé — version des plateformes à système de
/// fichiers. Seule Android l'exécute réellement.

/// Écrit le flux dans [path]. Le fichier est ouvert en écrasement : une reprise
/// après annulation repart de zéro plutôt que de coller deux moitiés d'APK.
Future<void> writeChunks(String path, Stream<List<int>> chunks) async {
  final sink = File(path).openWrite();
  try {
    await sink.addStream(chunks);
  } finally {
    await sink.close();
  }
}

/// Vide le dossier des mises à jour. Un APK pèse près de 90 Mo : garder celui
/// de la version précédente ne sert à rien et occupe le cache.
Future<void> clearDirectory(String path) async {
  final dir = Directory(path);
  if (!dir.existsSync()) return;
  for (final entity in dir.listSync()) {
    await entity.delete(recursive: true);
  }
}

Future<int?> fileSize(String path) async {
  final file = File(path);
  if (!file.existsSync()) return null;
  return file.length();
}
