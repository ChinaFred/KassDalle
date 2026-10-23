import 'package:flutter/foundation.dart';

import '../../../core/services/cooklang_parser.dart';
import '../../recipes/domain/recipe.dart';

/// Nombre de recettes affichées sous une fiche du référentiel nutrition.
///
/// La requête en demande une de plus : la vingt-et-unième, jamais affichée,
/// dit seulement qu'il en existe d'autres.
const int kIngredientUsageDisplayLimit = 20;

/// Plafond de valeurs d'un `arrayContainsAny` Firestore.
const int kIngredientUsageMaxValues = 30;

/// Les valeurs à chercher dans `ingredients_index` des recettes pour un
/// ingrédient du référentiel nutrition.
///
/// `ingredients_index` porte les noms écrits dans la recette, normalisés par
/// [buildIngredientsIndex] (espaces de bord retirés, minuscules). Le document
/// du référentiel porte, lui, un identifiant (`papier_sulfurise`), un nom
/// canonique (« papier sulfurisé ») et les noms rencontrés dans les recettes
/// (`aliases`). Chaque valeur passe ici par [buildIngredientsIndex] lui-même :
/// une normalisation recopiée pourrait s'écarter de celle de l'index, et la
/// recherche ne trouverait plus rien sans lever d'erreur.
///
/// Ordre : nom canonique, identifiant lu comme un nom, puis les alias. Au-delà
/// de [kIngredientUsageMaxValues] valeurs distinctes, les derniers alias sont
/// écartés — les deux premières valeurs, les plus fréquentes, restent.
List<String> ingredientUsageSearchValues({
  required String id,
  String? canonicalName,
  List<String> aliases = const [],
}) {
  final names = <String>[?canonicalName, id.replaceAll('_', ' '), ...aliases];
  final index = buildIngredientsIndex([
    for (final name in names) RecipeIngredient(name: name, qty: '', unit: ''),
  ]);
  return index.length > kIngredientUsageMaxValues
      ? index.sublist(0, kIngredientUsageMaxValues)
      : index;
}

/// Clé du provider des recettes d'un ingrédient : la liste des valeurs
/// cherchées, comparée par contenu.
@immutable
class IngredientUsageQuery {
  final List<String> values;

  const IngredientUsageQuery(this.values);

  @override
  bool operator ==(Object other) =>
      other is IngredientUsageQuery && listEquals(other.values, values);

  @override
  int get hashCode => Object.hashAll(values);
}

/// Une recette qui cite un ingrédient, telle que la fiche du référentiel
/// l'affiche : de quoi la nommer et l'ouvrir, sans lire le reste du document.
@immutable
class IngredientRecipeRef {
  final String id;
  final String title;

  /// Titre du livre, recopié sur la recette (`book_titre`) ; `null` pour une
  /// recette hors livre.
  final String? bookTitle;
  final bool isPrivate;

  /// Vrai tant que la recette n'est pas validée (`review_status` autre que
  /// `validated`). L'éditeur de recette n'ouvre pas un brouillon : il charge
  /// `raw_cooklang` et efface `draft_cooklang` à l'enregistrement.
  final bool isDraft;

  const IngredientRecipeRef({
    required this.id,
    required this.title,
    this.bookTitle,
    this.isPrivate = false,
    this.isDraft = false,
  });

  /// Lecture tolérante : un document ancien ou mal formé donne une ligne
  /// lisible plutôt qu'une erreur qui masquerait les autres recettes.
  factory IngredientRecipeRef.fromFirestore(
    String id,
    Map<String, dynamic> data,
  ) {
    final title = data['titre'];
    final book = data['book_titre'];
    final status = data['review_status'];
    return IngredientRecipeRef(
      id: id,
      title: title is String && title.trim().isNotEmpty
          ? title.trim()
          : 'Sans titre',
      bookTitle: book is String && book.trim().isNotEmpty ? book.trim() : null,
      isPrivate: data['is_private'] == true,
      // Même lecture que `Recipe.fromFirestore` : statut absent = brouillon.
      isDraft: (status is String ? status : 'draft') != 'validated',
    );
  }
}

/// Les recettes trouvées pour un ingrédient, plafonnées à
/// [kIngredientUsageDisplayLimit].
@immutable
class IngredientRecipeUsage {
  final List<IngredientRecipeRef> recipes;

  /// Vrai quand la requête a rendu plus de recettes que le plafond affiché.
  final bool hasMore;

  const IngredientRecipeUsage({required this.recipes, required this.hasMore});

  static const empty = IngredientRecipeUsage(recipes: [], hasMore: false);
}
