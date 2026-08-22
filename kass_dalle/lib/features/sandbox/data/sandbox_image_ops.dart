/// Opérations d'image propres au bac à sable, exécutées dans un isolate.
///
/// Ce qui n'est PAS ici : la recherche des quatre coins de la page. Deux
/// méthodes y ont vécu et ont été retirées.
///
/// La première cherchait un gradient franc : le bord du document devait être
/// la première transition rencontrée. Sur une page imprimée, la première
/// transition est une ligne de texte.
///
/// La seconde épluchait les couches — ce qui se détache du canapé, puis de la
/// serviette — et notait chacune sur sa clarté, sa saturation et sa densité de
/// contours. Elle rendait la serviette. Chaque réglage qui corrigeait un cas
/// en cassait un autre : un livre sur un bureau clair, une feuille volante sur
/// du bois, une double page sans rien dessous.
///
/// Savoir où s'arrête une page est une question de sens, pas de pixels. Un
/// humain ne mesure ni la saturation ni les contours : il reconnaît une page.
/// C'est le modèle qui répond, dans `functions/src/sandbox/page.ts`.
///
/// Restent ici les deux opérations qui sont bien affaire de pixels : remettre
/// l'image d'aplomb, et la réduire avant de l'envoyer. Le redressement lui-même
/// appelle `warpIsolate` de `core/presentation/image_enhancer_processing.dart`
/// tel quel.
///
/// Le **recalage** du cadre sur le bord réel du papier vit à côté, dans
/// `sandbox_snap.dart`. Ce n'est pas une détection — il ne cherche pas la page,
/// il resserre un cadre déjà posé sur elle.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

// ── Orientation ──────────────────────────────────────────────────────────────

class SandboxUprightParams {
  final Uint8List bytes;

  const SandboxUprightParams({required this.bytes});
}

class SandboxUprightResult {
  final Uint8List bytes;
  final int width;
  final int height;

  /// L'image était couchée et a été retournée.
  final bool rotated;

  const SandboxUprightResult({
    required this.bytes,
    required this.width,
    required this.height,
    required this.rotated,
  });
}

/// Applique l'orientation EXIF dans les pixels eux-mêmes.
///
/// Sans cette passe, une photo de téléphone existe en deux versions : celle que
/// Flutter affiche, qui honore l'EXIF, et celle que le paquet `image` décode,
/// qui l'ignore. Les deux sont tournées de quatre-vingt-dix degrés l'une par
/// rapport à l'autre.
///
/// Le modèle recevrait alors l'image couchée, rendrait des coins justes dans ce
/// repère-là, et le redressement les appliquerait à une image debout. Le résultat
/// est un morceau de canapé, parfaitement net.
///
/// Une seule remise d'aplomb, tout de suite après l'import, et tout le reste de
/// la chaîne parle du même repère.
SandboxUprightResult sandboxUprightIsolate(SandboxUprightParams p) {
  final source = img.decodeImage(p.bytes);
  if (source == null) throw Exception('Image illisible.');

  final upright = img.bakeOrientation(source);
  final rotated =
      upright.width != source.width || upright.height != source.height;

  // Réencodé seulement s'il s'est passé quelque chose : réencoder pour rien
  // coûterait une génération de JPEG, donc de la netteté, sans contrepartie.
  if (!rotated) {
    return SandboxUprightResult(
      bytes: p.bytes,
      width: source.width,
      height: source.height,
      rotated: false,
    );
  }

  return SandboxUprightResult(
    bytes: Uint8List.fromList(img.encodeJpg(upright, quality: 95)),
    width: upright.width,
    height: upright.height,
    rotated: true,
  );
}

// ── Réduction avant envoi au modèle ──────────────────────────────────────────

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
/// elles, se font sur les pixels d'origine.
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
