import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../domain/plating_advice.dart';

/// Briques d'affichage du conseil de dressage.
///
/// Elles ne savent rien de l'IA ni de Firestore : elles reçoivent un conseil
/// déjà produit et le mettent en page. L'onglet garde ainsi l'orchestration,
/// et ces widgets restent lisibles sans contexte.

/// Carte à puces — construction, pièges, dernière minute.
class PlatingListCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<String> items;

  const PlatingListCard({
    super.key,
    required this.title,
    required this.icon,
    required this.items,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ExcludeSemantics(child: Icon(icon, size: 18)),
                const SizedBox(width: 8),
                Text(title, style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: 12),
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('• '),
                    Expanded(child: Text(item)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Une étape de montage : le geste, son visuel, et l'action pour le créer.
class PlatingStepCard extends StatelessWidget {
  final int index;
  final PlatingStep step;

  /// Null quand l'utilisateur n'a pas le droit de générer une image.
  final VoidCallback? onGenerateImage;

  /// Vrai pendant la génération du visuel de cette étape.
  final bool generating;

  const PlatingStepCard({
    super.key,
    required this.index,
    required this.step,
    this.onGenerateImage,
    this.generating = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final imageUrl = step.imageUrl;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 13,
                  backgroundColor: theme.colorScheme.primaryContainer,
                  child: Text(
                    '${index + 1}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (step.titre.isNotEmpty)
                        Text(
                          step.titre,
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      if (step.titre.isNotEmpty) const SizedBox(height: 4),
                      Text(step.geste),
                    ],
                  ),
                ),
              ],
            ),
            if (step.elements.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final element in step.elements)
                    Chip(
                      visualDensity: VisualDensity.compact,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      label: Text(element, style: theme.textTheme.labelSmall),
                    ),
                ],
              ),
            ],
            if (imageUrl != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: CachedNetworkImage(
                  imageUrl: imageUrl,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  placeholder: (context, _) => const SizedBox(
                    height: 160,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  errorWidget: (context, _, _) => const SizedBox(
                    height: 60,
                    child: Center(child: Text('Visuel indisponible')),
                  ),
                ),
              ),
            ] else if (step.imagePrompt != null) ...[
              const SizedBox(height: 12),
              if (generating)
                const Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 10),
                    Expanded(child: Text('Création du visuel de montage…')),
                  ],
                )
              else if (onGenerateImage != null)
                OutlinedButton.icon(
                  onPressed: onGenerateImage,
                  icon: const Icon(Icons.image_outlined, size: 18),
                  label: const Text('Illustrer cette étape'),
                )
              else
                Text(
                  'Un visuel de montage est proposé pour cette étape.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Bandeau d'en-tête : intention du plat, complexité, moteur ayant répondu.
class PlatingHeaderCard extends StatelessWidget {
  final PlatingAdvice advice;

  const PlatingHeaderCard({super.key, required this.advice});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ExcludeSemantics(
                  child: Icon(
                    Icons.restaurant_outlined,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('Dressage', style: theme.textTheme.titleMedium),
                ),
              ],
            ),
            if (advice.resume.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(advice.resume),
            ],
            if (advice.contenant.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      Icons.dinner_dining_outlined,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(child: Text(advice.contenant)),
                ],
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                Chip(
                  visualDensity: VisualDensity.compact,
                  label: Text(advice.complexite.label),
                ),
                if (advice.userInstruction != null)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.tune, size: 16),
                    label: Text(advice.userInstruction!),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
