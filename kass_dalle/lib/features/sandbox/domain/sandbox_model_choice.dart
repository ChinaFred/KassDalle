import 'package:flutter/foundation.dart';

/// Le modèle qu'une expérience impose, ou l'absence de choix.
///
/// L'application choisit son moteur poste par poste dans Admin → Moteur d'IA,
/// et son modèle Claude de la même façon. Elle n'a en revanche aucun moyen de
/// choisir un modèle Gemini par poste : c'est une constante unique pour les
/// cinquante postes.
///
/// Le bac à sable a donc son propre sélecteur, qui ne touche pas au routage.
/// Sans choix, l'appel suit la politique comme n'importe quel poste.
@immutable
class SandboxModelChoice {
  /// `gemini` ou `anthropic`.
  final String provider;

  /// L'identifiant technique du modèle, tel que le fournisseur l'attend.
  final String model;

  /// Ce qui s'affiche dans le sélecteur.
  final String label;

  const SandboxModelChoice({
    required this.provider,
    required this.model,
    required this.label,
  });

  /// Un identifiant saisi à la main, hors des présélections.
  factory SandboxModelChoice.custom(String provider, String model) =>
      SandboxModelChoice(provider: provider, model: model, label: model);

  String get storageValue => '$provider|$model';

  static SandboxModelChoice? parse(String? stored) {
    if (stored == null || stored.isEmpty) return null;
    final parts = stored.split('|');
    if (parts.length != 2) return null;
    if (parts[0] != 'gemini' && parts[0] != 'anthropic') return null;
    if (parts[1].isEmpty) return null;
    final preset = kSandboxModelPresets
        .where((p) => p.provider == parts[0] && p.model == parts[1])
        .firstOrNull;
    return preset ?? SandboxModelChoice.custom(parts[0], parts[1]);
  }

  @override
  bool operator ==(Object other) =>
      other is SandboxModelChoice &&
      other.provider == provider &&
      other.model == model;

  @override
  int get hashCode => Object.hash(provider, model);
}

/// Les modèles proposés d'emblée.
///
/// La liste n'est pas fermée : le sélecteur accepte aussi un identifiant saisi
/// à la main. C'est le seul moyen d'essayer un modèle qui vient de sortir sans
/// redéployer, et c'est exactement ce qu'un bac à sable doit permettre. Un nom
/// inconnu fait échouer l'appel avec le message du fournisseur, ce qui est la
/// réponse utile.
const List<SandboxModelChoice> kSandboxModelPresets = [
  SandboxModelChoice(
    provider: 'anthropic',
    model: 'claude-opus-5',
    label: 'Claude Opus 5',
  ),
  SandboxModelChoice(
    provider: 'anthropic',
    model: 'claude-sonnet-5',
    label: 'Claude Sonnet 5',
  ),
  SandboxModelChoice(
    provider: 'anthropic',
    model: 'claude-haiku-4-5',
    label: 'Claude Haiku 4.5',
  ),
  SandboxModelChoice(
    provider: 'gemini',
    model: 'gemini-2.5-flash',
    label: 'Gemini 2.5 Flash',
  ),
];

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
