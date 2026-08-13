import 'package:flutter/material.dart';

/// Largeur maximale accordée au contenu sur grand écran.
///
/// Sur un 27 pouces, une ligne d'instruction de recette faisait deux mille
/// pixels de large : au-delà d'environ 90 caractères, l'œil perd sa ligne en
/// revenant à gauche. 1200 laisse la place aux écrans qui se mettent en deux
/// colonnes au-delà de 800 — chaque colonne reste alors sous les 600.
const double kReadableMaxWidth = 1200.0;

/// Borne la largeur du contenu **et** ce que ses enfants croient avoir.
///
/// Un simple [ConstrainedBox] ne suffit pas : il rétrécit la boîte sans toucher
/// au [MediaQuery], si bien qu'un écran interrogeant `MediaQuery.sizeOf` lit
/// encore 2 500 px et se met en deux colonnes dans 1 200. Le [MediaQuery] est
/// donc réécrit avec la largeur réellement disponible.
class ReadableWidth extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const ReadableWidth({
    super.key,
    required this.child,
    this.maxWidth = kReadableMaxWidth,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    if (media.size.width <= maxWidth) return child;

    // Center + ConstrainedBox : la forme canonique. L'enfant reçoit des
    // contraintes bornées sur les deux axes, ce qu'attend le Scaffold de la
    // route ; un SizedBox aligné en haut lui laisserait la hauteur lâche.
    return Center(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxWidth),
        child: MediaQuery(
          data: media.copyWith(size: Size(maxWidth, media.size.height)),
          child: child,
        ),
      ),
    );
  }
}
