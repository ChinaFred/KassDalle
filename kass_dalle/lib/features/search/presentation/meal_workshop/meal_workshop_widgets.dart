import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/theme/app_icon_size.dart';
import '../../../planning/domain/meal_kind.dart';
import '../../../planning/presentation/meal_course_style.dart';
import '../../data/meal_workshop_functions.dart';
import '../../domain/meal_workshop_freeze.dart';
import '../../domain/meal_workshop_menu.dart';
import 'meal_workshop_providers.dart';

/// Les briques de l'écran « Atelier repas » : bulles de la conversation,
/// cartes système, lignes du menu, lignes de figement. Rien ici n'écrit ni
/// n'appelle : l'écran tient l'état, ces widgets l'affichent.
///
/// Deux icônes, deux sens : le robot (`Icons.smart_toy_outlined`) marque ce
/// que l'IA a écrit — chaque bulle, chaque « pourquoi » du menu. Aucune
/// étoile dans l'écran.

// ── Conversation ─────────────────────────────────────────────────────────────

/// Le message de la personne, à droite.
class WorkshopUserBubble extends StatelessWidget {
  final String text;

  const WorkshopUserBubble({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: FractionallySizedBox(
        widthFactor: 0.8,
        alignment: Alignment.centerRight,
        child: Align(
          alignment: Alignment.centerRight,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: scheme.primaryContainer,
              borderRadius: BorderRadius.circular(16),
            ),
            child: SelectableText(
              text,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: scheme.onPrimaryContainer,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// La réponse de l'IA, à gauche, avec le robot ; sous elle, ce qui a changé
/// dans le menu. Le texte est brut : ni Markdown, ni lien.
class WorkshopAssistantBubble extends StatefulWidget {
  final WorkshopTurnResult result;

  /// Plat ou menu : « Plat mis à jour » ne compte pas les services.
  final MealKind kind;

  /// Services marqués « Modifié » par ce tour.
  final int changedCount;

  /// Le JSON du menu est identique au tour précédent.
  final bool unchanged;

  /// Ouvre le menu (téléphone : la feuille). `null` sur grand écran, où le
  /// panneau est toujours visible.
  final VoidCallback? onOpenMenu;

  const WorkshopAssistantBubble({
    super.key,
    required this.result,
    required this.kind,
    required this.changedCount,
    required this.unchanged,
    this.onOpenMenu,
  });

  @override
  State<WorkshopAssistantBubble> createState() =>
      _WorkshopAssistantBubbleState();
}

class _WorkshopAssistantBubbleState extends State<WorkshopAssistantBubble> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = widget.result.reponse;
    final foldable = text.length > kWorkshopReplyFoldChars;
    final shown = foldable && !_expanded
        ? '${text.substring(0, kWorkshopReplyFoldChars).trimRight()}…'
        : text;
    final thing = widget.kind == MealKind.plat ? 'plat' : 'menu';
    final String menuLine;
    if (widget.kind == MealKind.plat) {
      menuLine = widget.unchanged ? 'Plat inchangé' : 'Plat mis à jour';
    } else {
      menuLine = widget.unchanged
          ? 'Menu inchangé'
          : 'Menu mis à jour · ${_plural(widget.result.menu.courses.length, 'service')}'
                '${widget.changedCount > 0 ? ' · ${_plural(widget.changedCount, 'modifié')}' : ''}';
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 10, right: 8),
            child: Icon(
              Icons.smart_toy_outlined,
              size: AppIconSize.small,
              color: scheme.primary,
              semanticLabel: 'Réponse de l\'IA',
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        shown.isEmpty
                            ? (widget.unchanged
                                  ? 'L\'IA n\'a rien écrit et le $thing n\'a pas changé.'
                                  : 'L\'IA n\'a rien écrit : seul le $thing a changé.')
                            : shown,
                        style: theme.textTheme.bodyMedium,
                      ),
                      if (foldable)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () =>
                                setState(() => _expanded = !_expanded),
                            child: Text(
                              _expanded ? 'Réduire' : 'Lire la suite',
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                // Téléphone : la ligne ouvre la feuille, cible de 48 px.
                InkWell(
                  onTap: widget.onOpenMenu,
                  borderRadius: BorderRadius.circular(4),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: widget.onOpenMenu == null ? 0 : 48,
                    ),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        child: Text(
                          menuLine,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// « L'IA compose… », le temps d'un tour.
class WorkshopPendingRow extends StatelessWidget {
  const WorkshopPendingRow({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(
              Icons.smart_toy_outlined,
              size: AppIconSize.small,
              color: theme.colorScheme.primary,
              semanticLabel: 'IA',
            ),
            const SizedBox(width: 8),
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text(
              'L\'IA compose…',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Une carte système pleine largeur : périmètre, information. Jamais une bulle.
class WorkshopSystemCard extends StatelessWidget {
  final IconData icon;
  final String text;

  const WorkshopSystemCard({super.key, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: AppIconSize.small,
            color: scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// L'échec d'un tour : un titre, une phrase, et « Réessayer » quand c'est
/// permis — il renvoie le texte resté dans le champ.
///
/// Une carte dans le fil de la conversation, et non `AppErrorState(compact:
/// true)` : elle prend la place de la réponse qui n'est pas venue, alignée
/// comme une bulle, annoncée par `liveRegion`, et son titre dit ce qui n'a
/// pas eu lieu (« Réponse non reçue. », « Réponse illisible, plat
/// inchangé. »). `AppErrorState` sert à l'erreur du contexte, en tête de
/// liste (« Atelier non prêt »).
class WorkshopErrorCard extends StatelessWidget {
  final WorkshopFailure failure;

  /// Plat ou menu : « Réponse illisible, plat inchangé. » en mode Plat.
  final MealKind kind;
  final VoidCallback? onRetry;

  const WorkshopErrorCard({
    super.key,
    required this.failure,
    required this.kind,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = failure.kind == WorkshopFailureKind.unreadable
        ? 'Réponse illisible, ${kind == MealKind.plat ? 'plat' : 'menu'} inchangé.'
        : 'Réponse non reçue.';
    final retry = failure.retryable ? onRetry : null;

    return Semantics(
      liveRegion: true,
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        color: scheme.errorContainer,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.error_outline, color: scheme.onErrorContainer),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                failure.message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
              if (retry != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: retry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Réessayer'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ── Menu ─────────────────────────────────────────────────────────────────────

/// Une puce : « À rédiger », « Recette inconnue : à rédiger », « Modifié ».
class WorkshopPill extends StatelessWidget {
  final String text;
  final IconData? icon;
  final Color background;
  final Color foreground;
  final String? tooltip;

  const WorkshopPill({
    super.key,
    required this.text,
    this.icon,
    required this.background,
    required this.foreground,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: AppIconSize.badge, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            text,
            style: Theme.of(
              context,
            ).textTheme.labelSmall?.copyWith(color: foreground),
          ),
        ],
      ),
    );
    return tooltip == null ? pill : Tooltip(message: tooltip!, child: pill);
  }
}

/// Ce qu'une ligne de figement peut demander à l'écran.
class WorkshopFreezeActions {
  final VoidCallback? onRetry;
  final VoidCallback? onWriteInstead;
  final VoidCallback? onRemove;

  const WorkshopFreezeActions({
    this.onRetry,
    this.onWriteInstead,
    this.onRemove,
  });
}

/// Une ligne du menu en cours : type, titre, état, raison, accompagnements.
/// Pendant et après un figement, l'état est la ligne de figement.
class WorkshopCourseTile extends StatelessWidget {
  final WorkshopCourse course;
  final bool changed;
  final int menuPortions;
  final MealWorkshopContext? workshop;

  /// L'état de figement de ce service ; `null` hors figement.
  final FreezeLineState? freezeState;
  final WorkshopFreezeActions freezeActions;

  /// Vrai pendant les appels du figement : les actions des lignes attendent.
  final bool busy;

  const WorkshopCourseTile({
    super.key,
    required this.course,
    required this.changed,
    required this.menuPortions,
    required this.workshop,
    this.freezeState,
    this.freezeActions = const WorkshopFreezeActions(),
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final freeze = freezeState;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Décorative : le type est écrit juste à côté.
              ExcludeSemantics(
                child: Icon(
                  courseRoleIcon(course.role),
                  size: AppIconSize.small,
                  color: scheme.primary,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  course.typeLabel,
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: scheme.primary,
                  ),
                ),
              ),
              if (changed && freeze == null)
                WorkshopPill(
                  text: 'Modifié',
                  background: scheme.secondaryContainer,
                  foreground: scheme.onSecondaryContainer,
                ),
            ],
          ),
          const SizedBox(height: 2),
          Text(course.title, style: theme.textTheme.bodyLarge),
          const SizedBox(height: 4),
          if (freeze != null)
            WorkshopFreezeLine(
              state: freeze,
              actions: freezeActions,
              busy: busy,
            )
          else
            _buildStatus(context),
          if (course.description != null) ...[
            const SizedBox(height: 4),
            Text(course.description!, style: small),
          ],
          if (course.why != null) ...[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.smart_toy_outlined,
                  size: AppIconSize.inline,
                  color: scheme.primary,
                  semanticLabel: 'Raison donnée par l\'IA',
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    course.why!,
                    style: small?.copyWith(fontStyle: FontStyle.italic),
                  ),
                ),
              ],
            ),
          ],
          for (final side in course.sides) _buildSide(context, side),
        ],
      ),
    );
  }

  Widget _buildStatus(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final recipeId = course.recipeId;
    if (recipeId != null) {
      final recipe = workshop?.recipesById[recipeId];
      final book = recipe?.bookTitre ?? 'Sans livre';
      final portions = recipe?.portions;
      final gap = portions != null && portions != menuPortions
          ? ' · recette pour $portions, repas pour $menuPortions'
          : '';
      // Cible de 48 px : la ligne s'ouvre sur la fiche. C'est le seul lien de
      // l'écran : un identifiant cité dans le texte de l'IA n'en est pas un.
      return InkWell(
        onTap: () => context.push('/recipes/$recipeId'),
        borderRadius: BorderRadius.circular(4),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              Icon(
                Icons.menu_book_outlined,
                size: AppIconSize.inline,
                color: scheme.onSurfaceVariant,
                semanticLabel: 'Recette de la bibliothèque',
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '$book$gap',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    decoration: TextDecoration.underline,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    if (course.unknownRecipeId) {
      return WorkshopPill(
        text: 'Recette inconnue : à rédiger',
        background: scheme.tertiaryContainer,
        foreground: scheme.onTertiaryContainer,
        tooltip:
            'L\'IA a cité une recette absente du périmètre. Le plat sera rédigé.',
      );
    }
    return WorkshopPill(
      text: 'À rédiger',
      icon: Icons.edit_note,
      background: scheme.secondaryContainer,
      foreground: scheme.onSecondaryContainer,
    );
  }

  Widget _buildSide(BuildContext context, WorkshopSide side) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = theme.textTheme.bodySmall;
    final staple = side.stapleId == null
        ? null
        : workshop?.stapleById(side.stapleId!);
    final Widget row;
    if (staple != null) {
      row = Row(
        children: [
          Icon(
            Icons.rice_bowl_outlined,
            size: AppIconSize.inline,
            color: scheme.onSurfaceVariant,
            semanticLabel: 'Garniture',
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${staple.name} · ${staple.quantityLabel} par part',
              style: style,
            ),
          ),
        ],
      );
    } else if (side.recipeId != null) {
      // Cible de 48 px : la ligne s'ouvre sur la fiche.
      row = InkWell(
        onTap: () => context.push('/recipes/${side.recipeId}'),
        borderRadius: BorderRadius.circular(4),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Row(
            children: [
              Icon(
                Icons.menu_book_outlined,
                size: AppIconSize.inline,
                color: scheme.onSurfaceVariant,
                semanticLabel: 'Recette de la bibliothèque',
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  side.label,
                  style: style?.copyWith(decoration: TextDecoration.underline),
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      // Texte libre, identifiant reconnu ou non : le libellé seul.
      row = Text(side.label, style: style);
    }
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 4),
      child: row,
    );
  }
}

// ── Figement ─────────────────────────────────────────────────────────────────

/// L'état d'un service pendant et après le figement : « En attente »,
/// « Rédaction… », « Brouillon créé · Ouvrir », « Non rédigée — Réessayer »…
class WorkshopFreezeLine extends StatelessWidget {
  final FreezeLineState state;
  final WorkshopFreezeActions actions;
  final bool busy;

  const WorkshopFreezeLine({
    super.key,
    required this.state,
    required this.actions,
    required this.busy,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final error = theme.textTheme.bodySmall?.copyWith(color: scheme.error);
    final retry = busy ? null : actions.onRetry;

    Widget open(String label, String location) =>
        TextButton(onPressed: () => context.push(location), child: Text(label));

    return switch (state) {
      FreezeWaiting() => Text('En attente', style: small),
      FreezeWriting() => Semantics(
        liveRegion: true,
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 8),
            Text('Rédaction…', style: small),
          ],
        ),
      ),
      // En `Wrap` : à 200 % de texte, « Ouvrir » passe sous la ligne au lieu
      // de déborder du panneau.
      FreezeDraftCreated(:final draftId) => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        children: [
          Icon(
            Icons.edit_note,
            size: AppIconSize.inline,
            color: scheme.onSurfaceVariant,
            semanticLabel: 'Brouillon',
          ),
          Text('Brouillon créé ·', style: small),
          open('Ouvrir', '${AppRoutes.drafts}/$draftId'),
        ],
      ),
      FreezeLinked(:final recipeId) => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        children: [
          Icon(
            Icons.menu_book_outlined,
            size: AppIconSize.inline,
            color: scheme.onSurfaceVariant,
            semanticLabel: 'Recette de la bibliothèque',
          ),
          Text('Recette liée ·', style: small),
          open('Ouvrir', '/recipes/$recipeId'),
        ],
      ),
      FreezeLinkedUnreadable() => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          Text('Recette plus accessible', style: error),
          TextButton(
            onPressed: busy ? null : actions.onWriteInstead,
            child: const Text('Rédiger à la place'),
          ),
          TextButton(
            onPressed: busy ? null : actions.onRemove,
            child: const Text('Retirer du repas'),
          ),
        ],
      ),
      FreezeFailed() => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          Text('Non rédigée —', style: error),
          TextButton(onPressed: retry, child: const Text('Réessayer')),
        ],
      ),
      FreezeNoRecipe() => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          Text('Non rédigée. L\'IA n\'a pas rendu de recette.', style: error),
          TextButton(onPressed: retry, child: const Text('Réessayer')),
        ],
      ),
      FreezeBudgetStopped() => Text(
        'Non rédigée — plafond atteint',
        style: error,
      ),
      FreezePermissionDenied() => Text(
        'Non rédigée. L\'IA est réservée aux éditeurs.',
        style: error,
      ),
      FreezeSaveFailed() => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          Text('Brouillon non enregistré —', style: error),
          TextButton(onPressed: retry, child: const Text('Réessayer')),
        ],
      ),
    };
  }
}

String _plural(int n, String word) => '$n $word${n > 1 ? 's' : ''}';
