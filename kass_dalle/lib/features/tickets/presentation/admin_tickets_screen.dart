import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:markdown/markdown.dart' as md;
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
import '../domain/ticket_analysis.dart';
import '../domain/ticket_screens.dart';
import 'ticket_widgets.dart';
import 'tickets_providers.dart';

/// Admin › Tickets des membres (`/admin/tickets` et
/// `/admin/tickets/:ticketId`).
///
/// L'écran montre les tickets et leurs analyses, relance un envoi, et porte
/// les deux décisions de l'administrateur : « Valider » (étiquette `validé`
/// sur l'Issue) et « Refuser » (motif publié sur GitHub, Issue fermée). Les
/// deux passent par les callables `validateTicket` et `refuseTicket`.
///
/// Le filtre « À traiter » est posé par les points d'entrée
/// ([AdminTicketStatusFilterNotifier.enterToProcess]) ; l'écran ne le remet
/// jamais à zéro, il bascule seulement sur « Tous » une fois, à l'entrée,
/// s'il n'y a rien à traiter.
class AdminTicketsScreen extends ConsumerStatefulWidget {
  final String? selectedTicketId;
  const AdminTicketsScreen({super.key, this.selectedTicketId});

  @override
  ConsumerState<AdminTicketsScreen> createState() => _AdminTicketsScreenState();
}

class _AdminTicketsScreenState extends ConsumerState<AdminTicketsScreen> {
  @override
  void initState() {
    super.initState();
    // Le compteur peut être déjà connu (la pastille du compte le lit) :
    // lu tout de suite, appliqué après la construction.
    ref.listenManual<AsyncValue<int>>(adminTicketsToProcessCountProvider, (
      _,
      next,
    ) {
      final count = next.value;
      if (count == null) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(adminTicketStatusFilterProvider.notifier).settleEntry(count);
      });
    }, fireImmediately: true);
  }

  @override
  Widget build(BuildContext context) {
    final isWide =
        MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint;
    final selected = widget.selectedTicketId;

    if (!isWide && selected != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Tickets des membres')),
        body: _AdminTicketDetailPane(ticketId: selected),
      );
    }

    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Sous le seuil large, chaque rangée de filtres défile de côté : la
        // liste reste visible à 200 % et en paysage.
        _Filters(scrollable: !isWide),
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
  /// Vrai : une ligne par rangée, qui défile horizontalement. Faux : les
  /// puces passent à la ligne.
  final bool scrollable;
  const _Filters({required this.scrollable});

  Widget _row(List<Widget> chips) {
    if (!scrollable) {
      return Wrap(spacing: 6, runSpacing: 6, children: chips);
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final (i, chip) in chips.indexed) ...[
            if (i > 0) const SizedBox(width: 6),
            chip,
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(adminTicketStatusFilterProvider);
    final type = ref.watch(adminTicketTypeFilterProvider);
    final toProcess = ref.watch(adminTicketsToProcessCountProvider).value;
    final statusNotifier = ref.read(adminTicketStatusFilterProvider.notifier);
    final typeNotifier = ref.read(adminTicketTypeFilterProvider.notifier);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row([
            ChoiceChip(
              label: Text(
                toProcess == null ? 'À traiter' : 'À traiter ($toProcess)',
              ),
              selected: status == kAdminTicketTodoFilter,
              onSelected: (_) => statusNotifier.set(kAdminTicketTodoFilter),
            ),
            ChoiceChip(
              label: const Text('Tous'),
              selected: status == null,
              onSelected: (_) => statusNotifier.set(null),
            ),
            ChoiceChip(
              label: const Text('En anomalie'),
              selected: status == kAdminTicketAnomalyFilter,
              onSelected: (_) => statusNotifier.set(kAdminTicketAnomalyFilter),
            ),
            for (final s in TicketStatus.values)
              ChoiceChip(
                label: Text(s.label),
                selected: status == s.value,
                onSelected: (_) => statusNotifier.set(s.value),
              ),
          ]),
          const SizedBox(height: 8),
          _row([
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
          ]),
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
          final todo = status == kAdminTicketTodoFilter && type == null;
          return AppEmptyState(
            icon: todo
                ? AppIcons.ticketsToProcess
                : Icons.filter_alt_off_outlined,
            title: todo
                ? 'Rien à traiter.'
                : 'Aucun ticket ne correspond à ce filtre.',
            message: todo ? 'Tous les tickets ont reçu une décision.' : null,
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
  bool _validating = false;

  /// Motif du refus : gardé si l'administrateur ferme puis rouvre la boîte.
  final _reasonController = TextEditingController();

  /// Le motif a été publié sans que l'Issue soit fermée : il ne change plus.
  bool _reasonLocked = false;

  @override
  void didUpdateWidget(covariant _AdminTicketDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ticket.id != widget.ticket.id) {
      _reasonController.clear();
      _reasonLocked = false;
    }
  }

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _retry() async {
    setState(() => _retrying = true);
    try {
      final status = await ref
          .read(ticketRepositoryProvider)
          .retrySend(widget.ticket.id);
      if (!mounted) return;
      final next = TicketStatus.fromValue(status);
      if (next == TicketStatus.sending) {
        // Le serveur n'a toujours pas pu créer l'Issue : `last_send_error`
        // du ticket, affichée ci-dessous, dit pourquoi.
        context.showErrorSnackBar(
          'L\'envoi a encore échoué. Voir la dernière erreur ci-dessous.',
        );
      } else {
        context.showSuccessSnackBar(
          next == null ? 'Envoi relancé.' : 'Envoi relancé : ${next.label}.',
        );
      }
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

  Future<void> _validate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Valider ce ticket ?'),
        content: const Text('Il sera traité à votre prochaine demande.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Valider'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _validating = true);
    try {
      await ref.read(ticketRepositoryProvider).validate(widget.ticket.id);
      if (mounted) context.showSuccessSnackBar('Ticket validé.');
    } on TicketDecisionError catch (e) {
      // Déjà remontée par `TicketRepository` (feature `tickets`).
      if (mounted) context.showErrorSnackBar(e.message);
    } catch (e) {
      // Déjà remontée par `TicketRepository` (feature `tickets`).
      if (mounted) {
        context.showErrorSnackBar(
          'Ticket non validé : ${shortErrorMessage(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => _validating = false);
    }
  }

  Future<void> _refuse() async {
    final ticket = widget.ticket;
    final refused = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _RefuseTicketDialog(
        controller: _reasonController,
        inProgress: ticket.status == TicketStatus.inProgress,
        locked: _reasonLocked,
        onLocked: () {
          if (mounted) setState(() => _reasonLocked = true);
        },
        submit: (reason) =>
            ref.read(ticketRepositoryProvider).refuse(ticket.id, reason),
      ),
    );
    if (refused != true || !mounted) return;
    _reasonController.clear();
    setState(() => _reasonLocked = false);
    context.showSuccessSnackBar(
      'Ticket refusé. Le motif est publié sur GitHub.',
    );
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
    final decisions = adminTicketDecisions(ticket);
    final hint = decisions.validateHint;

    final details = SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Le libellé suit : l'icône n'est pas annoncée une seconde fois.
              ExcludeSemantics(child: TicketTypeIcon(type: ticket.type)),
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
          if (url != null) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _openGithub(url),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Ouvrir sur GitHub'),
                ),
                IconButton(
                  onPressed: () => _copyLink(url),
                  icon: const Icon(Icons.link),
                  tooltip: 'Copier le lien',
                ),
              ],
            ),
          ],
          if (ticket.isInAnomaly) ...[
            const SizedBox(height: 12),
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
          if (reply != null) ...[
            const SizedBox(height: 12),
            TicketReplyBox(
              title: ticket.status == TicketStatus.refused
                  ? 'Motif du refus'
                  : 'Réponse de l\'administrateur',
              text: reply,
            ),
          ],
          const SizedBox(height: 12),
          if (hint != null) TicketInfoLine(hint),
          TicketInfoLine('Auteur : $author'),
          if (created != null)
            TicketInfoLine('Envoyé le ${formatTicketDateTime(created)}'),
          TicketInfoLine('Version ${ticket.appVersion}'),
          TicketInfoLine(
            'Plateforme : ${ticketPlatformLabel(ticket.platform)}',
          ),
          TicketInfoLine('Écran : ${ticketScreenLabel(ticket.screen)}'),
          const SizedBox(height: 16),
          Text('Description', style: theme.textTheme.titleSmall),
          const SizedBox(height: 4),
          SelectableText(ticket.description),
          if (screenshot != null) ...[
            const SizedBox(height: 16),
            TicketScreenshotView(path: screenshot, height: 360),
          ],
          const SizedBox(height: 24),
          _AnalysesSection(ticket: ticket, onOpenGithub: _openGithub),
        ],
      ),
    );

    if (!decisions.hasAction) return details;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: details),
        const Divider(height: 1),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                if (decisions.canRefuse)
                  OutlinedButton.icon(
                    onPressed: _validating ? null : _refuse,
                    icon: const Icon(AppIcons.ticketStatusRefused),
                    label: const Text('Refuser'),
                  ),
                if (decisions.canValidate)
                  FilledButton.icon(
                    onPressed: _validating ? null : _validate,
                    icon: _validating
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(AppIcons.ticketStatusValidated),
                    label: const Text('Valider'),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Boîte « Refuser ce ticket » : le motif part sur GitHub, dépôt public.
///
/// Reste ouverte sur un échec, avec le message du serveur. Sur un échec
/// partiel (motif publié, Issue non fermée), le champ passe en lecture seule :
/// réessayer republie le même motif, que le serveur reconnaît et ne double pas.
class _RefuseTicketDialog extends StatefulWidget {
  final TextEditingController controller;
  final bool inProgress;
  final bool locked;
  final VoidCallback onLocked;
  final Future<String> Function(String reason) submit;

  const _RefuseTicketDialog({
    required this.controller,
    required this.inProgress,
    required this.locked,
    required this.onLocked,
    required this.submit,
  });

  @override
  State<_RefuseTicketDialog> createState() => _RefuseTicketDialogState();
}

class _RefuseTicketDialogState extends State<_RefuseTicketDialog> {
  bool _sending = false;
  String? _fieldError;
  String? _error;
  late bool _locked = widget.locked;

  Future<void> _submit() async {
    final reason = widget.controller.text.trim();
    if (reason.length < 5) {
      setState(
        () => _fieldError = 'Le motif doit faire au moins 5 caractères.',
      );
      return;
    }
    setState(() {
      _fieldError = null;
      _error = null;
      _sending = true;
    });
    try {
      await widget.submit(reason);
      if (mounted) Navigator.of(context).pop(true);
    } on TicketDecisionError catch (e) {
      // Déjà remontée par `TicketRepository` (feature `tickets`).
      if (!mounted) return;
      setState(() {
        _error = e.message;
        if (e.partial) _locked = true;
      });
      if (e.partial) widget.onLocked();
    } catch (e) {
      // Déjà remontée par `TicketRepository` (feature `tickets`).
      if (mounted) {
        setState(() => _error = 'Ticket non refusé : ${shortErrorMessage(e)}');
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final error = _error;
    return PopScope(
      canPop: !_sending,
      child: AlertDialog(
        scrollable: true,
        title: const Text('Refuser ce ticket'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.public, color: cs.onSurfaceVariant),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Le motif sera publié sur GitHub, dépôt public, et '
                          'lu par le membre. N\'y mettez ni nom ni donnée '
                          'privée.',
                          style: textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        if (widget.inProgress) ...[
                          const SizedBox(height: 8),
                          Text(
                            'Une pull request est ouverte. Elle ne sera pas '
                            'fermée.',
                            style: textTheme.bodyMedium?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: widget.controller,
              enabled: !_sending,
              readOnly: _locked,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              maxLength: 2000,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: 'Motif du refus',
                errorText: _fieldError,
              ),
            ),
            if (_locked && error == null) ...[
              const SizedBox(height: 8),
              Text(
                'Ce motif est déjà publié sur GitHub. Refuser ferme l\'Issue.',
                style: textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(error, style: TextStyle(color: cs.error)),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: _sending ? null : () => Navigator.of(context).pop(false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: _sending ? null : _submit,
            child: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Refuser'),
          ),
        ],
      ),
    );
  }
}

/// Section « Analyses (N) » de la fiche : les analyses du mainteneur
/// relevées sur l'Issue, en Markdown, dans l'ordre chronologique.
class _AnalysesSection extends ConsumerWidget {
  final Ticket ticket;
  final Future<void> Function(String url) onOpenGithub;

  const _AnalysesSection({required this.ticket, required this.onOpenGithub});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final url = ticket.githubUrl;
    return ref
        .watch(ticketAnalysisProvider(ticket.id))
        .when(
          skipLoadingOnRefresh: false,
          loading: () => const SizedBox(
            height: 120,
            child: AppLoadingState(label: 'Chargement des analyses…'),
          ),
          error: (error, _) => AppErrorState(
            error: error,
            compact: true,
            title: 'Impossible de charger les analyses.',
            onRetry: () => ref.invalidate(ticketAnalysisProvider(ticket.id)),
          ),
          data: (doc) {
            final view = ticketAnalysisView(status: ticket.status, doc: doc);
            final analyses = doc?.analyses ?? const <TicketAnalysis>[];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Analyses (${analyses.length})',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                switch (view) {
                  TicketAnalysisView.notAnalyzed => const TicketInfoLine(
                    'Pas encore analysé.',
                  ),
                  TicketAnalysisView.notYetCollected => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const TicketInfoLine('Analyse pas encore relevée.'),
                      if (url != null) ...[
                        const SizedBox(height: 4),
                        OutlinedButton(
                          onPressed: () => onOpenGithub(url),
                          child: const Text('Ouvrir sur GitHub'),
                        ),
                      ],
                    ],
                  ),
                  TicketAnalysisView.list => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (i, a) in analyses.indexed) ...[
                        if (i > 0) const SizedBox(height: 12),
                        _AnalysisCard(
                          analysis: a,
                          ticketId: ticket.id,
                          githubUrl: url,
                          onOpenGithub: onOpenGithub,
                        ),
                      ],
                    ],
                  ),
                },
              ],
            );
          },
        );
  }
}

class _AnalysisCard extends StatelessWidget {
  final TicketAnalysis analysis;
  final String ticketId;
  final String? githubUrl;
  final Future<void> Function(String url) onOpenGithub;

  const _AnalysisCard({
    required this.analysis,
    required this.ticketId,
    required this.githubUrl,
    required this.onOpenGithub,
  });

  Future<void> _openLink(BuildContext context, String? href) async {
    final uri = openableAnalysisLink(href);
    if (uri == null) return;
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok && context.mounted) {
        context.showErrorSnackBar('Impossible d\'ouvrir le lien.');
      }
    } catch (e, st) {
      reportUnexpectedError(
        feature: 'tickets',
        error: e,
        stackTrace: st,
        context: {'step': 'open_analysis_link', 'ticket_id': ticketId},
      );
      if (context.mounted) {
        context.showErrorSnackBar('Impossible d\'ouvrir le lien.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final created = analysis.createdAt;
    final url = githubUrl;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            created == null
                ? 'Analyse'
                : 'Analyse du ${formatTicketDateTime(created)}',
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: 8),
          MarkdownBody(
            data: ticketAnalysisDisplayBody(analysis.body),
            selectable: true,
            extensionSet: md.ExtensionSet.gitHubFlavored,
            styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
              h1: theme.textTheme.titleLarge,
              h2: theme.textTheme.titleMedium,
              h3: theme.textTheme.titleSmall,
              p: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
              listBullet: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
              blockquote: theme.textTheme.bodyMedium?.copyWith(
                fontStyle: FontStyle.italic,
                color: cs.onSurfaceVariant,
              ),
            ),
            onTapLink: (_, href, _) => _openLink(context, href),
            // Aucune image n'est chargée : une adresse tierce verrait passer
            // l'administrateur, et le texte suffit à l'analyse.
            imageBuilder: (_, _, alt) => Text(
              ticketAnalysisImagePlaceholder(alt),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontStyle: FontStyle.italic,
                color: cs.onSurfaceVariant,
              ),
            ),
          ),
          if (analysis.truncated) ...[
            const SizedBox(height: 8),
            const TicketInfoLine('Analyse tronquée, voir GitHub.'),
            if (url != null)
              TextButton(
                onPressed: () => onOpenGithub(url),
                child: const Text('Ouvrir sur GitHub'),
              ),
          ],
        ],
      ),
    );
  }
}
