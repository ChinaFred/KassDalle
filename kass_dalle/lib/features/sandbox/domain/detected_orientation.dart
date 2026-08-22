import 'package:flutter/foundation.dart';

import '../data/sandbox_image_ops.dart';
import 'sandbox_engine.dart';

/// Le sens de lecture d'une page mise à plat.
///
/// Le redressement met la page à plat, il ne la met pas à l'endroit : les
/// quatre coins décident quel côté devient le haut, et rien ne garantit que ce
/// soit le bon.
///
/// Le modèle ne rend pas un angle mais **une lettre** : celle de la case, sur
/// la planche des quatre orientations, où il sait lire. Lui demander des degrés
/// revenait à lui faire tourner une image dans sa tête, et il s'y trompait avec
/// aplomb — 98 % de confiance sur une page couchée. La correspondance
/// lettre → rotation appartient au programme, qui a composé la planche.
@immutable
class DetectedOrientation {
  /// La case retenue : A, B, C ou D.
  final String choice;

  /// Sur quoi le modèle s'est appuyé : le texte, la gravité d'une scène, la
  /// mise en page, ou rien.
  final String basis;

  /// Les trois premiers mots réellement lus dans la case retenue.
  ///
  /// C'est la pièce à conviction. Le modèle recopiait l'exemple du prompt —
  /// phrase entière et confiance comprises — en affirmant lire un titre qu'il
  /// n'avait pas vu. Une transcription se vérifie d'un coup d'œil ; une
  /// justification, non.
  final String reading;

  /// Ce qui a permis de trancher, en une phrase.
  final String note;

  final double confidence;

  final List<SandboxEngine> engines;

  const DetectedOrientation({
    required this.choice,
    required this.basis,
    required this.reading,
    required this.note,
    required this.confidence,
    required this.engines,
  });

  /// Les degrés horaires que porte la case retenue.
  ///
  /// L'ordre des cases est celui de `kSandboxSheetLabels`, décidé au moment de
  /// composer la planche. C'est le seul endroit qui fait le lien, et il est du
  /// côté qui a dessiné.
  int get rotation {
    final index = kSandboxSheetLabels.indexOf(choice);
    return index < 0 ? 0 : kSandboxSheetRotations[index];
  }

  bool get isUpright => rotation == 0;

  /// L'indice retenu, en français.
  String get basisLabel => switch (basis) {
    'texte' => 'le sens du texte',
    'image' => 'ce qui repose sur quoi dans la photo',
    'mise_en_page' => 'la mise en page',
    _ => 'aucun indice sûr',
  };

  /// Le quart de tour, en français.
  String get label => switch (rotation) {
    0 => 'déjà à l\'endroit',
    90 => 'un quart de tour horaire',
    180 => 'un demi-tour',
    270 => 'un quart de tour antihoraire',
    _ => '$rotation°',
  };

  static DetectedOrientation? fromJson(Map<String, dynamic> json) {
    final choice = (json['choice'] as String?)?.trim().toUpperCase();
    if (choice == null || !kSandboxSheetLabels.contains(choice)) return null;
    return DetectedOrientation(
      choice: choice,
      basis: (json['basis'] as String?)?.trim() ?? 'aucun',
      reading: (json['reading'] as String?)?.trim() ?? '',
      note: (json['note'] as String?)?.trim() ?? '',
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      engines: SandboxEngine.listFrom(json['engines']),
    );
  }
}
