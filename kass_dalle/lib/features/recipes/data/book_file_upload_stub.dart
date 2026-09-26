import 'package:firebase_storage/firebase_storage.dart';

/// Envoie un livre depuis le disque — version du web, qui n'en a pas.
///
/// Inatteignable : sur le web, le sélecteur rend les octets du fichier et
/// l'envoi passe par `putData`. Le fichier existe pour que le code compile, et
/// il lève plutôt que de mentir en silence.
UploadTask putBookFile(Reference ref, String path, SettableMetadata metadata) {
  throw UnsupportedError("Aucun système de fichiers sur cette plateforme.");
}
