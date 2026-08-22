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

  /// Le type réel des octets rendus, jamais un type supposé.
  ///
  /// Il était écrit en dur à `image/jpeg` par l'appelant, et c'était faux dès
  /// que l'image passait sans être réencodée — une capture d'écran reste du
  /// PNG. Claude refuse alors l'appel : « the image was specified using the
  /// image/jpeg media type, but the image appears to be a image/png image ».
  /// Gemini, lui, renifle le format et répond. Le repli automatique servait
  /// donc Gemini à chaque fois, silencieusement, sur une erreur de déclaration
  /// et non sur une panne de fournisseur.
  final String mimeType;

  const SandboxDownscaleResult({
    required this.bytes,
    required this.width,
    required this.height,
    required this.mimeType,
  });
}

/// Les types d'image que les deux fournisseurs acceptent.
const _acceptedMimeTypes = {
  'image/jpeg',
  'image/png',
  'image/gif',
  'image/webp',
};

/// Le type d'un fichier image, lu dans ses premiers octets.
///
/// L'extension du fichier ment — un `.jpg` peut contenir du PNG — et le paquet
/// `image` décode sans dire ce qu'il a décodé. La signature, elle, ne ment pas.
String? sandboxSniffMimeType(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 6 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  return null;
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
    // Assez petite pour partir telle quelle — à condition de savoir dire ce
    // qu'elle est. Un format que les fournisseurs n'acceptent pas, ou qu'on ne
    // reconnaît pas, est réencodé plutôt que déclaré au hasard.
    final sniffed = sandboxSniffMimeType(p.bytes);
    if (sniffed != null && _acceptedMimeTypes.contains(sniffed)) {
      return SandboxDownscaleResult(
        bytes: p.bytes,
        width: source.width,
        height: source.height,
        mimeType: sniffed,
      );
    }
    return SandboxDownscaleResult(
      bytes: Uint8List.fromList(img.encodeJpg(source, quality: 92)),
      width: source.width,
      height: source.height,
      mimeType: 'image/jpeg',
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
    mimeType: 'image/jpeg',
  );
}

// ── Rotation par quarts de tour ──────────────────────────────────────────────

class SandboxRotateParams {
  final Uint8List bytes;

  /// Degrés dans le sens des aiguilles d'une montre : 0, 90, 180 ou 270.
  final int degrees;

  const SandboxRotateParams({required this.bytes, required this.degrees});
}

class SandboxRotateResult {
  final Uint8List bytes;
  final int width;
  final int height;

  const SandboxRotateResult({
    required this.bytes,
    required this.width,
    required this.height,
  });
}

/// Tourne l'image d'un quart de tour, d'un demi-tour ou de trois quarts.
///
/// Un multiple de quatre-vingt-dix degrés est une permutation de pixels : rien
/// n'est interpolé, rien n'est perdu. C'est ce qui permet de corriger le sens
/// d'une page sans lui coûter la netteté qu'on vient de préserver au
/// redressement.
///
/// Le paquet `image` compte les angles positifs dans le sens des aiguilles
/// d'une montre, comme le modèle qui rend la rotation. Les deux conventions se
/// rejoignent donc sans conversion — et c'est précisément pour ça qu'elle est
/// écrite ici.
SandboxRotateResult sandboxRotateIsolate(SandboxRotateParams p) {
  final source = img.decodeImage(p.bytes);
  if (source == null) throw Exception('Image illisible.');

  final normalized = ((p.degrees % 360) + 360) % 360;
  if (normalized == 0) {
    return SandboxRotateResult(
      bytes: p.bytes,
      width: source.width,
      height: source.height,
    );
  }

  final rotated = img.copyRotate(source, angle: normalized);
  return SandboxRotateResult(
    bytes: Uint8List.fromList(img.encodeJpg(rotated, quality: 95)),
    width: rotated.width,
    height: rotated.height,
  );
}
