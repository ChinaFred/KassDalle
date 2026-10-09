import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../../core/utils/web_download.dart';
import '../../../../core/utils/context_extensions.dart';
import '../../../auth/presentation/auth_providers.dart';
import '../../../processing/domain/processing_job.dart';
import '../../../processing/presentation/processing_trail_row.dart';
import '../../../processing/presentation/processing_providers.dart';
import '../../domain/recipe.dart';
import '../../../../core/theme/app_icon_size.dart';

// ── Mode de filtre (public car utilisé par le screen) ─────────────────────────

enum WorkQueueFilter { me, family, allUsers }

// ── Filtre dropdown ────────────────────────────────────────────────────────────

class WorkQueueFilterDropdown extends StatelessWidget {
  final bool isAdmin;
  final WorkQueueFilter filterMode;
  final ValueChanged<WorkQueueFilter> onChanged;

  const WorkQueueFilterDropdown({
    super.key,
    required this.isAdmin,
    required this.filterMode,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final options = [
      (WorkQueueFilter.me, 'Mes éléments'),
      (WorkQueueFilter.family, 'Groupe familial'),
      if (isAdmin) (WorkQueueFilter.allUsers, 'Tous les utilisateurs'),
    ];
    return DropdownButtonHideUnderline(
      child: DropdownButton<WorkQueueFilter>(
        value: filterMode,
        isDense: true,
        items: options
            .map((opt) => DropdownMenuItem(value: opt.$1, child: Text(opt.$2)))
            .toList(),
        onChanged: (mode) {
          if (mode != null) onChanged(mode);
        },
      ),
    );
  }
}

// ── Filtre UID admin ──────────────────────────────────────────────────────────

class WorkQueueAdminUidFilter extends ConsumerWidget {
  final List<ProcessingJob> allJobs;
  final List<Recipe> allDrafts;

  const WorkQueueAdminUidFilter({
    super.key,
    required this.allJobs,
    required this.allDrafts,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentFilter = ref.watch(adminJobUserFilterProvider);
    final uids = {
      ...allJobs.map((j) => j.createdBy),
      ...allDrafts.map((d) => d.createdBy),
    }.toList();
    if (uids.length <= 1) return const SizedBox.shrink();
    return DropdownButtonHideUnderline(
      child: DropdownButton<String?>(
        value: currentFilter,
        hint: const Text('Tous'),
        isDense: true,
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('Tous')),
          ...uids.map(
            (uid) => DropdownMenuItem<String?>(
              value: uid,
              child: _UserNameText(uid: uid),
            ),
          ),
        ],
        onChanged: (uid) =>
            ref.read(adminJobUserFilterProvider.notifier).setFilter(uid),
      ),
    );
  }
}

class _UserNameText extends ConsumerWidget {
  final String uid;
  const _UserNameText({required this.uid});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final name =
        ref.watch(userByUidProvider(uid)).value?.displayedName ??
        uid.substring(0, 8);
    return Text(name);
  }
}

// ── En-tête de section par propriétaire ───────────────────────────────────────

class WorkQueueSectionHeader extends ConsumerWidget {
  final String ownerUid;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;

  /// Case « tout cocher dans cette section », visible pendant une sélection.
  /// `true` : tout est coché, `null` : une partie, `false` : rien.
  final bool? selection;
  final VoidCallback? onToggleSelection;

  const WorkQueueSectionHeader({
    super.key,
    required this.ownerUid,
    required this.count,
    required this.expanded,
    required this.onToggle,
    this.selection = false,
    this.onToggleSelection,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final name = ownerUid == '__me'
        ? 'Mes éléments'
        : ref.watch(userByUidProvider(ownerUid)).value?.displayedName ?? '…';

    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          onToggleSelection == null ? 16 : 4,
          onToggleSelection == null ? 12 : 4,
          16,
          onToggleSelection == null ? 8 : 4,
        ),
        child: Row(
          children: [
            if (onToggleSelection != null)
              Checkbox(
                tristate: true,
                value: selection,
                onChanged: (_) => onToggleSelection!(),
              ),
            Text(
              name,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Chip(
              label: Text('$count'),
              labelStyle: theme.textTheme.labelSmall,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
            const Spacer(),
            Icon(
              expanded ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

// ── Barre d'actions d'une sélection ───────────────────────────────────────────

/// Les actions d'une sélection, en bas de l'écran, avec le nombre d'éléments
/// que chacune touche.
///
/// « Valider » ne concerne que les brouillons, « Relancer » que les traitements
/// en erreur ou rejetés, « Supprimer » tout ce qui est coché. Un compte nul
/// masque l'action, sauf « Valider » : il reste affiché à zéro quand des
/// brouillons sont cochés mais qu'aucun n'est admis, et l'appui dit pourquoi.
/// Une sélection mêlée garde ainsi chaque action disponible, sur la part qui
/// la concerne — les icônes grisées de la barre du haut faisaient croire à une
/// sélection sans issue.
class WorkQueueSelectionBar extends StatelessWidget {
  /// Nul : aucun brouillon coché, l'action est masquée.
  final int? validateCount;

  /// Nul : aucun traitement relançable coché, l'action est masquée.
  final int? retryCount;
  final int deleteCount;
  final VoidCallback onValidate;
  final VoidCallback onRetry;
  final VoidCallback onDelete;

  const WorkQueueSelectionBar({
    super.key,
    required this.validateCount,
    required this.retryCount,
    required this.deleteCount,
    required this.onValidate,
    required this.onRetry,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      elevation: 8,
      color: scheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: OverflowBar(
            alignment: MainAxisAlignment.end,
            spacing: 8,
            overflowSpacing: 8,
            overflowAlignment: OverflowBarAlignment.end,
            children: [
              if (retryCount != null)
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: Text('Relancer ($retryCount)'),
                ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: scheme.error),
                onPressed: onDelete,
                icon: const Icon(Icons.delete_outline),
                label: Text('Supprimer ($deleteCount)'),
              ),
              if (validateCount != null)
                FilledButton.icon(
                  onPressed: onValidate,
                  icon: const Icon(Icons.check_circle_outline),
                  label: Text('Valider ($validateCount)'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// L'avancement d'une action en lot : « Validation 3/12 » et une barre.
class WorkQueueProgressBar extends StatelessWidget {
  final String label;
  final int done;
  final int total;

  const WorkQueueProgressBar({
    super.key,
    required this.label,
    required this.done,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$label $done/$total'),
              const SizedBox(height: 8),
              LinearProgressIndicator(value: total == 0 ? null : done / total),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Tuile traitement ──────────────────────────────────────────────────────────

class QueueJobTile extends StatelessWidget {
  final ProcessingJob job;
  final bool isSelected;
  final bool isSelecting;
  final bool isAdmin;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// `null` pour un compte qui ne peut pas importer : une relance remet le
  /// job en file et relance le pipeline facturé, réservé aux éditeurs.
  final VoidCallback? onRetry;
  final VoidCallback onDelete;
  final VoidCallback? onCancel;

  const QueueJobTile({
    super.key,
    required this.job,
    required this.isSelected,
    required this.isSelecting,
    required this.onTap,
    required this.onLongPress,
    required this.onRetry,
    required this.onDelete,
    this.isAdmin = false,
    this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasError = (job.errorMessage ?? '').isNotEmpty;
    final primaryAction = _primaryActionForStatus(job.status);

    final subtitle = [
      _labelType(job.type),
      if ((job.bookTitre ?? '').isNotEmpty) job.bookTitre!,
    ].join(' • ');

    final enTraitement =
        job.status == ProcessingJobStatus.processing && job.currentStep != null;

    final tuile = ListTile(
      selected: isSelected,
      selectedTileColor: theme.colorScheme.primaryContainer.withValues(
        alpha: 0.3,
      ),
      leading: isSelecting
          ? Checkbox(value: isSelected, onChanged: (_) => onTap())
          : CircleAvatar(
              backgroundColor: theme.colorScheme.secondaryContainer,
              child: Icon(
                _iconForType(job.type),
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
      // Le titre lu par l'IA dès que le serveur l'a posé, le nom de fichier
      // avant. Le fichier reste accessible par « Voir le document ».
      title: Text(job.titre ?? job.fileName, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(subtitle, style: theme.textTheme.bodySmall),
          const SizedBox(height: 4),
          // L'état et l'heure vivent SOUS le titre, pas à côté.
          //
          // Ils occupaient `trailing`, où `ListTile` accorde d'abord toute la
          // largeur demandée avant de laisser le reste au titre. Sur un
          // téléphone étroit — et dès que la police du système est agrandie —
          // il n'en restait qu'un caractère : le titre et le libellé de l'étape
          // se lisaient verticalement, une lettre par ligne.
          //
          // `Wrap` plutôt qu'une `Row` : à très grande échelle, la puce et
          // l'heure passent l'une sous l'autre au lieu de déborder.
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _JobStatusChip(status: job.status),
              Text(
                _formatDate(job.updatedAt),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          if (hasError) _ErrorBadge(errorMessage: job.errorMessage!),
          if (job.errorId != null) _ErrorIdChip(errorId: job.errorId!),
        ],
      ),
      // Le sous-titre porte toujours au moins deux lignes désormais.
      isThreeLine: true,
      trailing: isSelecting
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (primaryAction != null)
                  IconButton(
                    tooltip: primaryAction.label,
                    onPressed: primaryAction.run,
                    icon: Icon(primaryAction.icon),
                  ),
                PopupMenuButton<_JobMenuAction>(
                  tooltip: 'Actions',
                  onSelected: (action) async {
                    if (action == _JobMenuAction.retry) onRetry?.call();
                    if (action == _JobMenuAction.delete) onDelete();
                    if (action == _JobMenuAction.cancel) onCancel?.call();
                    if (action == _JobMenuAction.copyId) {
                      await Clipboard.setData(ClipboardData(text: job.id));
                      if (context.mounted) {
                        context.showSuccessSnackBar('ID copié : ${job.id}');
                      }
                    }
                    if (action == _JobMenuAction.viewSource) {
                      final uri = Uri.parse(job.fileUrl);
                      if (!await launchUrl(
                            uri,
                            mode: LaunchMode.platformDefault,
                          ) &&
                          context.mounted) {
                        context.showSnackBar(
                          'Impossible d\'ouvrir le document.',
                        );
                      }
                    }
                    if (action == _JobMenuAction.downloadSource) {
                      final url = job.fileUrl;
                      if (kIsWeb) {
                        final filename = filenameFromStorageUrl(
                          url,
                          fallback: 'document',
                        );
                        final ok = await triggerWebDownload(url, filename);
                        if (ok) return;
                      }
                      final uri = Uri.parse(url);
                      if (!await launchUrl(
                            uri,
                            mode: LaunchMode.externalApplication,
                          ) &&
                          context.mounted) {
                        context.showSnackBar(
                          'Impossible de télécharger le document.',
                        );
                      }
                    }
                  },
                  itemBuilder: (_) => [
                    if (primaryAction != null)
                      PopupMenuItem(
                        value: primaryAction.menuAction,
                        child: ListTile(
                          leading: Icon(primaryAction.icon),
                          title: Text(primaryAction.label),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    if (job.fileUrl.isNotEmpty) ...[
                      const PopupMenuItem(
                        value: _JobMenuAction.viewSource,
                        child: ListTile(
                          leading: Icon(Icons.document_scanner_outlined),
                          title: Text('Voir le document'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      const PopupMenuItem(
                        value: _JobMenuAction.downloadSource,
                        child: ListTile(
                          leading: Icon(Icons.download_outlined),
                          title: Text('Télécharger'),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ],
                    if (isAdmin)
                      PopupMenuItem(
                        value: _JobMenuAction.copyId,
                        child: ListTile(
                          leading: const Icon(Icons.fingerprint),
                          title: Text(
                            'Copier l\'ID',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.secondary,
                            ),
                          ),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    const PopupMenuItem(
                      value: _JobMenuAction.delete,
                      child: ListTile(
                        leading: Icon(Icons.delete_outline),
                        title: Text('Supprimer'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
              ],
            ),
      onTap: onTap,
      onLongPress: onLongPress,
    );

    // La suite des étapes prend une ligne À ELLE, sous la tuile.
    //
    // Elle vivait dans la colonne du sous-titre, que `ListTile` réduit à ce que
    // les boutons de droite lui laissent : le libellé de l'étape s'y coupait —
    // « Lecture de la page par … ». Ici, elle dispose de toute la largeur de la
    // carte, et le texte peut passer à la ligne.
    final contenu = !enTraitement
        ? tuile
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              tuile,
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: ProcessingTrailRow(
                  type: job.type,
                  currentStep: job.currentStep,
                ),
              ),
            ],
          );

    return _TeinteDeTraitement(status: job.status, child: contenu);
  }

  _PrimaryJobAction? _primaryActionForStatus(ProcessingJobStatus status) {
    switch (status) {
      case ProcessingJobStatus.queued:
      case ProcessingJobStatus.processing:
        if (onCancel == null) return null;
        return _PrimaryJobAction(
          icon: Icons.stop_circle_outlined,
          label: 'Forcer l\'arrêt',
          menuAction: _JobMenuAction.cancel,
          run: onCancel!,
        );
      case ProcessingJobStatus.error:
      case ProcessingJobStatus.rejected:
        if (onRetry == null) return null;
        return _PrimaryJobAction(
          icon: Icons.refresh,
          label: 'Relancer',
          menuAction: _JobMenuAction.retry,
          run: onRetry!,
        );
      case ProcessingJobStatus.done:
        return null;
    }
  }

  IconData _iconForType(ProcessingJobType type) => switch (type) {
    ProcessingJobType.recipeScan => Icons.receipt_long_outlined,
    ProcessingJobType.bookCoverScan => Icons.photo_camera_outlined,
    ProcessingJobType.bookDocumentScan => Icons.auto_stories_outlined,
  };

  String _labelType(ProcessingJobType type) => switch (type) {
    ProcessingJobType.recipeScan => 'Scan recette',
    ProcessingJobType.bookCoverScan => 'Scan couverture',
    ProcessingJobType.bookDocumentScan => 'Scan livre',
  };

  String _formatDate(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return "À l'instant";
    if (diff.inHours < 1) return 'Il y a ${diff.inMinutes} min';
    if (diff.inDays < 1) return 'Il y a ${diff.inHours} h';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}

enum _JobMenuAction {
  retry,
  delete,
  cancel,
  copyId,
  viewSource,
  downloadSource,
}

class _PrimaryJobAction {
  final IconData icon;
  final String label;
  final _JobMenuAction menuAction;
  final VoidCallback run;

  const _PrimaryJobAction({
    required this.icon,
    required this.label,
    required this.menuAction,
    required this.run,
  });
}

// ── Tuile brouillon ───────────────────────────────────────────────────────────

class QueueDraftTile extends StatelessWidget {
  final Recipe recipe;
  final bool isSelected;
  final bool isSelecting;
  final VoidCallback onTap;

  /// `null` pour le brouillon d'un autre membre : il ne se sélectionne pas,
  /// ne se valide pas et ne se supprime pas — seuls son créateur et un
  /// administrateur le peuvent. La ligne ouvre alors la relecture, où
  /// « Copier comme mon brouillon » existe.
  final VoidCallback? onLongPress;
  final VoidCallback? onValidate;
  final VoidCallback? onDelete;

  const QueueDraftTile({
    super.key,
    required this.recipe,
    required this.isSelected,
    required this.isSelecting,
    required this.onTap,
    required this.onLongPress,
    required this.onValidate,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selectable = onLongPress != null;
    final hasSource =
        recipe.sourceFileUrl != null && recipe.sourceFileUrl!.isNotEmpty;
    // Sans action ni document, pas de menu : un menu vide s'ouvrait sur rien.
    final hasMenu = onValidate != null || onDelete != null || hasSource;

    return ListTile(
      // En mode sélection, le brouillon d'un autre est grisé et ne réagit
      // pas : il ne se sélectionne pas, et naviguer ferait perdre la
      // sélection en cours.
      enabled: !(isSelecting && !selectable),
      selected: isSelected,
      selectedTileColor: theme.colorScheme.primaryContainer.withValues(
        alpha: 0.3,
      ),
      leading: isSelecting && selectable
          ? Checkbox(value: isSelected, onChanged: (_) => onTap())
          : CircleAvatar(
              backgroundColor: theme.colorScheme.primaryContainer,
              child: Icon(
                Icons.edit_document,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
      title: Text(recipe.titre, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (recipe.sourceFileName != null)
            Text(
              recipe.sourceFileName!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          if (recipe.bookTitre != null)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.menu_book_outlined,
                  size: AppIconSize.badge,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    recipe.bookTitre!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
        ],
      ),
      trailing: isSelecting
          ? null
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _DraftStatusChip(status: recipe.reviewStatus),
                const SizedBox(width: 4),
                Text(
                  _formatDate(recipe.updatedAt),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (!hasMenu)
                  const SizedBox(width: kMinInteractiveDimension)
                else
                  PopupMenuButton<_DraftMenuAction>(
                    tooltip: 'Actions',
                    onSelected: (action) async {
                      if (action == _DraftMenuAction.validate) {
                        onValidate?.call();
                      }
                      if (action == _DraftMenuAction.delete) {
                        onDelete?.call();
                      }
                      if (action == _DraftMenuAction.viewSource) {
                        final url = recipe.sourceFileUrl;
                        if (url != null && url.isNotEmpty) {
                          await launchUrl(
                            Uri.parse(url),
                            mode: LaunchMode.platformDefault,
                          );
                        }
                      }
                      if (action == _DraftMenuAction.downloadSource) {
                        final url = recipe.sourceFileUrl;
                        if (url != null && url.isNotEmpty) {
                          if (kIsWeb) {
                            final filename = filenameFromStorageUrl(
                              url,
                              fallback: recipe.sourceFileName ?? 'document',
                            );
                            final ok = await triggerWebDownload(url, filename);
                            if (ok) return;
                          }
                          await launchUrl(
                            Uri.parse(url),
                            mode: LaunchMode.externalApplication,
                          );
                        }
                      }
                    },
                    itemBuilder: (_) => [
                      if (onValidate != null)
                        const PopupMenuItem(
                          value: _DraftMenuAction.validate,
                          child: ListTile(
                            leading: Icon(Icons.check_circle_outline),
                            title: Text('Valider'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      if (hasSource) ...[
                        const PopupMenuItem(
                          value: _DraftMenuAction.viewSource,
                          child: ListTile(
                            leading: Icon(Icons.visibility_outlined),
                            title: Text('Voir le document'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                        const PopupMenuItem(
                          value: _DraftMenuAction.downloadSource,
                          child: ListTile(
                            leading: Icon(Icons.download_outlined),
                            title: Text('Télécharger'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ],
                      if (onDelete != null)
                        const PopupMenuItem(
                          value: _DraftMenuAction.delete,
                          child: ListTile(
                            leading: Icon(Icons.delete_outline),
                            title: Text('Supprimer'),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                    ],
                  ),
              ],
            ),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return "\u00c0 l'instant";
    if (diff.inHours < 1) return 'Il y a ${diff.inMinutes} min';
    if (diff.inDays < 1) return 'Il y a ${diff.inHours} h';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}

enum _DraftMenuAction { validate, delete, viewSource, downloadSource }

// ── Chip statut traitement ────────────────────────────────────────────────────

/// Le fond d'une ligne de traitement, pour qu'elle se distingue d'un brouillon.
///
/// Les deux partagent la même liste et la même forme : icône ronde, titre,
/// sous-titre, boutons. Seule la couleur de l'icône les séparait, plus une
/// puce « Traitement » qu'il faut lire. Un traitement en file ou en cours
/// porte donc la teinte secondaire sur toute sa ligne, avec un liseré à
/// gauche ; un traitement en erreur ou rejeté porte la teinte d'erreur ; un
/// brouillon garde le fond de la liste. La même teinte secondaire sert à la
/// puce et à l'icône du traitement : une seule couleur veut dire « en cours ».
class _TeinteDeTraitement extends StatelessWidget {
  const _TeinteDeTraitement({required this.status, required this.child});

  final ProcessingJobStatus status;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (fond, lisere) = switch (status) {
      ProcessingJobStatus.queued || ProcessingJobStatus.processing => (
        scheme.secondaryContainer.withValues(alpha: 0.35),
        scheme.secondary,
      ),
      ProcessingJobStatus.error || ProcessingJobStatus.rejected => (
        scheme.errorContainer.withValues(alpha: 0.35),
        scheme.error,
      ),
      ProcessingJobStatus.done => (Colors.transparent, Colors.transparent),
    };
    // Le fond va sur un `Material`, pas sur la boîte décorée : `ListTile`
    // peint sa couleur de sélection et son encre sur le `Material` le plus
    // proche, et une boîte colorée entre les deux les cacherait — Flutter le
    // refuse à l'exécution. La boîte ne porte que le liseré.
    return Material(
      color: fond,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: lisere, width: 4)),
        ),
        child: child,
      ),
    );
  }
}

class _JobStatusChip extends StatelessWidget {
  final ProcessingJobStatus status;
  const _JobStatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, bg, fg) = switch (status) {
      ProcessingJobStatus.queued => (
        'En file',
        theme.colorScheme.surfaceContainerHighest,
        theme.colorScheme.onSurface,
      ),
      ProcessingJobStatus.processing => (
        'Traitement',
        theme.colorScheme.secondaryContainer,
        theme.colorScheme.onSecondaryContainer,
      ),
      ProcessingJobStatus.done => (
        'Terminé',
        theme.colorScheme.primaryContainer,
        theme.colorScheme.onPrimaryContainer,
      ),
      ProcessingJobStatus.error => (
        'Erreur',
        theme.colorScheme.errorContainer,
        theme.colorScheme.onErrorContainer,
      ),
      ProcessingJobStatus.rejected => (
        'Rejeté',
        theme.colorScheme.error,
        theme.colorScheme.onError,
      ),
    };
    return Chip(
      label: Text(label),
      backgroundColor: bg,
      labelStyle: TextStyle(color: fg, fontSize: 11),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }
}

// ── Chip statut brouillon ─────────────────────────────────────────────────────

class _DraftStatusChip extends StatelessWidget {
  final ReviewStatus status;
  const _DraftStatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (label, bg, fg) = switch (status) {
      ReviewStatus.draft => (
        'Brouillon',
        theme.colorScheme.surfaceContainerHighest,
        theme.colorScheme.onSurface,
      ),
      ReviewStatus.inReview => (
        'En révision',
        theme.colorScheme.secondaryContainer,
        theme.colorScheme.onSecondaryContainer,
      ),
      ReviewStatus.validated => (
        'Validé',
        theme.colorScheme.primaryContainer,
        theme.colorScheme.onPrimaryContainer,
      ),
    };
    return Chip(
      label: Text(label),
      backgroundColor: bg,
      labelStyle: TextStyle(color: fg, fontSize: 11),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }
}

// ── Badge d'erreur avec tooltip + dialogue copie ──────────────────────────────

class _ErrorBadge extends StatelessWidget {
  final String errorMessage;
  const _ErrorBadge({required this.errorMessage});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onLongPress: () => _showErrorDialog(context, errorMessage),
            child: Tooltip(
              message: errorMessage,
              child: Text(
                errorMessage,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ),
        IconButton(
          tooltip: 'Copier le motif de rejet',
          visualDensity: VisualDensity.compact,
          iconSize: AppIconSize.inline,
          onPressed: () => _showErrorDialog(context, errorMessage),
          icon: Icon(Icons.copy_all_outlined, color: theme.colorScheme.error),
        ),
      ],
    );
  }

  void _showErrorDialog(BuildContext context, String message) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Détail de l'erreur"),
        content: SelectableText(message),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: message));
              Navigator.pop(ctx);
              context.showSuccessSnackBar('Copié dans le presse-papier');
            },
            child: const Text('Copier'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Fermer'),
          ),
        ],
      ),
    );
  }
}

// ── Chip code erreur (copiable en 1 tap) ─────────────────────────────────────

class _ErrorIdChip extends StatelessWidget {
  final String errorId;
  const _ErrorIdChip({required this.errorId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: errorId));
        if (context.mounted) {
          context.showSuccessSnackBar('Code erreur copié : $errorId');
        }
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.content_copy_outlined,
            size: AppIconSize.badge,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 3),
          Text(
            'Code : $errorId',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.error,
              decoration: TextDecoration.underline,
            ),
          ),
        ],
      ),
    );
  }
}
