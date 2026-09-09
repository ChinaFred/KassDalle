import '../../recipes/domain/recipe.dart';

/// Recettes que l'IA peut proposer pour un repas.
///
/// Toutes celles du corpus, moins celle que le repas porte déjà et celles
/// qu'on en a écartées. Le tri se fait ici, avant l'appel : une consigne
/// « ne repropose pas » dans le prompt est un vœu, un candidat absent de la
/// liste est une certitude.
List<Recipe> candidatesForMeal(
  List<Recipe> corpus, {
  String? currentRecipeId,
  Iterable<String> dismissedRecipeIds = const [],
}) {
  final excluded = <String>{
    ...dismissedRecipeIds,
    if (currentRecipeId != null && currentRecipeId.isNotEmpty) currentRecipeId,
  };
  if (excluded.isEmpty) return corpus;
  return corpus.where((r) => !excluded.contains(r.id)).toList(growable: false);
}
