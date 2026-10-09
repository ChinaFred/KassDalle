import 'package:flutter/material.dart';

import '../../domain/plating_advice.dart';
import '../../../../core/theme/app_icon_size.dart';
import '../../../../core/widgets/app_network_image.dart';
import '../../../../core/utils/app_image_url.dart';

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
                ExcludeSemantics(child: Icon(icon, size: AppIconSize.small)),
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

  /// Non nul sur la dernière étape illustrée, la seule qu'on puisse refaire :
  /// les visuels s'enchaînent, reprendre une étape du milieu laisserait
  /// derrière elle des images nées d'une assiette disparue.
  final VoidCallback? onRedoImage;

  /// Vrai pendant la génération du visuel de cette étape.
  final bool generating;

  /// Vrai pendant la génération d'un visuel, ici ou ailleurs dans la série.
  ///
  /// Les actions restent visibles mais deviennent inertes : les images se
  /// construisent l'une sur l'autre, en lancer deux de front produirait deux
  /// assiettes concurrentes et une série incohérente.
  final bool busy;

  const PlatingStepCard({
    super.key,
    required this.index,
    required this.step,
    this.onGenerateImage,
    this.onRedoImage,
    this.generating = false,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final texte = Column(
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
        if (step.imageUrl == null) ...[
          const SizedBox(height: 12),
          PlatingImageAction(
            generating: generating,
            onGenerate: onGenerateImage,
            disabled: busy,
            label: 'Illustrer cette étape',
          ),
        ] else if (generating || onRedoImage != null) ...[
          const SizedBox(height: 12),
          PlatingImageAction(
            generating: generating,
            onGenerate: onRedoImage,
            disabled: busy,
            label: 'Refaire ce visuel',
            icon: Icons.refresh,
          ),
        ],
      ],
    );

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        // Le visuel accompagne le geste, il ne le remplace pas : en pleine
        // largeur, il chassait le texte hors de l'écran et obligeait à faire
        // l'aller-retour entre la consigne et l'image censée l'éclairer.
        child: LayoutBuilder(
          builder: (context, constraints) {
            final image = step.imageUrl == null
                ? null
                : PlatingImage(url: step.imageUrl!);
            if (image == null) return texte;

            if (constraints.maxWidth < 480) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [texte, const SizedBox(height: 12), image],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: texte),
                const SizedBox(width: 16),
                SizedBox(width: 200, child: image),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Visuel de montage, cliquable pour être vu en grand.
class PlatingImage extends StatelessWidget {
  final String url;

  const PlatingImage({super.key, required this.url});

  @override
  Widget build(BuildContext context) {
    // Une image hors de Kass'Dalle n'ouvre pas de visionneuse.
    final viewable = isAppImageUrl(url);
    return Semantics(
      button: viewable,
      label: viewable ? 'Agrandir le visuel de montage' : 'Visuel indisponible',
      child: InkWell(
        onTap: !viewable
            ? null
            : () => showDialog<void>(
                context: context,
                builder: (context) => Dialog(
                  clipBehavior: Clip.antiAlias,
                  child: InteractiveViewer(
                    child: AppNetworkImage(imageUrl: url, fit: BoxFit.contain),
                  ),
                ),
              ),
        borderRadius: BorderRadius.circular(8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: AspectRatio(
            aspectRatio: 1,
            child: AppNetworkImage(
              imageUrl: url,
              fit: BoxFit.cover,
              placeholder: (context, _) =>
                  const Center(child: CircularProgressIndicator()),
              errorWidget: (context, _, _) =>
                  const Center(child: Text('Visuel indisponible')),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bouton de génération d'un visuel, ou son attente.
class PlatingImageAction extends StatelessWidget {
  final bool generating;
  final VoidCallback? onGenerate;
  final String label;
  final IconData icon;

  /// Une génération est en cours ailleurs : le bouton reste lisible, mais
  /// inerte. Le faire disparaître laisserait croire que l'action n'existe pas.
  final bool disabled;

  const PlatingImageAction({
    super.key,
    required this.generating,
    required this.onGenerate,
    required this.label,
    this.icon = Icons.image_outlined,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    if (generating) {
      return const Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: 10),
          Expanded(child: Text('Création du visuel de montage…')),
        ],
      );
    }
    if (onGenerate == null) return const SizedBox.shrink();
    return OutlinedButton.icon(
      onPressed: disabled ? null : onGenerate,
      icon: Icon(icon, size: AppIconSize.small),
      label: Text(label),
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
                      size: AppIconSize.small,
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
                    avatar: const Icon(
                      Icons.tune_outlined,
                      size: AppIconSize.inline,
                    ),
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
