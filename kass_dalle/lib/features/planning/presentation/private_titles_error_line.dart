import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'meal_suggestion_providers.dart';

/// Ligne posée sous le champ de recherche d'un plat quand les titres des
/// livres privés n'ont pas pu être lus (`suggestablePrivateTitlesProvider`
/// en erreur). La liste habituelle reste affichée ; « Réessayer » relance la
/// lecture ; pendant cette nouvelle lecture, un indicateur de chargement
/// remplace le bouton. Rien quand la lecture a abouti, ou à la première
/// lecture.
///
/// Le rapport d'erreur est envoyé par `PrivateTitlesRepository.list`.
class PrivateTitlesErrorLine extends ConsumerWidget {
  final EdgeInsetsGeometry padding;

  const PrivateTitlesErrorLine({super.key, this.padding = EdgeInsets.zero});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final titlesAsync = ref.watch(suggestablePrivateTitlesProvider);
    if (!titlesAsync.hasError) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Titres des livres privés non chargés.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
          // Pendant la nouvelle lecture, un indicateur prend la place du
          // bouton, qui garde sa taille (invisible) : la ligne ne bouge pas.
          Stack(
            alignment: Alignment.center,
            children: [
              Visibility(
                visible: !titlesAsync.isLoading,
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                child: TextButton(
                  onPressed: titlesAsync.isLoading
                      ? null
                      : () => ref.invalidate(suggestablePrivateTitlesProvider),
                  child: const Text('Réessayer'),
                ),
              ),
              if (titlesAsync.isLoading)
                const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    semanticsLabel: 'Chargement des titres…',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
