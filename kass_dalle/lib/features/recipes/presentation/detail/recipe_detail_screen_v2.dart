import 'package:flutter/material.dart';

import 'book_reader_navigation.dart';
import 'recipe_detail_screen.dart';

/// Point d'entree de la V2.
///
/// Cette V2 est actuellement isofonctionnelle et delegue la logique complete
/// a l'ecran existant. La reorganisation UX sera effectuee incrementalement
/// sans risque de regression fonctionnelle.
class RecipeDetailScreenV2 extends StatelessWidget {
  final String recipeId;
  final bool scrollToAnnotations;
  final BookReadingContext readingContext;

  const RecipeDetailScreenV2({
    super.key,
    required this.recipeId,
    this.scrollToAnnotations = false,
    this.readingContext = const BookReadingContext(),
  });

  @override
  Widget build(BuildContext context) {
    return RecipeDetailScreen(
      recipeId: recipeId,
      scrollToAnnotations: scrollToAnnotations,
      readingContext: readingContext,
    );
  }
}
