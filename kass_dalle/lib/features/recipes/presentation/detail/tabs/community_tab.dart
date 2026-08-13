import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../annotations/presentation/annotation_providers.dart';
import '../../recipe_rating_widget.dart';
import '../recipe_detail_annotations.dart';
import '../../../../../core/widgets/app_states.dart';

/// Onglet « Communauté » : note de la recette et annotations partagées.
///
/// Extrait de recipe_detail_screen.dart.

class CommunityTab extends ConsumerWidget {
  final String recipeId;
  final GlobalKey annotationsKey;

  const CommunityTab({
    super.key,
    required this.recipeId,
    required this.annotationsKey,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final annotationsAsync = ref.watch(annotationsProvider(recipeId));
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: RecipeRatingEditor(recipeId: recipeId)),
        SliverToBoxAdapter(
          child: Padding(
            key: annotationsKey,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'Annotations',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const Expanded(child: Divider()),
              ],
            ),
          ),
        ),
        annotationsAsync.when(
          loading: () => const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
          error: (e, _) =>
              SliverToBoxAdapter(child: AppErrorState(error: e, compact: true)),
          data: (annotations) {
            if (annotations.isEmpty) {
              return const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: Text(
                      'Aucune annotation. Soyez le premier !',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                ),
              );
            }
            return SliverList(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => AnnotationTile(
                  annotation: annotations[i],
                  recipeId: recipeId,
                ),
                childCount: annotations.length,
              ),
            );
          },
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 80)),
      ],
    );
  }
}
