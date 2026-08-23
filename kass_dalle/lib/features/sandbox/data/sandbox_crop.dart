/// Découpe des zones repérées, en illustrations autonomes.
///
/// Un simple découpage, et c'est voulu : la page est déjà à plat et à
/// l'endroit, les zones y sont des rectangles alignés sur ses bords. Il n'y a
/// plus de perspective à corriger, donc rien à rééchantillonner — chaque pixel
/// gardé est celui d'origine.
///
/// Le découpage se fait sur la page à pleine résolution, celle que
/// `sandbox_warp.dart` a rendue à 4000 px. Une zone qui occupe le quart d'une
/// double page en sort autour de 600 px de côté : de quoi juger, et de quoi
/// publier le jour où l'expérience quittera le bac à sable.
library;

import 'dart:typed_data';

import 'package:image/image.dart' as img;

class SandboxCropParams {
  final Uint8List bytes;

  /// Les rectangles à découper, quatre valeurs par zone — gauche, haut, droite,
  /// bas — en fraction de la page, dans l'ordre d'affichage.
  final List<double> rectsFlat;

  /// Marge ajoutée autour de chaque zone, en fraction de sa taille.
  ///
  /// Une zone cadrée au pixel près laisse parfois un liseré du papier voisin
  /// sur un bord et mord d'un cheveu sur l'image de l'autre. Une marge nulle
  /// est le choix par défaut : c'est le cadrage du modèle qu'on juge ici, pas
  /// une retouche.
  final double margin;

  const SandboxCropParams({
    required this.bytes,
    required this.rectsFlat,
    this.margin = 0,
  });
}

class SandboxCrop {
  final Uint8List bytes;
  final int width;
  final int height;

  const SandboxCrop({
    required this.bytes,
    required this.width,
    required this.height,
  });
}

class SandboxCropResult {
  /// Une découpe par zone, dans le même ordre. Une zone illisible rend `null`
  /// à sa place : les autres n'ont pas à disparaître avec elle.
  final List<SandboxCrop?> crops;

  const SandboxCropResult({required this.crops});
}

/// Découpe chaque zone de la page.
SandboxCropResult sandboxCropIsolate(SandboxCropParams p) {
  final source = img.decodeImage(p.bytes);
  if (source == null) throw Exception('Page illisible.');

  final crops = <SandboxCrop?>[];
  for (var i = 0; i + 3 < p.rectsFlat.length; i += 4) {
    final left = p.rectsFlat[i];
    final top = p.rectsFlat[i + 1];
    final right = p.rectsFlat[i + 2];
    final bottom = p.rectsFlat[i + 3];

    final marginX = (right - left) * p.margin;
    final marginY = (bottom - top) * p.margin;

    final x = ((left - marginX) * source.width).round().clamp(
      0,
      source.width - 1,
    );
    final y = ((top - marginY) * source.height).round().clamp(
      0,
      source.height - 1,
    );
    final width = ((right - left + 2 * marginX) * source.width).round().clamp(
      1,
      source.width - x,
    );
    final height = ((bottom - top + 2 * marginY) * source.height).round().clamp(
      1,
      source.height - y,
    );

    // Une découpe de moins de seize pixels de côté n'est pas une illustration.
    // Elle vient d'une zone mal rendue, et l'encoder ne ferait qu'ajouter une
    // vignette illisible à la galerie.
    if (width < 16 || height < 16) {
      crops.add(null);
      continue;
    }

    final cropped = img.copyCrop(
      source,
      x: x,
      y: y,
      width: width,
      height: height,
    );
    crops.add(
      SandboxCrop(
        bytes: Uint8List.fromList(img.encodeJpg(cropped, quality: 95)),
        width: cropped.width,
        height: cropped.height,
      ),
    );
  }

  return SandboxCropResult(crops: crops);
}
