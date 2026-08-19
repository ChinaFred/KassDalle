import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/services/error_report_service.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/widgets/app_states.dart';
import '../domain/moderation_entry.dart';
import '../domain/moderation_labels.dart';
import 'moderation_providers.dart';

/// Administration › Modération.
///
/// Montre **tout** le journal, pas seulement les rejets : ce que la modération
/// laisse passer est au moins aussi important que ce qu'elle bloque. Sous
/// chaque identification, la phrase qui explique la décision.
class AdminModerationScreen extends ConsumerWidget {
  const AdminModerationScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final journal = ref.watch(moderationJournalProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Modération des images'),
        actions: [
          IconButton(
            tooltip: 'Relancer les images sans verdict',
            icon: const Icon(Icons.refresh),
            onPressed: () => _retry(context, ref),
          ),
        ],
      ),
      body: Column(
        children: [
          const _Filters(),
          const Divider(height: 1),
          Expanded(
            child: journal.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => AppErrorState(
                error: e,
                title: 'Journal de modération illisible.',
                onRetry: () => ref.invalidate(moderationJournalProvider),
              ),
              data: (entries) {
                if (entries.isEmpty) {
                  return const _EmptyJournal();
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: entries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (_, i) => _EntryCard(entry: entries[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _retry(BuildContext context, WidgetRef ref) async {
    try {
      final result = await ref
          .read(moderationRepositoryProvider)
          .retryPending();
      if (!context.mounted) return;
      context.showSnackBar(
        result.relaunched == 0 && result.stillDown == 0
            ? 'Aucune image en attente de verdict.'
            : '${result.relaunched} image(s) traitée(s), '
                  '${result.stillDown} toujours sans verdict.',
      );
    } catch (e) {
      if (!context.mounted) return;
      context.showSnackBar('Relance impossible : $e');
    }
  }
}

class _EmptyJournal extends StatelessWidget {
  const _EmptyJournal();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          'Aucune image sur cette période.\n\n'
          'Un journal vide n\'est pas la preuve que la modération fonctionne : '
          'élargissez la période avant d\'en conclure quoi que ce soit.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}

class _Filters extends ConsumerWidget {
  const _Filters();

  static const _statusLabels = <String?, String>{
    null: 'Tous',
    'manual_review': 'À revoir',
    'pending': 'Sans verdict',
    'rejected': 'Refusées',
    'approved': 'Publiées',
  };

  static const _dayOptions = <int?, String>{
    7: '7 jours',
    30: '30 jours',
    365: '1 an',
    null: 'Tout',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(moderationStatusFilterProvider);
    final days = ref.watch(moderationDaysFilterProvider);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final entry in _statusLabels.entries)
            ChoiceChip(
              label: Text(entry.value),
              selected: status == entry.key,
              onSelected: (_) => ref
                  .read(moderationStatusFilterProvider.notifier)
                  .set(entry.key),
            ),
          const SizedBox(width: 16),
          for (final entry in _dayOptions.entries)
            ChoiceChip(
              label: Text(entry.value),
              selected: days == entry.key,
              onSelected: (_) => ref
                  .read(moderationDaysFilterProvider.notifier)
                  .set(entry.key),
            ),
        ],
      ),
    );
  }
}

class _EntryCard extends ConsumerWidget {
  final ModerationEntry entry;
  const _EntryCard({required this.entry});

  static final _dateFormat = DateFormat('dd/MM/yyyy HH:mm');

  Color _statusColor(ColorScheme scheme) {
    switch (entry.status) {
      case 'approved':
        return scheme.primary;
      case 'rejected':
        return scheme.error;
      case 'manual_review':
        return scheme.tertiary;
      default:
        return scheme.outline;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final url = entry.publishedUrl;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Rien à montrer d'office ici : une image refusée ou en attente
                // n'a pas d'URL publiée. Elle reste consultable plus bas, sur
                // demande — parcourir un journal ne doit pas exposer sans
                // prévenir ce qui a été jugé impubliable.
                SizedBox(
                  width: 88,
                  height: 88,
                  child: url == null
                      ? ColoredBox(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: Icon(
                            entry.status == 'rejected'
                                ? Icons.block
                                : Icons.hourglass_empty_outlined,
                            color: theme.colorScheme.outline,
                          ),
                        )
                      : ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: CachedNetworkImage(
                            imageUrl: url,
                            fit: BoxFit.cover,
                          ),
                        ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Chip(
                            label: Text(
                              moderationLabel(
                                kModerationStatuses,
                                entry.status,
                              ),
                            ),
                            backgroundColor: _statusColor(
                              theme.colorScheme,
                            ).withValues(alpha: 0.15),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              moderationLabel(
                                kModerationTargets,
                                entry.targetKind,
                              ),
                              style: theme.textTheme.titleSmall,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // La phrase de motif : c'est elle qu'on vient lire.
                      Text(
                        moderationLabel(
                          kModerationReasons,
                          entry.decisionReason,
                        ),
                        style: theme.textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        [
                          if (entry.createdAt != null)
                            _dateFormat.format(entry.createdAt!),
                          'envoyée par ${entry.uid}',
                          if (entry.engine.isNotEmpty && entry.engine != 'none')
                            'moteur ${entry.engine}',
                        ].join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (entry.previewPath != null) ...[
              const SizedBox(height: 10),
              _SourcePreview(
                path: entry.previewPath!,
                awaitsDecision: entry.awaitsDecision,
              ),
            ] else if (entry.publishedUrl == null) ...[
              const SizedBox(height: 8),
              Text(
                'Image non conservée : ce refus est antérieur à la '
                'conservation des refus. Rien ne permet de le réévaluer.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
            if (entry.criteria.isNotEmpty) ...[
              const SizedBox(height: 10),
              _CriteriaTable(entry: entry),
            ],
            if (entry.labels.isNotEmpty) ...[
              const SizedBox(height: 10),
              _Labels(entry: entry),
            ],
            if (entry.reviewNote != null && entry.reviewNote!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Motif saisi : ${entry.reviewNote}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (entry.correlationId != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: SelectableText(
                  'Trace : ${entry.correlationId}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),
            if (entry.awaitsDecision) ...[
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.block),
                    label: const Text('Refuser'),
                    onPressed: () => _reject(context, ref),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.check),
                    label: const Text('Publier'),
                    onPressed: () => _approve(context, ref),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _approve(BuildContext context, WidgetRef ref) async {
    try {
      await ref
          .read(moderationRepositoryProvider)
          .review(moderationId: entry.id, approve: true);
      if (!context.mounted) return;
      context.showSnackBar('Image publiée.');
    } catch (e) {
      if (!context.mounted) return;
      context.showSnackBar('Publication impossible : $e');
    }
  }

  Future<void> _reject(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Refuser cette image'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Le motif n\'est pas une formalité : c\'est ce que lira la '
              'personne qui a envoyé l\'image.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Motif du refus'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Refuser'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (note == null || note.isEmpty) return;

    try {
      await ref
          .read(moderationRepositoryProvider)
          .review(moderationId: entry.id, approve: false, note: note);
      if (!context.mounted) return;
      context.showSnackBar('Image refusée.');
    } catch (e) {
      if (!context.mounted) return;
      context.showSnackBar('Refus impossible : $e');
    }
  }
}

/// L'image à juger, consultable à la demande.
///
/// Deux sources selon l'état : une image refusée vit sous `rejected/`, une
/// image en attente de décision est encore en quarantaine. Les deux dossiers
/// sont lisibles par un administrateur, et par lui seul pour le premier.
///
/// Sans cet aperçu, on ne peut ni juger un refus — et ce sont les FAUX refus,
/// une photo de rôti prise pour une scène violente, qu'on a le plus besoin de
/// voir — ni trancher une mise en revue, qui se déciderait sur des scores.
///
/// Elle n'est pas affichée d'office, et c'est délibéré : parcourir un journal
/// ne doit pas exposer sans prévenir ce qui a été jugé impubliable. On la
/// demande, on la voit.
///
/// Les octets sont lus directement, sans passer par une URL de téléchargement :
/// en émettre une créerait un lien partageable qui survivrait au retrait du
/// rôle administrateur.
class _SourcePreview extends StatefulWidget {
  final String path;

  /// Une image qui attend une décision se montre sans détour ; un refus déjà
  /// prononcé reste replié, parce qu'on le parcourt sans l'avoir demandé.
  final bool awaitsDecision;

  const _SourcePreview({required this.path, required this.awaitsDecision});

  @override
  State<_SourcePreview> createState() => _SourcePreviewState();
}

class _SourcePreviewState extends State<_SourcePreview> {
  static const _maxBytes = 20 * 1024 * 1024;

  Uint8List? _bytes;
  bool _loading = false;
  String? _error;
  final _errorReportService = ErrorReportService();

  @override
  void initState() {
    super.initState();
    // Une image qui attend une décision se charge d'office : on ne peut pas
    // demander à quelqu'un de trancher sur une photo qu'il n'a pas vue, et
    // ajouter un clic obligatoire avant chaque verdict ne protège de rien —
    // celui qui ouvre cette file vient précisément pour regarder.
    if (widget.awaitsDecision) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await FirebaseStorage.instance
          .ref(widget.path)
          .getData(_maxBytes);
      if (!mounted) return;
      setState(() {
        _bytes = data;
        _loading = false;
      });
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'moderation.loadSourceImage',
        error: e,
        stackTrace: st,
        context: {'path': widget.path},
      );
      if (!mounted) return;
      setState(() {
        // Un refus de lecture et un fichier absent ne se corrigent pas de la
        // même façon : le message porte la cause, pas un « échec » générique.
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_bytes != null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.memory(
              _bytes!,
              height: 220,
              fit: BoxFit.contain,
              alignment: Alignment.centerLeft,
            ),
          ),
          TextButton.icon(
            icon: const Icon(Icons.visibility_off_outlined),
            label: const Text('Masquer'),
            onPressed: () => setState(() => _bytes = null),
          ),
        ],
      );
    }

    if (_error != null) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              'Image illisible : $_error',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
          TextButton(onPressed: _load, child: const Text('Réessayer')),
        ],
      );
    }

    return TextButton.icon(
      icon: _loading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.visibility_outlined),
      label: Text(
        _loading
            ? 'Chargement…'
            : widget.awaitsDecision
            ? 'Voir l\'image (pour décider)'
            : 'Voir l\'image refusée (pour l\'évaluer)',
      ),
      onPressed: _loading ? null : _load,
    );
  }
}

/// Les critères du moteur, en français, avec leur palier.
class _CriteriaTable extends StatelessWidget {
  final ModerationEntry entry;
  const _CriteriaTable({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final c in entry.criteria)
          Chip(
            visualDensity: VisualDensity.compact,
            label: Text(
              '${moderationLabel(kModerationCriteria, c.key)} : '
              '${moderationLabel(kModerationLikelihoods, c.likelihood)}',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

/// Les labels vus par le moteur, contexte culinaire mis en évidence.
class _Labels extends StatelessWidget {
  final ModerationEntry entry;
  const _Labels({required this.entry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final culinary = entry.culinaryMatches.map((e) => e.toLowerCase()).toSet();
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final label in entry.labels.take(12))
          Chip(
            visualDensity: VisualDensity.compact,
            backgroundColor: culinary.contains(label.name.toLowerCase())
                ? theme.colorScheme.primaryContainer
                : null,
            label: Text(
              '${label.name} ${(label.score * 100).round()} %',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}
