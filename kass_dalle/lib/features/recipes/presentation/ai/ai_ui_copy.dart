/// Copie UX unifiée pour les actions IA liées aux recettes.
///
/// Centraliser ces libellés évite les divergences entre écrans
/// (création, édition, détail, brouillons) et simplifie les ajustements futurs.
class RecipeAiUiCopy {
  const RecipeAiUiCopy._();

  static const appBarActionLabel = 'Améliorer avec l\'IA';
  static const appBarActionTooltip = 'Améliorer cette recette avec l\'IA';

  static const refineDialogTitle = 'Améliorer avec l\'IA';
  static const refineDialogPrimaryCta = 'Lancer l\'amélioration';
  static const refineDialogInputPrompt =
      'Précisez ce que vous voulez améliorer (optionnel) :';

  static const cooklangRefineTooltip = 'Améliorer la recette avec l\'IA';
  static const cooklangPolishTooltip =
      'Corriger et harmoniser la recette avec l\'IA';
  static const cooklangTransformTooltip = 'Transformer en CookLang avec l\'IA';

  static const generateImageLabel = 'Créer une image IA';
  static const generateImageTooltip =
      'Créer une image photo-réaliste du plat avec l\'IA';
  static const generateImageDialogTitle = 'Créer une image IA';
  static const generateImageDialogPrimaryCta = 'Générer l\'image';
  static const generateImageDialogHelper =
      'Décris le plat ou ajuste le prompt. L\'image sera photo-réaliste, avec un dressage soigné et les éléments essentiels bien visibles.';
  static const generateImageSuccess = 'Image générée par l\'IA ✓';

  static const successRecipeRefined = 'Recette améliorée par l\'IA ✓';
  static const successRecipePolished = 'Recette corrigée et harmonisée !';
  static const successRecipeTransformed = 'Recette convertie en CookLang !';

  /// Compte rendu de l'extraction des illustrations d'un scan, accordé en
  /// nombre : « 1 illustration extraite ✓ », « 3 illustrations extraites ✓ ».
  static String illustrationsExtracted(int count) => count == 1
      ? '1 illustration extraite ✓'
      : '$count illustrations extraites ✓';

  /// Message neutre : l'extraction a abouti, la page n'avait pas de photo.
  static const noIllustrationFound =
      'Aucune illustration trouvée dans le scan.';

  static const processingTitle = 'Traitement IA en cours';

  /// Un traitement d'IA sur une recette dure une à deux minutes : « quelques
  /// secondes » faisait croire à un blocage au bout de trente.
  static const processingMessage =
      'Cela peut prendre une à deux minutes. Restez sur cet écran.';

  // ── Conversion d'un texte collé (Nouvelle recette) ─────────────────────────

  static const conversionTitle = 'Conversion de la recette';
  static const conversionEstimate = 'Comptez 1 à 2 minutes.';
  static const conversionStayHere =
      "Restez sur cet écran : la recette s'affichera ici.";
  static const conversionStepReading = 'Lecture du texte';
  static const conversionStepTagging = 'Repérage des ingrédients et des étapes';
  static const conversionLeaveTitle = 'Quitter ?';
  static const conversionLeaveMessage = 'La conversion en cours sera perdue.';
  static const conversionLeaveStay = 'Rester';
  static const conversionLeaveConfirm = 'Quitter';

  /// Remplace l'estimation au-delà de trois minutes
  /// (`AiProcessingOverlay.slowThreshold`).
  static const processingSlow =
      "C'est plus long que d'habitude. Le traitement continue : inutile de "
      'relancer.';

  /// « Temps écoulé : 1 min 05 ».
  static String processingElapsed(Duration elapsed) {
    final minutes = elapsed.inMinutes;
    final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return 'Temps écoulé : $minutes min $seconds';
  }
}
