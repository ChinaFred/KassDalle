import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/utils/context_extensions.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/app_states.dart';
import '../../../core/widgets/error_message.dart';
import '../../auth/presentation/auth_providers.dart';
import '../domain/ticket.dart';
import '../domain/ticket_screens.dart';
import 'ticket_widgets.dart';
import 'tickets_providers.dart';

/// Admin › Tickets des membres (`/admin/tickets` et
/// `/admin/tickets/:ticketId`).
///
/// L'écran montre et relance ; il ne valide rien. La décision se prend sur
/// GitHub, par les étiquettes de l'Issue.
class AdminTicketsScreen extends ConsumerWidget {
  final String? selectedTicketId;
  const AdminTicketsScreen({super.key, this.selectedTicketId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isWide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;
    final selected = selectedTicketId;

    if (!isWide && selected != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Tickets des membres')),
        body: _AdminTicketDetailPane(ticketId: selected),
      );
    }

    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Filters(),
        const Divider(height: 1),
        Expanded(
          child: _AdminTicketList(selectedTicketId: selected, isWide: isWide),
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Tickets des membres')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _TokenBanner(),
          Expanded(
            child: isWide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(width: 460, child: list),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: selected == null
                            ? const AppEmptyState(
                                icon: AppIcons.tickets,
                                title:
                                    'Choisissez un ticket pour voir son '
                                    'suivi.',
                              )
                            : _AdminTicketDetailPane(ticketId: selected),
                      ),
                    ],
                  )
                : list,
          ),
        ],
      ),
    );
  }
}

/// Bandeau « Jeton GitHub invalide », tant que le serveur le signale.
class _TokenBanner extends ConsumerWidget {
  const _TokenBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final since = ref.watch(ticketsTokenInvalidSinceProvider).value;
    if (since == null) return const SizedBox.shrink();
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        color: cs.errorContainer,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.warning_amber_outlined, color: cs.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Jeton GitHub invalide : aucun ticket n\'est transmis à '
                'GitHub depuis le ${formatTicketDateTime(since)}. Remplacez '
                'le jeton dans Secret Manager. Les tickets en attente '
                'repartiront ensuite.',
                style: TextStyle(color: cs.onErrorContainer, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Filters extends ConsumerWidget {
  const _Filters();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(adminTicketStatusFilterProvider);
    final type = ref.watch(adminTicketTypeFilterProvider);
    final statusNotifier = ref.read(adminTicketStatusFilterProvider.notifier);
    final typeNotifier = ref.read(adminTicketTypeFilterProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ChoiceChip(
                label: const Text('Tous'),
                selected: status == null,
                onSelected: (_) => statusNotifier.set(null),
              ),
              ChoiceChip(
                label: const Text('En anomalie'),
                selected: status == kAdminTicketAnomalyFilter,
                onSelected: (_) =>
                    statusNotifier.set(kAdminTicketAnomalyFilter),
              ),
              for (final s in TicketStatus.values)
                ChoiceChip(
                  label: Text(s.label),
                  selected: status == s.value,
                  onSelected: (_) => statusNotifier.set(s.value),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ChoiceChip(
                label: const Text('Tous les types'),
                selected: type == null,
                onSelected: (_) => typeNotifier.set(null),
              ),
              for (final t in TicketType.values)
                ChoiceChip(
                  label: Text(t.label),
                  selected: type == t,
                  onSelected: (_) => typeNotifier.set(t),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AdminTicketList extends ConsumerWidget {
  final String? selectedTicketId;
  final bool isWide;
  const _AdminTicketList({
    required this.selectedTicketId,
    required this.isWide,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ticketsAsync = ref.watch(adminTicketsProvider);
    final status = ref.watch(adminTicketStatusFilterProvider);
    final type = ref.watch(adminTicketTypeFilterProvider);
    return ticketsAsync.when(
      skipLoadingOnRefresh: false,
      loading: () => const AppLoadingState(label: 'Chargement des tickets…'),
      error: (error, _) => AppErrorState(
        error: error,
        title: 'Impossible de charger les tickets.',
        onRetry: () => ref.invalidate(adminTicketsProvider),
      ),
      data: (tickets) {
        if (tickets.isEmpty) {
          return const AppEmptyState(
            icon: AppIcons.tickets,
            title: 'Aucun ticket',
            message: 'Les membres n\'ont encore rien signalé.',
          );
        }
        final shown = filterAdminTickets(tickets, status: status, type: type);
        if (shown.isEmpty) {
          return AppEmptyState(
            icon: Icons.filter_alt_off_outlined,
            title: 'Aucun ticket ne correspond à ce filtre.',
            action: OutlinedButton(
              onPressed: () {
                ref.read(adminTicketStatusFilterProvider.notifier).set(null);
                ref.read(adminTicketTypeFilterProvider.notifier).set(null);
              },
              child: const Text('Afficher tous les tickets'),
            ),
          );
        }
        return ListView.separated(
          itemCount: shown.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final t = shown[i];
            return _AdminTicketTile(
              ticket: t,
              selected: t.id == selectedTicketId,
              onTap: () {
                final location = AppRoutes.adminTicketDetail(t.id);
                if (isWide) {
                  context.go(location);
                } else {
                  context.push(location);
                }
              },
            );
          },
        );
      },
    );
  }
}

class _AdminTicketTile extends ConsumerWidget {
  final Ticket ticket;
  final bool selected;
  final VoidCallback onTap;

  const _AdminTicketTile({
    required this.ticket,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final author = ref.watch(memberNameProvider(ticket.authorUid)) ?? '…';
    final created = ticket.createdAt;
    return ListTile(
      selected: selected,
      leading: TicketTypeIcon(type: ticket.type),
      title: Text(ticket.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '$author · ${created == null ? '…' : formatTicketDate(created)}',
            ),
            TicketStatusChip(status: ticket.status),
            if (ticket.isInAnomaly) const TicketAnomalyChip(),
          ],
        ),
      ),
      onTap: onTap,
    );
  }
}

class _AdminTicketDetailPane extends ConsumerWidget {
  final String ticketId;
  const _AdminTicketDetailPane({required this.ticketId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ref
        .watch(adminTicketProvider(ticketId))
        .when(
          skipLoadingOnRefresh: false,
          loading: () =>
              const AppLoadingState(label: 'Chargement des tickets…'),
          error: (error, _) => AppErrorState(
            error: error,
            title: 'Impossible de charger les tickets.',
            onRetry: () => ref.invalidate(adminTicketsProvider),
          ),
          data: (ticket) {
            if (ticket == null) {
              return AppEmptyState(
                icon: AppIcons.tickets,
                title: 'Ce ticket n\'existe plus.',
                action: OutlinedButton(
                  onPressed: () => context.go(AppRoutes.adminTickets),
                  child: const Text('Retour aux tickets'),
                ),
              );
            }
            return _AdminTicketDetail(ticket: ticket);
          },
        );
  }
}

class _AdminTicketDetail extends ConsumerStatefulWidget {
  final Ticket ticket;
  const _AdminTicketDetail({required this.ticket});

  @override
  ConsumerState<_AdminTicketDetail> createState() => _AdminTicketDetailState();
}

class _AdminTicketDetailState extends ConsumerState<_AdminTicketDetail> {
  bool _retrying = false;

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      final status = await ref
          .read(ticketRepositoryProvider)
          .retrySend(widget.ticket.id);
      if (!mounted) return;
      final label = TicketStatus.fromValue(status)?.label;
      context.showSuccessSnackBar(
        label == null ? 'Envoi relancé.' : 'Envoi relancé : $label.',
      );
    } catch (e) {
      // Déjà remontée par `TicketRepository` (feature `tickets`).
      if (mounted) {
        context.showErrorSnackBar(
          'Envoi non relancé : ${shortErrorMessage(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  Future<void> _openGithub(String url) async {
    try {
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok && mounted) {
        context.showErrorSnackBar('Impossible d\'ouvrir GitHub.');
      }
    } catch (e, st) {
      reportUnexpectedError(
        feature: 'tickets',
        error: e,
        stackTrace: st,
        context: {'step': 'open_github', 'ticket_id': widget.ticket.id},
      );
      if (mounted) {
        context.showErrorSnackBar('Impossible d\'ouvrir GitHub.');
      }
    }
  }

  Future<void> _copyLink(String url) async {
    try {
      await Clipboard.setData(ClipboardData(text: url));
      if (mounted) context.showSuccessSnackBar('Lien copié.');
    } catch (e, st) {
      reportUnexpectedError(
        feature: 'tickets',
        error: e,
        stackTrace: st,
        context: {'step': 'copy_link', 'ticket_id': widget.ticket.id},
      );
      if (mounted) context.showErrorSnackBar('Lien non copié.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final ticket = widget.ticket;
    final theme = Theme.of(context);
    final author = ref.watch(memberNameProvider(ticket.authorUid)) ?? '…';
    final created = ticket.createdAt;
    final url = ticket.githubUrl;
    final screenshot = ticket.screenshotPath;
    final reply = ticket.replyText;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              TicketTypeIcon(type: ticket.type),
              const SizedBox(width: 8),
              Text(ticket.type.label, style: theme.textTheme.labelLarge),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(ticket.title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              TicketStatusChip(status: ticket.status),
              if (ticket.isInAnomaly) const TicketAnomalyChip(),
            ],
          ),
          const SizedBox(height: 12),
          TicketInfoLine('Auteur : $author'),
          if (created != null)
            TicketInfoLine('Envoyé le ${formatTicketDateTime(created)}'),
          TicketInfoLine('Version ${ticket.appVersion}'),
          TicketInfoLine(
            'Plateforme : ${ticketPlatformLabel(ticket.platform)}',
          ),
          TicketInfoLine('Écran : ${ticketScreenLabel(ticket.screen)}'),
          if (ticket.isInAnomaly) ...[
            const SizedBox(height: 8),
            TicketInfoLine('Essais d\'envoi : ${ticket.sendAttempts}'),
            if (ticket.lastSendError != null)
              TicketInfoLine('Dernière erreur : ${ticket.lastSendError}'),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: _retrying ? null : _retry,
              icon: _retrying
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: const Text('Relancer l\'envoi'),
            ),
          ],
          if (url != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () => _openGithub(url),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Ouvrir sur GitHub'),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: () => _copyLink(url),
                  icon: const Icon(Icons.link),
                  tooltip: 'Copier le lien',
                ),
              ],
            ),
          ],
          if (reply != null) ...[
            const SizedBox(height: 12),
            TicketReplyBox(
              title: ticket.status == TicketStatus.refused
                  ? 'Motif'
                  : 'Réponse de l\'administrateur',
              text: reply,
            ),
          ],
          const SizedBox(height: 16),
          Text('Description', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          SelectableText(ticket.description),
          if (screenshot != null) ...[
            const SizedBox(height: 16),
            TicketScreenshotView(path: screenshot, height: 360),
          ],
        ],
      ),
    );
  }
}
