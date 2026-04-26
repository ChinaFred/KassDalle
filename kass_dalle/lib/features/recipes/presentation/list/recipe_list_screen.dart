import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../recipe_providers.dart';
import '../../domain/recipe.dart';

class RecipeListScreen extends ConsumerWidget {
  final String? bookId;
  const RecipeListScreen({super.key, this.bookId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Recipe>> recipesAsync = bookId != null
        ? ref.watch(recipesByBookProvider(bookId!))
        : ref.watch(unattachedRecipesProvider);

    final title = bookId != null ? 'Recettes du livre' : 'Recettes libres';

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: recipesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e')),
        data: (recipes) {
          if (recipes.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.restaurant_menu_outlined,
                    size: 64,
                    color: Theme.of(context).colorScheme.outlineVariant,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    bookId != null
                        ? 'Aucune recette dans ce livre'
                        : 'Aucune recette libre\nValidez un brouillon sans livre pour en créer',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: recipes.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) => _RecipeCard(recipe: recipes[i]),
          );
        },
      ),
    );
  }
}

class _RecipeCard extends StatelessWidget {
  final Recipe recipe;
  const _RecipeCard({required this.recipe});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(
            Icons.restaurant,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        title: Text(recipe.titre),
        subtitle: recipe.bookTitre != null
            ? Text(recipe.bookTitre!)
            : Text(
                'Recette libre',
                style: TextStyle(color: theme.colorScheme.outline),
              ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.go('/recipes/${recipe.id}'),
      ),
    );
  }
}
