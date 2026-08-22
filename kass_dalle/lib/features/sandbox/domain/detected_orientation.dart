import 'package:flutter/foundation.dart';

import 'sandbox_engine.dart';

/// Le sens de lecture d'une page mise à plat.
///
/// Le redressement met la page à plat, il ne la met pas à l'endroit : les
/// quatre coins décident quel côté devient le haut, et rien ne garantit que ce
/// soit le bon. Une photo prise en tournant autour du livre sort la tête en bas.
@immutable
class DetectedOrientation {
  /// Degrés à appliquer dans le sens des aiguilles d'une montre : 0, 90, 180
  /// ou 270.
  final int rotation;

  /// Ce qui a permis de trancher, en une phrase.
  final String note;

  final double confidence;

  final List<SandboxEngine> engines;

  const DetectedOrientation({
    required this.rotation,
    required this.note,
    required this.confidence,
    required this.engines,
  });

  bool get isUpright => rotation == 0;

  /// Le quart de tour, en français.
  String get label => switch (rotation) {
    0 => 'déjà à l\'endroit',
    90 => 'un quart de tour horaire',
    180 => 'un demi-tour',
    270 => 'un quart de tour antihoraire',
    _ => '$rotation°',
  };

  static DetectedOrientation? fromJson(Map<String, dynamic> json) {
    final rotation = (json['rotation'] as num?)?.round();
    if (rotation == null || !const [0, 90, 180, 270].contains(rotation)) {
      return null;
    }
    return DetectedOrientation(
      rotation: rotation,
      note: (json['note'] as String?)?.trim() ?? '',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      engines: SandboxEngine.listFrom(json['engines']),
    );
  }
}
