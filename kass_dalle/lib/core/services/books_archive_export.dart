import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'archive_save_stub.dart'
    if (dart.library.js_interop) 'archive_save_web.dart';

/// Réunit plusieurs PDF de livres dans une seule archive ZIP.
///
/// Deux livres peuvent porter le même titre : le second fichier devient
/// `Titre (2).pdf`, pour qu'aucun PDF n'en écrase un autre dans l'archive.
/// Les PDF sont déjà compressés : l'archive les range sans les recompresser.
Uint8List zipBookPdfs(List<({String filename, Uint8List bytes})> pdfs) {
  final archive = Archive();
  final used = <String>{};
  for (final pdf in pdfs) {
    final name = uniqueArchiveName(pdf.filename, used);
    used.add(name.toLowerCase());
    archive.addFile(
      ArchiveFile.bytes(name, pdf.bytes)..compression = CompressionType.none,
    );
  }
  return ZipEncoder().encodeBytes(archive);
}

/// Rend [filename], ou `base (n).ext` si le nom est déjà pris dans [used].
///
/// La comparaison ignore la casse : Windows et macOS ne distinguent pas
/// `Tartes.pdf` de `tartes.pdf` à l'extraction.
String uniqueArchiveName(String filename, Set<String> used) {
  if (!used.contains(filename.toLowerCase())) return filename;
  final dot = filename.lastIndexOf('.');
  final base = dot > 0 ? filename.substring(0, dot) : filename;
  final ext = dot > 0 ? filename.substring(dot) : '';
  var n = 2;
  while (used.contains('$base ($n)$ext'.toLowerCase())) {
    n++;
  }
  return '$base ($n)$ext';
}

/// Nom de l'archive de la bibliothèque, daté du jour : `Bibliotheque_2026-10-11.zip`.
String libraryArchiveFilename(DateTime now) {
  String two(int v) => v.toString().padLeft(2, '0');
  return 'Bibliotheque_${now.year}-${two(now.month)}-${two(now.day)}.zip';
}

/// Enregistre l'archive : téléchargement sur le web, dialogue
/// « Enregistrer sous » ailleurs. Rend `false` si l'utilisateur a annulé.
Future<bool> saveBooksArchive(Uint8List bytes, String filename) =>
    saveArchive(bytes, filename);
