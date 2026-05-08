import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../presentation/recipe_providers.dart';
import '../../auth/presentation/auth_providers.dart';

/// Badge compact affichant la note de l'utilisateur (ex : ★ 8).
/// Appuyez dessus pour ouvrir le sélecteur de note.
class RecipeRatingBadge extends ConsumerWidget {
  final String recipeId;

  const RecipeRatingBadge({super.key, required this.recipeId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ratingAsync = ref.watch(myRatingProvider(recipeId));
    final rating = ratingAsync.valueOrNull?.rating;

    return GestureDetector(
      onTap: () => _showRatingDialog(context, ref, rating),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: rating != null
              ? _ratingColor(rating, Theme.of(context))
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              rating != null ? Icons.star_rounded : Icons.star_outline_rounded,
              size: 13,
              color: rating != null
                  ? _ratingFg(rating, Theme.of(context))
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 3),
            Text(
              rating != null ? '$rating' : '–',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: rating != null
                    ? _ratingFg(rating, Theme.of(context))
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showRatingDialog(BuildContext context, WidgetRef ref, int? current) {
    showDialog<void>(
      context: context,
      builder: (_) => _RatingDialog(recipeId: recipeId, current: current),
    );
  }
}

/// Bloc éditeur de note (affichage inline dans la fiche recette).
/// Affiche la note courante + un slider pour la modifier.
class RecipeRatingEditor extends ConsumerStatefulWidget {
  final String recipeId;

  const RecipeRatingEditor({super.key, required this.recipeId});

  @override
  ConsumerState<RecipeRatingEditor> createState() => _RecipeRatingEditorState();
}

class _RecipeRatingEditorState extends ConsumerState<RecipeRatingEditor> {
  bool _editing = false;
  int? _draft;

  @override
  Widget build(BuildContext context) {
    final ratingAsync = ref.watch(myRatingProvider(widget.recipeId));
    final rating = ratingAsync.valueOrNull?.rating;
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Card(
        color: theme.colorScheme.surfaceContainerLow,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.star_rounded,
                    size: 18,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'Ma note',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  if (rating != null && !_editing) ...[
                    _RatingChip(rating: rating),
                    const SizedBox(width: 8),
                  ],
                  if (!_editing)
                    TextButton.icon(
                      onPressed: () => setState(() {
                        _draft = rating ?? 5;
                        _editing = true;
                      }),
                      icon: Icon(
                        rating != null
                            ? Icons.edit_outlined
                            : Icons.add_outlined,
                        size: 16,
                      ),
                      label: Text(rating != null ? 'Modifier' : 'Noter'),
                    ),
                ],
              ),
              if (!_editing && rating == null)
                Text(
                  'Pas encore noté',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              if (_editing) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      '0',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        value: (_draft ?? 5).toDouble(),
                        min: 0,
                        max: 10,
                        divisions: 10,
                        label: '${_draft ?? 5}',
                        onChanged: (v) => setState(() => _draft = v.round()),
                      ),
                    ),
                    Text(
                      '10',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 8),
                    _RatingChip(rating: _draft ?? 5),
                  ],
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (rating != null)
                      TextButton.icon(
                        onPressed: () async {
                          final uid = ref
                              .read(appUserProvider)
                              .valueOrNull
                              ?.uid;
                          if (uid == null) return;
                          await ref
                              .read(recipeRatingRepositoryProvider)
                              .deleteRating(
                                userId: uid,
                                recipeId: widget.recipeId,
                              );
                          setState(() => _editing = false);
                        },
                        icon: const Icon(
                          Icons.delete_outline,
                          size: 16,
                          color: Colors.red,
                        ),
                        label: const Text(
                          'Supprimer',
                          style: TextStyle(color: Colors.red),
                        ),
                      ),
                    const Spacer(),
                    TextButton(
                      onPressed: () => setState(() => _editing = false),
                      child: const Text('Annuler'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () async {
                        final uid = ref.read(appUserProvider).valueOrNull?.uid;
                        if (uid == null) return;
                        await ref
                            .read(recipeRatingRepositoryProvider)
                            .setRating(
                              userId: uid,
                              recipeId: widget.recipeId,
                              rating: _draft ?? 5,
                            );
                        setState(() => _editing = false);
                      },
                      child: const Text('Enregistrer'),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _RatingChip extends StatelessWidget {
  final int rating;
  const _RatingChip({required this.rating});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _ratingColor(rating, theme),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$rating / 10',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.bold,
          color: _ratingFg(rating, theme),
        ),
      ),
    );
  }
}

// ── Dialog sélecteur de note ──────────────────────────────────────────────────

class _RatingDialog extends ConsumerStatefulWidget {
  final String recipeId;
  final int? current;

  const _RatingDialog({required this.recipeId, this.current});

  @override
  ConsumerState<_RatingDialog> createState() => _RatingDialogState();
}

class _RatingDialogState extends ConsumerState<_RatingDialog> {
  late int _value;

  @override
  void initState() {
    super.initState();
    _value = widget.current ?? 5;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ma note'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RatingChip(rating: _value),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('0'),
              Expanded(
                child: Slider(
                  value: _value.toDouble(),
                  min: 0,
                  max: 10,
                  divisions: 10,
                  label: '$_value',
                  onChanged: (v) => setState(() => _value = v.round()),
                ),
              ),
              const Text('10'),
            ],
          ),
        ],
      ),
      actions: [
        if (widget.current != null)
          TextButton(
            onPressed: () async {
              final uid = ref.read(appUserProvider).valueOrNull?.uid;
              if (uid == null) return;
              await ref
                  .read(recipeRatingRepositoryProvider)
                  .deleteRating(userId: uid, recipeId: widget.recipeId);
              if (!context.mounted) return;
              Navigator.of(context).pop();
            },
            child: const Text('Supprimer', style: TextStyle(color: Colors.red)),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () async {
            final uid = ref.read(appUserProvider).valueOrNull?.uid;
            if (uid == null) return;
            await ref
                .read(recipeRatingRepositoryProvider)
                .setRating(
                  userId: uid,
                  recipeId: widget.recipeId,
                  rating: _value,
                );
            if (!context.mounted) return;
            Navigator.of(context).pop();
          },
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}

// ── Helpers couleur ───────────────────────────────────────────────────────────

Color _ratingColor(int rating, ThemeData theme) {
  if (rating >= 8) return Colors.green.shade100;
  if (rating >= 5) return Colors.orange.shade100;
  return Colors.red.shade100;
}

Color _ratingFg(int rating, ThemeData theme) {
  if (rating >= 8) return Colors.green.shade800;
  if (rating >= 5) return Colors.orange.shade800;
  return Colors.red.shade800;
}
