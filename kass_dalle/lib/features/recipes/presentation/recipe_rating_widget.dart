import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../domain/family_ratings.dart';
import '../presentation/recipe_providers.dart';
import '../../auth/presentation/auth_providers.dart';
import '../../../core/theme/app_icon_size.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/widgets/error_message.dart';
import '../../groups/presentation/group_providers.dart';

/// Badge compact affichant la note de l'utilisateur (ex : ★ 8).
/// Appuyez dessus pour ouvrir le sélecteur de note.
class RecipeRatingBadge extends ConsumerWidget {
  final String recipeId;

  const RecipeRatingBadge({super.key, required this.recipeId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ratingAsync = ref.watch(myRatingProvider(recipeId));
    final rating = ratingAsync.value?.rating;

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
              size: AppIconSize.badge,
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
    showRecipeRatingDialog(context, recipeId, current);
  }
}

/// Ouvre le sélecteur de note (curseur 0 à 10) pour une recette.
///
/// Point d'entrée unique : la note vit dans `recipe_ratings`, jamais dans les
/// annotations. Tout écran qui veut proposer « noter » passe par ici.
Future<void> showRecipeRatingDialog(
  BuildContext context,
  String recipeId,
  int? current,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => _RatingDialog(recipeId: recipeId, current: current),
  );
}

/// Ligne compacte « Ma note : 8 / 10 · Modifier », à poser en tête d'un autre
/// formulaire (dialogue d'annotation) comme raccourci vers le sélecteur.
///
/// N'enregistre rien elle-même : elle ne fait qu'ouvrir
/// [showRecipeRatingDialog], qui écrit dans sa propre collection.
class RecipeRatingInlineLink extends ConsumerWidget {
  final String recipeId;

  const RecipeRatingInlineLink({super.key, required this.recipeId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rating = ref.watch(myRatingProvider(recipeId)).value?.rating;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    return Row(
      children: [
        Icon(
          rating != null ? Icons.star_rounded : Icons.star_outline_rounded,
          size: AppIconSize.inline,
          color: theme.colorScheme.primary,
        ),
        const SizedBox(width: 6),
        Text('Ma note', style: muted),
        const SizedBox(width: 8),
        if (rating != null)
          _RatingChip(rating: rating)
        else
          Text(
            'pas encore notée',
            style: muted?.copyWith(fontStyle: FontStyle.italic),
          ),
        const Spacer(),
        TextButton(
          onPressed: () => showRecipeRatingDialog(context, recipeId, rating),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(rating != null ? 'Modifier' : 'Noter'),
        ),
      ],
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
    final rating = ratingAsync.value?.rating;
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
                    size: AppIconSize.small,
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
                        rating != null ? Icons.edit_outlined : Icons.add,
                        size: AppIconSize.inline,
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
              if (!_editing) ...[
                const SizedBox(height: 4),
                _FamilyRatingsSection(recipeId: widget.recipeId),
              ],
              if (_editing) ...[
                const SizedBox(height: 8),
                const _RatingVisibilityNotice(),
                const SizedBox(height: 4),
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
                          final uid = ref.read(appUserProvider).value?.uid;
                          if (uid == null) return;
                          final ok = await _deleteRating(
                            context,
                            ref,
                            uid,
                            widget.recipeId,
                          );
                          if (ok && mounted) setState(() => _editing = false);
                        },
                        icon: Icon(
                          Icons.delete_outline,
                          size: AppIconSize.inline,
                          color: theme.colorScheme.error,
                        ),
                        label: Text(
                          'Supprimer',
                          style: TextStyle(color: theme.colorScheme.error),
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
                        final uid = ref.read(appUserProvider).value?.uid;
                        if (uid == null) return;
                        final ok = await _saveRating(
                          context,
                          ref,
                          uid,
                          widget.recipeId,
                          _draft ?? 5,
                        );
                        if (ok && mounted) setState(() => _editing = false);
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
          const _RatingVisibilityNotice(),
          const SizedBox(height: 4),
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
              final uid = ref.read(appUserProvider).value?.uid;
              if (uid == null) return;
              final ok = await _deleteRating(
                context,
                ref,
                uid,
                widget.recipeId,
              );
              if (!ok || !context.mounted) return;
              Navigator.of(context).pop();
            },
            child: Text(
              'Supprimer',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: () async {
            final uid = ref.read(appUserProvider).value?.uid;
            if (uid == null) return;
            final ok = await _saveRating(
              context,
              ref,
              uid,
              widget.recipeId,
              _value,
            );
            if (!ok || !context.mounted) return;
            Navigator.of(context).pop();
          },
          child: const Text('Enregistrer'),
        ),
      ],
    );
  }
}

// ── Enregistrement ────────────────────────────────────────────────────────────

/// Enregistre la note et annonce un échec. `true` si l'écriture a réussi.
///
/// Le repository a déjà rapporté l'erreur : il ne reste qu'à la dire à
/// l'utilisateur, qui croirait sinon sa note enregistrée.
Future<bool> _saveRating(
  BuildContext context,
  WidgetRef ref,
  String uid,
  String recipeId,
  int rating,
) async {
  try {
    await ref
        .read(recipeRatingRepositoryProvider)
        .setRating(userId: uid, recipeId: recipeId, rating: rating);
    return true;
  } catch (e) {
    if (context.mounted) {
      context.showErrorSnackBar(
        'Note non enregistrée — ${shortErrorMessage(e)}',
      );
    }
    return false;
  }
}

/// Supprime la note et annonce un échec. `true` si la suppression a réussi.
Future<bool> _deleteRating(
  BuildContext context,
  WidgetRef ref,
  String uid,
  String recipeId,
) async {
  try {
    await ref
        .read(recipeRatingRepositoryProvider)
        .deleteRating(userId: uid, recipeId: recipeId);
    return true;
  } catch (e) {
    if (context.mounted) {
      context.showErrorSnackBar('Note non supprimée — ${shortErrorMessage(e)}');
    }
    return false;
  }
}

// ── Notes de la famille ───────────────────────────────────────────────────────

/// Rappel affiché au moment de noter : la note n'est pas privée.
class _RatingVisibilityNotice extends StatelessWidget {
  const _RatingVisibilityNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.visibility_outlined, size: AppIconSize.inline, color: muted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            'Votre note est visible des membres qui ont accès à cette recette.',
            style: theme.textTheme.bodySmall?.copyWith(color: muted),
          ),
        ),
      ],
    );
  }
}

/// Moyenne de la famille et, dépliée, la note de chaque membre de mes
/// groupes. Repliée par défaut.
class _FamilyRatingsSection extends ConsumerWidget {
  final String recipeId;

  const _FamilyRatingsSection({required this.recipeId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final async = ref.watch(familyRatingsProvider(recipeId));

    return async.when(
      loading: () => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text('Chargement des notes de la famille…', style: muted),
            ),
          ],
        ),
      ),
      error: (e, _) => AppErrorState(
        error: e,
        compact: true,
        title: 'Notes de la famille indisponibles',
        onRetry: () {
          ref.invalidate(recipeRatingsProvider(recipeId));
          ref.invalidate(myGroupsProvider);
        },
      ),
      data: (family) {
        final average = family.average;
        if (average == null) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              "Aucun autre membre n'a encore noté cette recette.",
              style: muted,
            ),
          );
        }
        final avg = formatRatingAverage(average);
        final count = family.count;
        final notes = count > 1 ? 'notes' : 'note';
        return Theme(
          data: theme.copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            initiallyExpanded: false,
            leading: Icon(
              Icons.groups_outlined,
              size: AppIconSize.small,
              color: theme.colorScheme.primary,
            ),
            title: Semantics(
              label:
                  'Moyenne de la famille : $avg sur 10, '
                  '$count $notes',
              excludeSemantics: true,
              child: Text(
                'Famille : $avg / 10 · $count $notes',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            children: [
              for (final member in family.others) _MemberRatingTile(member),
            ],
          ),
        );
      },
    );
  }
}

class _MemberRatingTile extends StatelessWidget {
  final MemberRating member;

  const _MemberRatingTile(this.member);

  @override
  Widget build(BuildContext context) {
    final date = DateFormat('d MMM yyyy', 'fr').format(member.updatedAt);
    final initial = member.name.trim().isEmpty
        ? '?'
        : member.name.trim().characters.first.toUpperCase();
    return MergeSemantics(
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: ExcludeSemantics(
          child: CircleAvatar(radius: 16, child: Text(initial)),
        ),
        title: Text(member.name),
        subtitle: Text(date),
        trailing: Semantics(
          label: '${member.rating} sur 10',
          excludeSemantics: true,
          child: _RatingChip(rating: member.rating),
        ),
      ),
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
