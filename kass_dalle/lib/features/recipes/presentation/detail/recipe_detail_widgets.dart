import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../auth/presentation/auth_providers.dart';
import '../../../../core/theme/app_icon_size.dart';

// ── Couverture par défaut "Recette libre" ──────────────────────────────────

class RecipeDetailFreeRecipeCover extends StatelessWidget {
  final bool isOwner;
  const RecipeDetailFreeRecipeCover({super.key, this.isOwner = false});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.secondaryContainer;
    final fg = Theme.of(context).colorScheme.onSecondaryContainer;
    return Container(
      width: 32,
      height: 44,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(Icons.menu_book_outlined, size: AppIconSize.small, color: fg),
          if (isOwner)
            Positioned(
              bottom: 2,
              right: 2,
              child: Icon(
                Icons.add_a_photo_outlined,
                size: AppIconSize.badge,
                color: fg.withValues(alpha: 0.7),
              ),
            ),
        ],
      ),
    );
  }
}

// ── Label propriétaire ────────────────────────────────────────────────────────

class RecipeDetailOwnerLabel extends ConsumerWidget {
  final String ownerUid;
  const RecipeDetailOwnerLabel({super.key, required this.ownerUid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name = ref.watch(memberNameProvider(ownerUid));
    if (name == null) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.person_outline,
          size: AppIconSize.badge,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 2),
        Text(
          name,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
