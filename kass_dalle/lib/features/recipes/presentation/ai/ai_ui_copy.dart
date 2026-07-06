/// Copie UX unifiée pour les actions IA liées aux recettes.
///
/// Centraliser ces libellés évite les divergences entre écrans
/// (création, édition, détail, brouillons) et simplifie les ajustements futurs.
class RecipeAiUiCopy {
  const RecipeAiUiCopy._();

  static const appBarActionLabel = 'Ameliorer avec l\'IA';
  static const appBarActionTooltip = 'Ameliorer cette recette avec l\'IA';

  static const refineDialogTitle = 'Ameliorer avec l\'IA';
  static const refineDialogPrimaryCta = 'Lancer l\'amelioration';
  static const refineDialogInputPrompt =
      'Precisez ce que vous voulez ameliorer (optionnel) :';

  static const cooklangRefineTooltip = 'Ameliorer la recette avec l\'IA';
  static const cooklangPolishTooltip =
      'Corriger et harmoniser la recette avec l\'IA';
  static const cooklangTransformTooltip =
      'Transformer en CookLang avec l\'IA';

  static const successRecipeRefined = 'Recette amelioree par l\'IA ✓';
  static const successRecipePolished = 'Recette corrigee et harmonisee !';
  static const successRecipeTransformed = 'Recette convertie en CookLang !';
}
