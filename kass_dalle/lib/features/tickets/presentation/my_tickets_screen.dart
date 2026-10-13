import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_icons.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../core/widgets/app_states.dart';
import '../domain/ticket.dart';
import '../domain/ticket_screens.dart';
import 'ticket_widgets.dart';
import 'tickets_providers.dart';

/// « Mes tickets » (`/tickets` et `/tickets/:ticketId`).
///
/// Sur grand écran, la liste et le détail côte à côte ; sur petit écran, l'un
/// ou l'autre selon la route.
class MyTicketsScreen extends ConsumerWidget {
  final String? selectedTicketId;
  const MyTicketsScreen({super.key, this.selectedTicketId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isWide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;
    final selected = selectedTicketId;

    if (!isWide && selected != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Mes tickets')),
        body: _MyTicketDetailPane(ticketId: selected),
      );
    }

    final ticketsAsync = ref.watch(myTicketsProvider);
    final list = ticketsAsync.when(
      skipLoadingOnRefresh: false,
      loading: () => const AppLoadingState(label: 'Chargement de vos tickets…'),
      error: (error, _) => AppErrorState(
        error: error,
        title: 'Impossible de charger vos tickets.',
        onRetry: () => ref.invalidate(myTicketsProvider),
      ),
      data: (tickets) {
        if (tickets.isEmpty) {
          return AppEmptyState(
            icon: AppIcons.tickets,
            title: 'Aucun ticket pour l\'instant',
            message:
                'Un bug, une idée, une question ? Envoyez-les à '
                'l\'administrateur.',
            action: FilledButton.icon(
              onPressed: () => context.push(AppRoutes.ticketNew),
              icon: const Icon(AppIcons.ticketNew),
              label: const Text('Signaler ou proposer'),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.only(bottom: 88),
          itemCount: tickets.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final t = tickets[i];
            return _MyTicketTile(
              ticket: t,
              selected: t.id == selected,
              onTap: () {
                final location = AppRoutes.ticketDetail(t.id);
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

    return Scaffold(
      appBar: AppBar(title: const Text('Mes tickets')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push(AppRoutes.ticketNew),
        icon: const Icon(AppIcons.ticketNew),
        label: const Text('Signaler ou proposer'),
      ),
      body: isWide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 380, child: list),
                const VerticalDivider(width: 1),
                Expanded(
                  child: selected == null
                      ? const AppEmptyState(
                          icon: AppIcons.tickets,
                          title: 'Choisissez un ticket pour voir son suivi.',
                        )
                      : _MyTicketDetailPane(ticketId: selected),
                ),
              ],
            )
          : list,
    );
  }
}

class _MyTicketTile extends StatelessWidget {
  final Ticket ticket;
  final bool selected;
  final VoidCallback onTap;

  const _MyTicketTile({
    required this.ticket,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final created = ticket.createdAt;
    return ListTile(
      selected: selected,
      leading: TicketTypeIcon(type: ticket.type),
      title: Text(ticket.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(created == null ? '…' : formatTicketDate(created)),
      trailing: Badge(
        isLabelVisible: ticket.hasUnseenUpdate,
        child: TicketStatusChip(status: ticket.status),
      ),
      onTap: onTap,
    );
  }
}

/// Le détail d'un ticket du membre. Son ouverture note la lecture du
/// dernier statut (`seen_by_author_at`).
class _MyTicketDetailPane extends ConsumerStatefulWidget {
  final String ticketId;
  const _MyTicketDetailPane({required this.ticketId});

  @override
  ConsumerState<_MyTicketDetailPane> createState() =>
      _MyTicketDetailPaneState();
}

class _MyTicketDetailPaneState extends ConsumerState<_MyTicketDetailPane> {
  /// Le `status_changed_at` déjà noté comme lu, pour ne pas écrire deux fois.
  DateTime? _markedFor;
  bool _marked = false;

  void _markSeenIfNeeded(Ticket ticket) {
    final seen = ticket.seenByAuthorAt;
    final changed = ticket.statusChangedAt;
    final upToDate =
        seen != null && (changed == null || !seen.isBefore(changed));
    if (upToDate) return;
    if (_marked && _markedFor == changed) return;
    _marked = true;
    _markedFor = changed;
    unawaited(ref.read(ticketRepositoryProvider).markSeen(ticket.id));
  }

  @override
  Widget build(BuildContext context) {
    final ticketAsync = ref.watch(myTicketProvider(widget.ticketId));
    return ticketAsync.when(
      skipLoadingOnRefresh: false,
      loading: () => const AppLoadingState(label: 'Chargement de vos tickets…'),
      error: (error, _) => AppErrorState(
        error: error,
        title: 'Impossible de charger vos tickets.',
        onRetry: () => ref.invalidate(myTicketsProvider),
      ),
      data: (ticket) {
        if (ticket == null) {
          return AppEmptyState(
            icon: AppIcons.tickets,
            title: 'Ce ticket n\'existe plus.',
            action: OutlinedButton(
              onPressed: () => context.go(AppRoutes.tickets),
              child: const Text('Retour à mes tickets'),
            ),
          );
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _markSeenIfNeeded(ticket);
        });
        return _MemberTicketDetail(ticket: ticket);
      },
    );
  }
}

class _MemberTicketDetail extends StatelessWidget {
  final Ticket ticket;
  const _MemberTicketDetail({required this.ticket});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final created = ticket.createdAt;
    final sentence = ticket.status.memberSentence;
    final reply = ticket.replyText;
    final screenshot = ticket.screenshotPath;
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
          TicketStatusChip(status: ticket.status),
          const SizedBox(height: 8),
          if (created != null)
            TicketInfoLine('Envoyé le ${formatTicketDateTime(created)}'),
          const SizedBox(height: 8),
          if (sentence != null) Text(sentence),
          if (ticket.isLate(DateTime.now())) ...[
            const SizedBox(height: 4),
            const Text(kTicketLateSentence),
          ],
          if (ticket.status == TicketStatus.answered && reply != null) ...[
            const SizedBox(height: 12),
            TicketReplyBox(title: 'Réponse de l\'administrateur', text: reply),
          ],
          if (ticket.status == TicketStatus.refused && reply != null) ...[
            const SizedBox(height: 12),
            TicketReplyBox(title: 'Motif', text: reply),
          ],
          const SizedBox(height: 16),
          TicketTimeline(status: ticket.status),
          const SizedBox(height: 8),
          Text('Description', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          SelectableText(ticket.description),
          const SizedBox(height: 16),
          TicketInfoLine('Écran : ${ticketScreenLabel(ticket.screen)}'),
          TicketInfoLine(
            'Version ${ticket.appVersion} — '
            '${ticketPlatformLabel(ticket.platform)}',
          ),
          if (screenshot != null) ...[
            const SizedBox(height: 12),
            TicketScreenshotView(path: screenshot),
          ],
        ],
      ),
    );
  }
}
