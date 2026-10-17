import '../../recipes/domain/recipe.dart';

/// Le titre d'une recette validée d'un livre privé d'un membre de mes groupes,
/// tel que le rend `listFamilyPrivateTitlesFn`. Rien d'autre de la recette ne
/// traverse : ni image, ni ingrédients, ni accès à la fiche.
class PrivateRecipeTitle {
  final String id;
  final String titre;
  final String? bookTitre;
  final String createdBy;

  const PrivateRecipeTitle({
    required this.id,
    required this.titre,
    required this.createdBy,
    this.bookTitre,
  });

  /// Lit une entrée de la réponse ; `null` si l'identifiant ou le titre
  /// manque.
  static PrivateRecipeTitle? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final id = raw['id'];
    final titre = raw['titre'];
    if (id is! String || id.isEmpty || titre is! String || titre.isEmpty) {
      return null;
    }
    final book = raw['bookTitre'];
    final author = raw['createdBy'];
    return PrivateRecipeTitle(
      id: id,
      titre: titre,
      bookTitre: book is String && book.isNotEmpty ? book : null,
      createdBy: author is String ? author : '',
    );
  }

  /// La recette creuse que le sélecteur affiche : identifiant, titre, livre et
  /// indicateur privé, sans contenu.
  Recipe toRecipe() => Recipe(
    id: id,
    titre: titre,
    langue: 'fr',
    rawCooklang: '',
    imageUrls: const [],
    reviewStatus: ReviewStatus.validated,
    tags: const RecipeTags(),
    ingredientsIndex: const [],
    bookTitre: bookTitre,
    isPrivate: true,
    createdBy: createdBy,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
}

/// Les entrées lisibles d'une réponse `{titles: [...]}`, les autres ignorées.
List<PrivateRecipeTitle> parsePrivateRecipeTitles(Object? data) {
  if (data is! Map) return const [];
  final titles = data['titles'];
  if (titles is! List) return const [];
  return [for (final t in titles) ?PrivateRecipeTitle.tryParse(t)];
}
