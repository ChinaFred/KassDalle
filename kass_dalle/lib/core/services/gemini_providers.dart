import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'gemini_service.dart';

/// Provider global pour [GeminiService].
///
/// La consommation n'est plus enregistrée depuis le client. Elle l'est par la
/// Cloud Function qui passe l'appel, au tarif du modèle qui a réellement
/// répondu — le client, lui, ne connaît ni le moteur retenu par la politique de
/// routage, ni les jetons consommés, et écrivait donc un chiffre inventé à
/// partir d'un modèle supposé.
final geminiServiceProvider = Provider<GeminiService>((ref) {
  return GeminiService();
});
