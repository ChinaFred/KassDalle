import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../annotations/presentation/annotation_providers.dart';
import '../../recipe_rating_widget.dart';
import '../recipe_detail_annotations.dart';

/// Résumé communauté affiché dans le corps mobile : notes et annotations.
///
/// Extrait de recipe_detail_screen.dart.

class MobileCommunitySummary extends ConsumerWidget {
  final String recipeId;
  final Future<void> Function() onOpenCommunity;

  const MobileCommunitySummary({
    super.key,
    required this.recipeId,
    required this.onOpenCommunity,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final annotationsAsync = ref.watch(annotationsProvider(recipeId));
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  'Communaute',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: onOpenCommunity,
                  icon: const Icon(Icons.open_in_full, size: 18),
                  label: const Text('Voir tout'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            RecipeRatingEditor(recipeId: recipeId),
            const SizedBox(height: 8),
            annotationsAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Text('Erreur : $e'),
              data: (annotations) {
                if (annotations.isEmpty) {
                  return const Text('Aucune annotation pour le moment.');
                }
                final items = annotations.take(3).toList();
                return Column(
                  children: [
                    for (final annotation in items)
                      AnnotationTile(
                        annotation: annotation,
                        recipeId: recipeId,
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
