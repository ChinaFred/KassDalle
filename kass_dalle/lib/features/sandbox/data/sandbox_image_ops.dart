/// Opérations d'image propres au bac à sable, exécutées dans un isolate.
///
/// Le redressement, lui, n'est pas ici : il appelle `detectCornersIsolate` et
/// `warpIsolate` de `core/presentation/image_enhancer_processing.dart` tels
/// qu'ils sont. Le bac à sable s'appuie sur le code de l'application, il ne le
/// recopie que lorsqu'il doit le changer.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

class SandboxDownscaleParams {
  final Uint8List bytes;

  /// Côté long visé, en pixels.
  final int maxDimension;

  const SandboxDownscaleParams({
    required this.bytes,
    required this.maxDimension,
  });
}

class SandboxDownscaleResult {
  final Uint8List bytes;
  final int width;
  final int height;

  const SandboxDownscaleResult({
    required this.bytes,
    required this.width,
    required this.height,
  });
}

/// Réduit une image avant de l'envoyer au modèle.
///
/// L'appel callable plafonne à 10 Mo, et le base64 alourdit d'un tiers ce
/// qu'on lui donne. Une photo de téléphone passe donc rarement telle quelle.
///
/// Ça ne coûte aucune précision : le modèle rend ses coins en repère
/// normalisé 0-1000, qui ne dépend pas de la taille envoyée. Les découpes,
/// elles, se feront plus tard sur les pixels d'origine.
SandboxDownscaleResult sandboxDownscaleIsolate(SandboxDownscaleParams p) {
  final source = img.decodeImage(p.bytes);
  if (source == null) throw Exception('Image illisible.');

  final longest = source.width > source.height ? source.width : source.height;
  if (longest <= p.maxDimension) {
    return SandboxDownscaleResult(
      bytes: p.bytes,
      width: source.width,
      height: source.height,
    );
  }

  final factor = p.maxDimension / longest;
  final resized = img.copyResize(
    source,
    width: (source.width * factor).round(),
    height: (source.height * factor).round(),
    interpolation: img.Interpolation.linear,
  );
  return SandboxDownscaleResult(
    bytes: Uint8List.fromList(img.encodeJpg(resized, quality: 90)),
    width: resized.width,
    height: resized.height,
  );
}
