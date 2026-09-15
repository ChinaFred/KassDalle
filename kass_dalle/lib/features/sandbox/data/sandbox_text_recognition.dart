import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../../../core/services/error_reporting.dart';

/// Reconnaissance de texte entièrement sur l'appareil, via ML Kit.
///
/// Android et iOS seulement — jamais appelée ailleurs, voir
/// `PlatformUtils.isMobile` côté appelant. Rien n'est envoyé à un serveur, et
/// rien n'est facturé.
///
/// Rend les blocs de texte en pixels de l'image fournie, pas encore en
/// fraction : c'est l'appelant qui connaît déjà la taille de cette page et
/// fait la conversion, comme pour les zones rendues par le modèle.
///
/// ML Kit ne lit pas un tableau d'octets JPEG directement sur Android : il lui
/// faut un chemin de fichier, ou une image déjà décompressée dans un format
/// brut qu'il connaît. Écrire un fichier temporaire est plus simple qu'une
/// conversion en YUV, pour un test qui n'a pas vocation à durer.
Future<List<Rect>> recognizeTextBlocksOnDevice(Uint8List pageBytes) async {
  final file = await File(
    '${Directory.systemTemp.path}${Platform.pathSeparator}'
    'sandbox_text_${DateTime.now().microsecondsSinceEpoch}.jpg',
  ).create();
  await file.writeAsBytes(pageBytes, flush: true);

  final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
  List<Rect> blocks;
  try {
    final inputImage = InputImage.fromFilePath(file.path);
    final result = await recognizer.processImage(inputImage);
    blocks = [for (final block in result.blocks) block.boundingBox];
  } finally {
    await recognizer.close();
    // Le fichier temporaire n'a plus d'usage une fois le résultat lu. Un échec
    // de suppression n'invalide pas ce résultat : il n'est signalé, jamais
    // avalé, mais ne fait pas échouer la détection pour autant.
    unawaited(
      file.delete().then(
        (_) {},
        onError: (Object error, StackTrace stackTrace) {
          reportUnexpectedError(
            feature: 'sandbox.textRecognition.tempFile',
            error: error,
            stackTrace: stackTrace,
          );
        },
      ),
    );
  }
  return blocks;
}
