import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../../../../../core/theme/app_icon_size.dart';
import '../../../../../core/utils/context_extensions.dart';
import '../../../../../core/widgets/error_message.dart';
import '../../../../planning/presentation/meal_course_style.dart';
import '../../../data/sandbox_functions.dart';
import '../../../domain/meal_workshop_menu.dart';
import '../../../domain/sandbox_model_choice.dart';
import '../../sandbox_providers.dart';
import '../../widgets/sandbox_model_picker.dart';

/// Les briques de l'écran « Atelier repas » du bac à sable : bulles de la
/// conversation, lignes du menu, zone « Mesures ». Rien ici n'écrit ni
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
/// dans le menu, la ligne de mesures du tour, et le volet « Réponse brute ».
class WorkshopAssistantBubble extends StatefulWidget {
  final WorkshopTurnResult result;

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
    final menuLine = widget.unchanged
        ? 'Menu inchangé'
        : 'Menu mis à jour · ${_plural(widget.result.menu.courses.length, 'service')}'
              '${widget.changedCount > 0 ? ' · ${_plural(widget.changedCount, 'modifié')}' : ''}';

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
                                  ? 'L\'IA n\'a rien écrit et le menu n\'a pas changé.'
                                  : 'L\'IA n\'a rien écrit : seul le menu a changé.')
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
                InkWell(
                  onTap: widget.onOpenMenu,
                  borderRadius: BorderRadius.circular(4),
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
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: SelectableText(
                    workshopUsageLine(widget.result.usage),
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontFamily: 'monospace',
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                _RawAnswerTile(result: widget.result),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// « Réponse brute » : le JSON contrôlé, puis les champs du contrôle serveur.
class _RawAnswerTile extends StatelessWidget {
  final WorkshopTurnResult result;

  const _RawAnswerTile({required this.result});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
        childrenPadding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        dense: true,
        title: Text('Réponse brute', style: theme.textTheme.bodySmall),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              result.rawTruncated ? '${result.raw}\n[…coupé]' : result.raw,
              style: mono,
            ),
          ),
          const SizedBox(height: 8),
          Text('Contrôle serveur', style: theme.textTheme.labelMedium),
          for (final line in result.control.lines)
            SelectableText(line, style: mono),
          SelectableText(
            'prompt : ${formatWorkshopCount(result.promptChars)} caractères · '
            'tour ${result.turn}'
            '${result.reponseTruncated ? ' · texte coupé' : ''}'
            '${result.usage.stopReason == null ? '' : ' · arrêt : ${result.usage.stopReason}'}',
            style: mono,
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

/// L'échec d'un tour : le message, puis le code renvoyé par `sandboxFn` et
/// sa raison — l'administrateur lit les codes (palier 0). « Réessayer »
/// renvoie le texte resté dans le champ.
class WorkshopErrorCard extends StatelessWidget {
  final Object error;
  final VoidCallback? onRetry;

  const WorkshopErrorCard({super.key, required this.error, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final sandbox = error is SandboxCallException
        ? error as SandboxCallException
        : null;
    final unreadable = sandbox?.reason == kWorkshopUnreadableReason;
    final title = unreadable
        ? 'Réponse illisible, menu inchangé.'
        : 'Réponse non reçue.';
    // Hors `sandboxFn` (réseau, décodage) : le titre lisible de
    // `describeError`, « Connexion perdue » pour une `ClientException`. Les
    // titres n'ont pas de point final ; le message serveur en a un.
    final message = sandbox != null
        ? sandbox.message
        : '${describeError(error).title}.';
    final code = sandbox == null
        ? error.runtimeType.toString()
        : '${sandbox.code}${sandbox.reason == null ? '' : ' · ${sandbox.reason}'}';
    final usage = sandbox?.details?['usage'];
    final usageLine = usage is Map
        ? workshopUsageLine(
            WorkshopUsage.fromJson(Map<String, dynamic>.from(usage)),
          )
        : null;
    final preview = sandbox?.details?['rawPreview'];

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
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                code,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  color: scheme.onErrorContainer,
                ),
              ),
              if (usageLine != null)
                SelectableText(
                  'tour facturé · $usageLine',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: scheme.onErrorContainer,
                  ),
                ),
              if (preview is String && preview.isNotEmpty)
                Theme(
                  data: theme.copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(
                      'Texte rendu',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onErrorContainer,
                      ),
                    ),
                    children: [
                      SelectableText(
                        preview,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontFamily: 'monospace',
                          color: scheme.onErrorContainer,
                        ),
                      ),
                    ],
                  ),
                ),
              if (onRetry != null) ...[
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonalIcon(
                    onPressed: onRetry,
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

/// Une ligne du menu en cours : type, titre, état, raison, accompagnements.
class WorkshopCourseTile extends StatelessWidget {
  final WorkshopCourse course;
  final bool changed;
  final int menuPortions;
  final MealWorkshopContext? workshop;

  const WorkshopCourseTile({
    super.key,
    required this.course,
    required this.changed,
    required this.menuPortions,
    required this.workshop,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );

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
              if (changed)
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
          ? ' · recette pour $portions, menu pour $menuPortions'
          : '';
      // Cible de 48 px : la ligne s'ouvre sur la fiche.
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
      // Texte libre, identifiant reconnu ou non : le libellé seul. Les
      // compteurs du contrôle sont dans « Réponse brute ».
      row = Text(side.label, style: style);
    }
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 4),
      child: row,
    );
  }
}

// ── Mesures ──────────────────────────────────────────────────────────────────

/// La zone « Mesures » du palier 0 : choix du modèle, taille du contexte,
/// tableau des tours et « Copier le tableau ».
class WorkshopMeasuresPanel extends StatelessWidget {
  final SandboxModelChoice? modelChoice;
  final ValueChanged<SandboxModelChoice?> onModelChanged;
  final bool enabled;

  /// Taille du contexte fixe avant le premier tour, en caractères.
  final int contextChars;

  /// Le dernier tour rendu, pour la taille exacte du prompt et ses jetons.
  final WorkshopTurnResult? lastResult;
  final List<WorkshopTurnMeasure> measures;

  const WorkshopMeasuresPanel({
    super.key,
    required this.modelChoice,
    required this.onModelChanged,
    required this.enabled,
    required this.contextChars,
    required this.lastResult,
    required this.measures,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final last = lastResult;
    final contextLine = last == null
        ? 'Contexte fixe : ${formatWorkshopCount(contextChars)} caractères '
              '(recettes, garnitures, préférences) · jetons connus après le '
              'premier tour'
        : 'Contexte envoyé : ${formatWorkshopCount(last.promptChars)} '
              'caractères · ${formatWorkshopCount(last.usage.inputTokens)} '
              'jetons d\'entrée';
    final total = workshopCostTotal(measures);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Mesures', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          SandboxModelPicker(
            featureKey: kWorkshopFeature,
            value: modelChoice,
            onChanged: onModelChanged,
            enabled: enabled,
          ),
          const SizedBox(height: 8),
          Text(contextLine, style: small),
          const SizedBox(height: 12),
          if (measures.isEmpty)
            Text('Aucun tour pour l\'instant.', style: small)
          else ...[
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: _MeasuresTable(measures: measures),
            ),
            const SizedBox(height: 8),
            Text(
              'Total : ${formatWorkshopCost(total.knownUsd)} sur '
              '${_plural(measures.length, 'tour')}'
              '${total.unpriced > 0 ? ' · ${_plural(total.unpriced, 'tour')} '
                        'sans montant' : ''}',
              style: small,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: workshopMeasuresTable(measures)),
                  );
                  if (!context.mounted) return;
                  context.showSuccessSnackBar('Tableau copié.');
                },
                icon: const Icon(Icons.copy_all_outlined),
                label: const Text('Copier le tableau'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _MeasuresTable extends StatelessWidget {
  final List<WorkshopTurnMeasure> measures;

  const _MeasuresTable({required this.measures});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    final head = mono?.copyWith(fontWeight: FontWeight.w600);

    Widget cell(String text, {TextStyle? style}) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Text(text, style: style ?? mono),
    );

    return Table(
      defaultColumnWidth: const IntrinsicColumnWidth(),
      children: [
        TableRow(
          children: [
            cell('conv.', style: head),
            cell('n°', style: head),
            cell('coût', style: head),
            cell('jetons', style: head),
            cell('durée', style: head),
            cell('inv.', style: head),
            cell('état', style: head),
          ],
        ),
        for (final m in measures)
          TableRow(
            children: [
              cell('${m.conversation}'),
              cell('${m.turn}'),
              cell(formatWorkshopCost(m.costUsd)),
              cell(
                '${formatWorkshopCount(m.inputTokens)}→'
                '${formatWorkshopCount(m.outputTokens)}',
              ),
              cell(formatWorkshopDuration(m.durationMs)),
              cell('${m.inventedIds}'),
              cell(
                m.unreadable
                    ? 'illisible'
                    : m.truncated
                    ? 'tronqué'
                    : m.droppedCourses > 0
                    ? '${m.droppedCourses} écarté(s)'
                    : '',
              ),
            ],
          ),
      ],
    );
  }
}

String _plural(int n, String word) => '$n $word${n > 1 ? 's' : ''}';
