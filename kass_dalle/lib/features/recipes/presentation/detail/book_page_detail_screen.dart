import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/recipe.dart';
import '../recipe_providers.dart';
import '../source_viewer.dart';

/// Affiche le contenu d'une page non-recette d'un livre (technique, matériel, etc.).
class BookPageDetailScreen extends ConsumerWidget {
  final String pageId;
  const BookPageDetailScreen({super.key, required this.pageId});

  static IconData _iconForPageType(PageType t) => switch (t) {
    PageType.technique => Icons.tips_and_updates_outlined,
    PageType.equipment => Icons.kitchen_outlined,
    PageType.ingredientNote => Icons.eco_outlined,
    PageType.other => Icons.description_outlined,
    _ => Icons.description_outlined,
  };

  static String _labelForPageType(PageType t) => switch (t) {
    PageType.technique => 'Technique culinaire',
    PageType.equipment => 'Matériel & ustensiles',
    PageType.ingredientNote => 'Note sur les ingrédients',
    PageType.other => 'Page de livre',
    _ => 'Page de livre',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recipeAsync = ref.watch(recipeByIdProvider(pageId));
    final theme = Theme.of(context);

    return recipeAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        appBar: AppBar(title: const Text('Erreur')),
        body: Center(child: Text('$e')),
      ),
      data: (recipe) {
        if (recipe == null) {
          return Scaffold(
            appBar: AppBar(title: const Text('Page introuvable')),
            body: const Center(child: Text('Cette page est introuvable.')),
          );
        }
        final pageIcon = _iconForPageType(recipe.pageType);
        final pageLabel = _labelForPageType(recipe.pageType);
        final content = (recipe.draftCooklang?.isNotEmpty == true
                ? recipe.draftCooklang!
                : recipe.rawCooklang)
            .trim();

        return Scaffold(
          appBar: AppBar(
            centerTitle: false,
            title: Row(
              children: [
                Icon(pageIcon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    recipe.titre,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            actions: [
              if ((recipe.sourceFileUrl ?? '').isNotEmpty)
                SourceViewerButton(
                  sourceFileUrl: recipe.sourceFileUrl,
                  sourceFileName: recipe.sourceFileName,
                ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Badge type + numéro de page
                Row(
                  children: [
                    Chip(
                      avatar: Icon(pageIcon, size: 16),
                      label: Text(pageLabel),
                      visualDensity: VisualDensity.compact,
                    ),
                    if (recipe.pageNumber != null) ...[
                      const SizedBox(width: 8),
                      Chip(
                        label: Text('p.${recipe.pageNumber}'),
                        visualDensity: VisualDensity.compact,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                if (content.isEmpty)
                  Text(
                    'Aucun contenu extrait.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  )
                else
                  SelectableText(
                    content,
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                  ),
                const SizedBox(height: 80),
              ],
            ),
          ),
        );
      },
    );
  }
}
