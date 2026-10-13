import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_icon_size.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/widgets/app_states.dart';
import '../domain/ticket.dart';
import 'tickets_providers.dart';

/// Pièces communes aux écrans « Mes tickets » et « Tickets des membres ».

IconData ticketTypeIcon(TicketType type) => switch (type) {
  TicketType.bug => AppIcons.ticketTypeBug,
  TicketType.evolution => AppIcons.ticketTypeEvolution,
  TicketType.feature => AppIcons.ticketTypeFeature,
  TicketType.question => AppIcons.ticketTypeQuestion,
};

IconData ticketStatusIcon(TicketStatus status) => switch (status) {
  TicketStatus.sending => AppIcons.ticketStatusSending,
  TicketStatus.received => AppIcons.ticketStatusReceived,
  TicketStatus.analyzed => AppIcons.ticketStatusAnalyzed,
  TicketStatus.validated => AppIcons.ticketStatusValidated,
  TicketStatus.inProgress => AppIcons.ticketStatusInProgress,
  TicketStatus.delivered => AppIcons.ticketStatusDelivered,
  TicketStatus.refused => AppIcons.ticketStatusRefused,
  TicketStatus.answered => AppIcons.ticketStatusAnswered,
};

/// Fond et texte de la puce d'un statut.
({Color background, Color foreground}) ticketStatusColors(
  TicketStatus status,
  ColorScheme cs,
) => switch (status) {
  TicketStatus.sending || TicketStatus.refused => (
    background: cs.surfaceContainerHighest,
    foreground: cs.onSurface,
  ),
  TicketStatus.received || TicketStatus.analyzed => (
    background: cs.secondaryContainer,
    foreground: cs.onSecondaryContainer,
  ),
  TicketStatus.validated || TicketStatus.delivered => (
    background: cs.primaryContainer,
    foreground: cs.onPrimaryContainer,
  ),
  TicketStatus.inProgress || TicketStatus.answered => (
    background: cs.tertiaryContainer,
    foreground: cs.onTertiaryContainer,
  ),
};

/// Puce d'un statut : icône et texte, jamais la couleur seule.
class TicketStatusChip extends StatelessWidget {
  final TicketStatus status;
  const TicketStatusChip({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final colors = ticketStatusColors(status, Theme.of(context).colorScheme);
    return _Pill(
      icon: ticketStatusIcon(status),
      label: status.label,
      background: colors.background,
      foreground: colors.foreground,
    );
  }
}

/// Puce « En anomalie » des écrans d'administration.
class TicketAnomalyChip extends StatelessWidget {
  const TicketAnomalyChip({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return _Pill(
      icon: AppIcons.ticketAnomaly,
      label: 'En anomalie',
      background: cs.errorContainer,
      foreground: cs.onErrorContainer,
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color background;
  final Color foreground;

  const _Pill({
    required this.icon,
    required this.label,
    required this.background,
    required this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExcludeSemantics(
            child: Icon(icon, size: AppIconSize.inline, color: foreground),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}

/// Icône du type, annoncée par son libellé.
class TicketTypeIcon extends StatelessWidget {
  final TicketType type;
  const TicketTypeIcon({super.key, required this.type});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: type.label,
      child: Icon(ticketTypeIcon(type), semanticLabel: type.label),
    );
  }
}

/// Frise verticale des étapes d'un ticket.
class TicketTimeline extends StatelessWidget {
  final TicketStatus status;
  const TicketTimeline({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final steps = ticketTimeline(status);
    final reached = steps.indexOf(status);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < steps.length; i++)
          Semantics(
            label: i < reached
                ? '${steps[i].label} : étape passée'
                : i == reached
                ? '${steps[i].label} : étape actuelle'
                : '${steps[i].label} : à venir',
            excludeSemantics: true,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 24,
                    child: Column(
                      children: [
                        Icon(
                          i < reached
                              ? Icons.check_circle
                              : i == reached
                              ? ticketStatusIcon(steps[i])
                              : Icons.radio_button_unchecked,
                          size: AppIconSize.small,
                          color: i <= reached ? cs.primary : cs.outline,
                        ),
                        if (i < steps.length - 1)
                          Expanded(
                            child: Container(
                              width: 2,
                              color: i < reached
                                  ? cs.primary
                                  : cs.outlineVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      steps[i].label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: i == reached ? FontWeight.w600 : null,
                        color: i <= reached ? null : cs.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Encadré d'un texte de l'administrateur : réponse ou motif de refus.
class TicketReplyBox extends StatelessWidget {
  final String title;
  final String text;
  const TicketReplyBox({super.key, required this.title, required this.text});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.tertiaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: cs.onTertiaryContainer,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(
            text,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: cs.onTertiaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}

/// Vignette de la capture d'un ticket, agrandie en plein écran à l'appui.
class TicketScreenshotView extends ConsumerWidget {
  final String path;
  final double height;
  const TicketScreenshotView({
    super.key,
    required this.path,
    this.height = 220,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bytes = ref.watch(ticketScreenshotProvider(path));
    return bytes.when(
      skipLoadingOnRefresh: false,
      loading: () => SizedBox(
        height: height,
        child: const AppLoadingState(label: 'Chargement de la capture…'),
      ),
      error: (error, _) => AppErrorState(
        error: error,
        compact: true,
        title: 'Capture illisible.',
        onRetry: () => ref.invalidate(ticketScreenshotProvider(path)),
      ),
      data: (data) => Align(
        alignment: Alignment.centerLeft,
        child: Semantics(
          button: true,
          label: 'Agrandir la capture',
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () => showDialog<void>(
              context: context,
              builder: (ctx) => Dialog.fullscreen(
                child: Scaffold(
                  appBar: AppBar(
                    title: const Text('Capture'),
                    leading: IconButton(
                      icon: const Icon(Icons.close),
                      tooltip: 'Fermer',
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ),
                  body: InteractiveViewer(
                    maxScale: 5,
                    child: Center(child: Image.memory(data)),
                  ),
                ),
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Image.memory(
                data,
                height: height,
                fit: BoxFit.contain,
                errorBuilder: (_, error, _) => AppErrorState(
                  error: error,
                  compact: true,
                  title: 'Capture illisible.',
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Une ligne « libellé : valeur » du détail.
class TicketInfoLine extends StatelessWidget {
  final String text;
  const TicketInfoLine(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
