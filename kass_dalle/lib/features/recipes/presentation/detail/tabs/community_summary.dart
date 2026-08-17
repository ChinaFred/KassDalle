import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../annotations/presentation/annotation_providers.dart';
import '../../cooklang_preview_sections.dart';
import '../../recipe_rating_widget.dart';
import '../recipe_detail_annotations.dart';
import '../../../../../core/widgets/app_states.dart';

/// Résumé communauté affiché dans le corps mobile : notes et annotations.
///
/// Extrait de recipe_detail_screen.dart. Se replie comme les sections
/// voisines : son en-tête est le même que celui des ingrédients et de la
/// préparation, et « Voir tout » y reste joignable même repliée.

class MobileCommunitySummary extends ConsumerStatefulWidget {
  final String recipeId;
  final Future<void> Function() onOpenCommunity;

  const MobileCommunitySummary({
    super.key,
    required this.recipeId,
    required this.onOpenCommunity,
  });

  @override
  ConsumerState<MobileCommunitySummary> createState() =>
      _MobileCommunitySummaryState();
}

class _MobileCommunitySummaryState
    extends ConsumerState<MobileCommunitySummary> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final recipeId = widget.recipeId;
    final annotationsAsync = ref.watch(annotationsProvider(recipeId));
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CooklangSectionHeader(
              icon: Icons.forum_outlined,
              title: 'Communaute',
              expanded: _expanded,
              onTap: () => setState(() => _expanded = !_expanded),
              action: TextButton.icon(
                onPressed: widget.onOpenCommunity,
                icon: const Icon(Icons.open_in_full, size: 18),
                label: const Text('Voir tout'),
              ),
            ),
            if (_expanded) ...[
              const SizedBox(height: 4),
              RecipeRatingEditor(recipeId: recipeId),
              const SizedBox(height: 8),
              annotationsAsync.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => AppErrorState(error: e, compact: true),
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
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }
}
