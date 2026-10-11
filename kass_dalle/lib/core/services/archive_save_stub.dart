import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// Implémentation non-web : dialogue « Enregistrer sous » du système.
///
/// Sur Android et iOS, le sélecteur écrit lui-même les octets ; sur Windows,
/// `file_picker` les écrit au chemin choisi. Rend `false` si l'utilisateur a
/// fermé le dialogue sans choisir d'emplacement.
Future<bool> saveArchive(Uint8List bytes, String filename) async {
  final path = await FilePicker.saveFile(
    dialogTitle: 'Enregistrer l\'archive',
    fileName: filename,
    type: FileType.custom,
    allowedExtensions: const ['zip'],
    bytes: bytes,
  );
  return path != null;
}
