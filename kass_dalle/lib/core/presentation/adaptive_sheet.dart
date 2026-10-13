import 'package:flutter/material.dart';

import '../utils/platform_utils.dart';

/// Ouvre [child] en feuille du bas sur un téléphone, en boîte de dialogue
/// centrée et bornée à [maxWidth] sur grand écran
/// (`PlatformUtils.wideBreakpoint`).
///
/// Sur un écran large, une feuille du bas s'étire sur toute la largeur et
/// éloigne ses boutons du regard ; une boîte de dialogue garde le contenu
/// sous les yeux. Le même widget sert les deux : seul le cadre change.
///
/// [enableDrag] : le glisser ferme la feuille sans passer par un `PopScope`.
/// Un contenu qui doit refuser la fermeture pendant un enregistrement le met
/// à `false`.
Future<T?> showAdaptiveSheet<T>(
  BuildContext context, {
  required Widget child,
  double maxWidth = 560,
  bool enableDrag = true,
}) {
  final wide = MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;
  if (wide) {
    return showDialog<T>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    enableDrag: enableDrag,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => child,
  );
}
