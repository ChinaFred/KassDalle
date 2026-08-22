import 'package:flutter/material.dart';

/// Un bloc d'étape, dans une expérience qui progresse par paliers.
///
/// Le principe : une étape ne s'affiche que si la précédente a abouti. Chaque
/// palier se valide seul, avant qu'on écrive le suivant. L'écran qui empile ces
/// blocs décide de leur apparition ; ce widget ne fait que les habiller.
class ExperimentStep extends StatelessWidget {
  /// Numéro affiché dans la pastille, à partir de 1.
  final int index;

  final String title;

  /// Ce que l'étape attend de l'utilisateur, en une phrase.
  final String? subtitle;

  /// L'étape a produit son résultat : la pastille passe au vert.
  final bool done;

  final Widget child;

  const ExperimentStep({
    super.key,
    required this.index,
    required this.title,
    required this.child,
    this.subtitle,
    this.done = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: done
                      ? scheme.primary
                      : scheme.surfaceContainerHighest,
                  foregroundColor: done ? scheme.onPrimary : scheme.onSurface,
                  child: done
                      ? const Icon(Icons.check, size: 18)
                      : Text('$index', style: theme.textTheme.labelLarge),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            child,
          ],
        ),
      ),
    );
  }
}
