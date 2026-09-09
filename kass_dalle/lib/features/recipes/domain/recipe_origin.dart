/// D'où vient un document de recette : ce qui l'a écrit la première fois.
///
/// L'écran de relecture disait « issu d'un scan » à tout brouillon sans
/// recette source — y compris ceux que l'IA conçoit pour le planning et ceux
/// saisis à la main. L'origine s'écrit à la création, par celui qui écrit le
/// document, et ne se déduit ni du livre porteur ni de la présence d'un
/// fichier source.
enum RecipeOrigin {
  /// Une page de livre importée et lue par l'IA.
  scan,

  /// Une recette conçue par l'IA — planning ou Explorer.
  ai,

  /// Une recette saisie à la main, texte collé compris.
  manual,

  /// Une copie de travail d'une recette existante.
  copy,
}

/// Sous-titre de l'écran de relecture d'un brouillon.
///
/// `null` est une origine absente — un document écrit avant que le champ
/// existe, sans fichier source ni recette source. On ne l'affirme pas.
String draftOriginLabel(RecipeOrigin? origin) => switch (origin) {
  RecipeOrigin.scan => 'Brouillon issu d\'un scan',
  RecipeOrigin.ai => 'Brouillon conçu par l\'IA',
  RecipeOrigin.manual => 'Brouillon saisi à la main',
  RecipeOrigin.copy => 'Copie de travail - l\'originale reste intacte',
  null => 'Brouillon d\'origine non renseignée',
};

/// Lit une origine écrite en base, ou null si la valeur est absente ou inconnue.
RecipeOrigin? recipeOriginFrom(Object? raw) {
  for (final origin in RecipeOrigin.values) {
    if (origin.name == raw) return origin;
  }
  return null;
}
