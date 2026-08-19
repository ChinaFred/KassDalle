/// Copie UX unifiée pour les actions IA liées aux recettes.
///
/// Centraliser ces libellés évite les divergences entre écrans
/// (création, édition, détail, brouillons) et simplifie les ajustements futurs.
class RecipeAiUiCopy {
  const RecipeAiUiCopy._();

  static const appBarActionLabel = 'Améliorer avec l\'IA';
  static const appBarActionTooltip = 'Améliorer cette recette avec l\'IA';

  static const refineDialogTitle = 'Améliorer avec l\'IA';
  static const refineDialogPrimaryCta = 'Lancer l\'amelioration';
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

  static const successRecipeRefined = 'Recette amelioree par l\'IA ✓';
  static const successRecipePolished = 'Recette corrigee et harmonisee !';
  static const successRecipeTransformed = 'Recette convertie en CookLang !';

  static const processingTitle = 'Traitement IA en cours';
  static const processingMessage =
      'Patientez quelques secondes, nous appliquons vos consignes.';
}
