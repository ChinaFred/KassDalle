import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'admin_providers.dart';
import '../data/nutrition_ingredients_repository.dart';
import '../domain/ingredient_recipe_usage.dart';
import '../../../core/theme/app_icon_size.dart';

/// Section « Recettes qui l'utilisent » d'une fiche du référentiel nutrition.
///
/// Construite seulement fiche dépliée (`ExpansionTile` ne garde pas ses
/// enfants une fois replié) : la lecture a lieu au dépliage, et un nouveau
/// dépliage relit. Une requête Firestore, aucun appel d'IA.
class IngredientRecipesSection extends ConsumerWidget {
  final NutritionIngredientDoc doc;

  const IngredientRecipesSection({super.key, required this.doc});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = IngredientUsageQuery(
      ingredientUsageSearchValues(
        id: doc.id,
        canonicalName: doc.canonicalName,
        aliases: doc.aliases,
      ),
    );
    final provider = ingredientRecipeUsageProvider(query);
    final usageAsync = ref.watch(provider);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    final usage = usageAsync.isLoading ? null : usageAsync.value;
    final count = usage == null
        ? ''
        : usage.hasMore
        ? ' ($kIngredientUsageDisplayLimit+)'
        : ' (${usage.recipes.length})';

    final Widget body;
    if (usageAsync.isLoading) {
      body = const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(minHeight: 2),
      );
    } else if (usageAsync.hasError) {
      // Erreur déjà signalée au rapport d'erreurs par
      // IngredientUsageRepository.fetchRecipesUsing.
      body = Row(
        children: [
          const Expanded(child: Text('Recettes introuvables pour le moment.')),
          TextButton(
            onPressed: () => ref.invalidate(provider),
            child: const Text('Réessayer'),
          ),
        ],
      );
    } else if (usage == null || usage.recipes.isEmpty) {
      body = Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text('Aucune recette n\'utilise cet ingrédient.', style: muted),
      );
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final recipe in usage.recipes) _RecipeUsageTile(recipe: recipe),
          if (usage.hasMore)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '$kIngredientUsageDisplayLimit premières recettes affichées. '
                'Corrigez-les puis repliez et dépliez la fiche pour voir la '
                'suite.',
                style: muted,
              ),
            ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Recettes qui l\'utilisent$count',
            style: theme.textTheme.titleSmall,
          ),
          body,
        ],
      ),
    );
  }
}

class _RecipeUsageTile extends StatelessWidget {
  final IngredientRecipeRef recipe;

  const _RecipeUsageTile({required this.recipe});

  @override
  Widget build(BuildContext context) {
    final details = [
      if (recipe.isDraft) 'Brouillon',
      if (recipe.isPrivate) 'Privée',
      ?recipe.bookTitle,
    ];
    return Semantics(
      hint: 'Ouvrir la recette',
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: const Icon(
          Icons.restaurant_menu_outlined,
          size: AppIconSize.small,
        ),
        title: Text(recipe.title),
        subtitle: details.isEmpty ? null : Text(details.join(' · ')),
        // L'éditeur de recette charge `raw_cooklang` et efface
        // `draft_cooklang` à l'enregistrement : il n'ouvre pas un brouillon,
        // qui se corrige depuis sa relecture.
        trailing: recipe.isDraft
            ? null
            : IconButton(
                tooltip: 'Ouvrir dans l\'éditeur',
                icon: const Icon(Icons.edit_outlined, size: AppIconSize.small),
                onPressed: () => context.push('/recipes/${recipe.id}/edit'),
              ),
        onTap: () => context.push('/recipes/${recipe.id}'),
      ),
    );
  }
}
