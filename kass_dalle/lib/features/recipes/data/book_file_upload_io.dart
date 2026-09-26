import 'dart:io';

import 'package:firebase_storage/firebase_storage.dart';

/// Envoie un livre depuis le disque — version des plateformes à système de
/// fichiers.
///
/// `putFile` lit le fichier par morceaux : un livre de 300 Mo ne passe jamais
/// en mémoire. `putData` l'y aurait chargé, puis recopié au passage du canal
/// natif — deux à trois fois sa taille, sur un téléphone.
UploadTask putBookFile(Reference ref, String path, SettableMetadata metadata) {
  return ref.putFile(File(path), metadata);
}
