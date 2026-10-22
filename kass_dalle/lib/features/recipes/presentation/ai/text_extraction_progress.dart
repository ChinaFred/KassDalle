import '../../../../core/services/gemini_service.dart' show TextExtractionStep;
import '../../../../core/utils/language_names.dart';
import 'ai_processing_overlay.dart';
import 'ai_ui_copy.dart';

/// Liste affichée par [AiProcessingOverlay] pendant la conversion d'un texte
/// collé, à partir des étapes annoncées par le serveur.
///
/// Aucune étape reçue : liste vide, l'overlay n'en affiche pas. Dès la
/// première, la liste montre la lecture et le repérage ; la traduction s'y
/// insère quand le serveur l'annonce, et seulement alors — elle n'a lieu que
/// pour un texte écrit dans une autre langue. La dernière étape reçue est en
/// cours, celles d'avant sont faites, celles d'après à venir.
List<AiProcessingStep> textExtractionProgressSteps(
  List<TextExtractionStep> received,
) {
  if (received.isEmpty) return const [];
  TextExtractionStep? translation;
  for (final step in received) {
    if (step.etape == TextExtractionStep.traduction) translation = step;
  }
  final plan = <(String, String)>[
    (TextExtractionStep.lecture, RecipeAiUiCopy.conversionStepReading),
    if (translation != null)
      (TextExtractionStep.traduction, translationStepLabel(translation.langue)),
    (TextExtractionStep.balisage, RecipeAiUiCopy.conversionStepTagging),
  ];
  final currentIndex = plan.indexWhere((p) => p.$1 == received.last.etape);
  return [
    for (var i = 0; i < plan.length; i++)
      AiProcessingStep(
        plan[i].$2,
        i < currentIndex
            ? AiProcessingStepState.done
            : i == currentIndex
            ? AiProcessingStepState.current
            : AiProcessingStepState.upcoming,
      ),
  ];
}
