import 'package:flutter/material.dart';

import '../../recipes/domain/storage_advice.dart';
import '../domain/meal_storage_rules.dart';

/// Feuille de conservation et de réchauffage d'un plat.
///
/// Deux natures de contenu s'y côtoient, et la distinction est délibérément
/// visible : en tête, la consigne **calculée** depuis le délai réel — elle ne
/// dépend d'aucun modèle et ne peut pas être fantaisiste ; en dessous, le
/// conseil propre au plat, produit par l'IA.
Future<void> showStorageAdviceSheet(
  BuildContext context, {
  required String titre,
  required StorageAdvice advice,
  required int daysAhead,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) =>
        _StorageSheet(titre: titre, advice: advice, daysAhead: daysAhead),
  );
}

class _StorageSheet extends StatelessWidget {
  final String titre;
  final StorageAdvice advice;
  final int daysAhead;

  const _StorageSheet({
    required this.titre,
    required this.advice,
    required this.daysAhead,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mode = mealStorageMode(daysAhead);

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (ctx, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.4,
                ),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Icon(Icons.kitchen_outlined, color: theme.colorScheme.primary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Conservation — $titre',
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Consigne calculée : elle ne dépend d'aucune génération.
          if (daysAhead > 0)
            Card(
              margin: EdgeInsets.zero,
              color: mode == MealStorageMode.freezer
                  ? theme.colorScheme.tertiaryContainer
                  : theme.colorScheme.primaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      mode == MealStorageMode.freezer
                          ? Icons.ac_unit_outlined
                          : Icons.kitchen_outlined,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        mealStorageInstruction(daysAhead),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (daysAhead > 0) const SizedBox(height: 16),

          if (advice.resume.isNotEmpty) ...[
            Text(advice.resume, style: theme.textTheme.bodyMedium),
            const SizedBox(height: 16),
          ],

          _block(theme, 'Refroidissement', advice.refroidissement),
          _window(theme, 'Réfrigérateur', advice.refrigerateur),
          if (advice.congelateur != null)
            _window(theme, 'Congélateur', advice.congelateur!)
          else
            _block(
              theme,
              'Congélation déconseillée',
              advice.congelationDeconseillee ?? '',
            ),
          _block(
            theme,
            'Réchauffage',
            [
              advice.rechauffage.summary,
              advice.rechauffage.conseil,
            ].where((s) => s.trim().isNotEmpty).join('. '),
          ),
          _list(
            theme,
            'À ajouter au dernier moment',
            advice.aAjouterAuDernierMoment,
          ),
          _list(
            theme,
            'Ne plus consommer si',
            advice.signesDAlerte,
            color: theme.colorScheme.error,
          ),
        ],
      ),
    );
  }

  Widget _block(ThemeData theme, String label, String value) {
    if (value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }

  Widget _window(ThemeData theme, String label, StorageWindow window) {
    final detail = [
      window.contenant,
      window.conseil,
    ].where((s) => s.trim().isNotEmpty).join(' ');
    final text = [
      window.duree,
      detail,
    ].where((s) => s.trim().isNotEmpty).join('. ');
    return _block(theme, label, text);
  }

  Widget _list(
    ThemeData theme,
    String label,
    List<String> items, {
    Color? color,
  }) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: color ?? theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('• $item', style: theme.textTheme.bodyMedium),
            ),
        ],
      ),
    );
  }
}
