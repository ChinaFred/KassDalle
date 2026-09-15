import '../../recipes/domain/recipe.dart';

/// Sources disponibles pour la sélection de recettes dans la génération par
/// slot : où chercher, avant d'éventuellement inventer.
enum RecipeSource {
  myRecipes,
  myDrafts,
  familyRecipes,
  aiCreation;

  String get label => switch (this) {
    RecipeSource.myRecipes => 'Mes recettes validées',
    RecipeSource.myDrafts => 'Mes brouillons',
    RecipeSource.familyRecipes => 'Recettes famille',
    RecipeSource.aiCreation => 'Conception IA (si aucun résultat)',
  };
}

/// Ce que retient « Où chercher des recettes ? » : quelles sources, et dans
/// quels livres.
///
/// Une préférence de lecteur — la bibliothèque est partagée, chacun y cherche
/// à sa façon — persistée sous `users/{uid}/preferences/recipe_search_scope`
/// pour survivre à la fermeture de l'écran comme à un changement d'appareil.
class RecipeSearchScope {
  final Set<RecipeSource> sources;

  /// Identifiants de livre retenus. Un livre absent de cet ensemble est
  /// écarté de la recherche — y compris un livre créé depuis le dernier
  /// choix : il se coche à la main, comme les autres, plutôt que d'entrer en
  /// silence dans un périmètre qu'on croyait figé.
  final Set<String> bookIds;

  const RecipeSearchScope({required this.sources, this.bookIds = const {}});

  /// Vrai si [recipe] entre dans ce périmètre de livres.
  ///
  /// Une recette sans livre — un reliquat d'avant que le champ existe —
  /// n'est jamais écartée : un filtre par livre ne peut pas se prononcer sur
  /// elle, et l'exclure la ferait disparaître sans qu'aucune case ne
  /// permette de la ramener.
  bool matchesBook(Recipe recipe) {
    final id = recipe.bookId;
    return id == null || id.isEmpty || bookIds.contains(id);
  }

  factory RecipeSearchScope.fromMap(Map<String, dynamic> data) {
    final rawSources = (data['sources'] as List?)?.cast<String>() ?? const [];
    final sources = <RecipeSource>{
      for (final value in RecipeSource.values)
        if (rawSources.contains(value.name)) value,
    };
    return RecipeSearchScope(
      // Un document illisible ou vidé ne doit pas réduire la recherche à
      // rien : au moins les recettes validées restent proposées.
      sources: sources.isEmpty ? {RecipeSource.myRecipes} : sources,
      bookIds: ((data['book_ids'] as List?)?.cast<String>() ?? const [])
          .toSet(),
    );
  }

  Map<String, dynamic> toMap() => {
    'sources': [for (final s in sources) s.name],
    'book_ids': bookIds.toList(),
  };
}
