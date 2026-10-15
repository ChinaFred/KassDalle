import 'dart:async';

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
import '../domain/ticket_answer.dart';
import '../domain/ticket_delivery.dart';
import '../domain/ticket_launch.dart';
import '../domain/ticket_screens.dart';
import 'ticket_widgets.dart';
import 'tickets_providers.dart';

/// Admin › Tickets des membres (`/admin/tickets` et
/// `/admin/tickets/:ticketId`).
///
/// L'écran montre les tickets et leurs analyses, relance un envoi, et porte
/// les décisions de l'administrateur : « Valider » (étiquette `validé` sur
/// l'Issue), « Refuser » (motif publié sur GitHub, Issue fermée), « Répondre »
/// (précisions publiées sous la dernière analyse, ticket ramené à Reçu),
/// « Lancer l'analyse », « Lancer le développement » et « Livrer » (session
/// Claude Code lancée par une Routine ; la livraison fusionne la PR prête
/// d'un ticket En cours). Elles passent par les callables `validateTicket`,
/// `refuseTicket`, `answerTicketAnalysis`, `launchTicketAnalysis`,
/// `launchTicketDevelopment` et `launchTicketDelivery`.
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
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _ConfigAlerts(),
            Expanded(child: _AdminTicketDetailPane(ticketId: selected)),
          ],
        ),
      );
    }

    final list = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _LaunchCounter(),
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
          const _ConfigAlerts(),
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

/// Les bandeaux d'alerte de configuration, tant que le serveur les signale
/// (`app_config/tickets_status`) : jeton GitHub, jeton de la routine
/// d'analyse, jeton de la routine de développement. Posés sur la liste et
/// sur la fiche au téléphone.
class _ConfigAlerts extends ConsumerWidget {
  const _ConfigAlerts();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(ticketsStatusProvider).value;
    if (status == null) return const SizedBox.shrink();
    final messages = [
      if (status.githubTokenInvalidSince case final since?)
        'Jeton GitHub invalide : aucun ticket n\'est transmis à GitHub '
            'depuis le ${formatTicketDateTime(since)}. Remplacez le jeton '
            'dans Secret Manager. Les tickets en attente repartiront ensuite.',
      if (status.analysisRoutineInvalidSince case final since?)
        'Jeton de la routine d\'analyse refusé depuis le '
            '${formatTicketDateTime(since)}. Remplacez-le dans Secret '
            'Manager.',
      if (status.developmentRoutineInvalidSince case final since?)
        'Jeton de la routine de développement refusé depuis le '
            '${formatTicketDateTime(since)}. Remplacez-le dans Secret '
            'Manager.',
    ];
    if (messages.isEmpty) return const SizedBox.shrink();
    // Au plus un tiers de l'écran : à 200 % sur un téléphone, trois bandeaux
    // masqueraient la liste ou la fiche ; ils défilent alors entre eux.
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height / 3,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (i, message) in messages.indexed) ...[
              if (i > 0) const Divider(height: 1),
              _ConfigAlertBanner(message),
            ],
          ],
        ),
      ),
    );
  }
}

class _ConfigAlertBanner extends StatelessWidget {
  final String message;
  const _ConfigAlertBanner(this.message);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        color: cs.errorContainer,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            ExcludeSemantics(
              child: Icon(
                Icons.warning_amber_outlined,
                color: cs.onErrorContainer,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: cs.onErrorContainer, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// « Lancements de sessions : N ce mois-ci · R aujourd'hui sur 10 » : un
/// nombre de lancements, jamais un montant (le coût est facturé sur
/// l'abonnement Claude de l'administrateur).
class _LaunchCounter extends ConsumerWidget {
  const _LaunchCounter();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statusAsync = ref.watch(ticketsStatusProvider);
    final limit = ref.watch(ticketLaunchesPerDayProvider).value;
    if (statusAsync.hasError && !statusAsync.hasValue) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
        child: Row(
          children: [
            const Expanded(
              child: TicketInfoLine(
                'Lancements de sessions : compteur indisponible.',
              ),
            ),
            IconButton(
              onPressed: () => ref.invalidate(ticketsStatusProvider),
              icon: const Icon(Icons.refresh),
              tooltip: 'Réessayer',
            ),
          ],
        ),
      );
    }
    final status = statusAsync.value;
    if (status == null) return const SizedBox.shrink();
    final now = DateTime.now();
    final today = status.launchesTodayAt(now);
    final month = status.launchesMonthAt(now);
    final todayText = limit == null
        ? '$today aujourd\'hui'
        : '$today aujourd\'hui sur $limit';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: TicketInfoLine(
        'Lancements de sessions : $month ce mois-ci · $todayText',
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
    final issue = ticket.githubIssueNumber;
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
            // Sans Issue (envoi en cours, en anomalie), pas de numéro.
            Text(
              [
                if (issue != null) '#$issue',
                author,
                created == null ? '…' : formatTicketDate(created),
              ].join(' · '),
            ),
            TicketStatusChip(status: ticket.status),
            if (ticket.status == TicketStatus.inProgress &&
                ticket.rawStatus == ticket.status.value)
              _DeliveryReadyChip(ticketId: ticket.id),
            AdminTicketLaunchChip(ticket: ticket),
            if (ticket.isInAnomaly) const TicketAnomalyChip(),
          ],
        ),
      ),
      onTap: onTap,
    );
  }
}

/// Puce « Analyse en cours », « Développement en cours » ou « Livraison en
/// cours » d'un ticket de la liste, puis « Relance possible » à l'échéance.
/// La règle est celle de la fiche (`adminTicketDecisions`). Rien tant que
/// l'historique n'est pas lu, ni s'il ne se lit pas : la fiche le dit.
class AdminTicketLaunchChip extends ConsumerStatefulWidget {
  final Ticket ticket;
  const AdminTicketLaunchChip({super.key, required this.ticket});

  @override
  ConsumerState<AdminTicketLaunchChip> createState() =>
      AdminTicketLaunchChipState();
}

class AdminTicketLaunchChipState extends ConsumerState<AdminTicketLaunchChip> {
  Timer? _timer;
  DateTime? _timerAt;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _arm(DateTime? until) {
    if (until == _timerAt) return;
    _timer?.cancel();
    _timer = null;
    _timerAt = until;
    if (until == null) return;
    final delay = until.difference(DateTime.now());
    // Une seconde de marge : à l'instant exact, la règle compare encore
    // « avant l'échéance ».
    _timer = Timer(
      (delay.isNegative ? Duration.zero : delay) + const Duration(seconds: 1),
      () {
        _timerAt = null;
        if (mounted) setState(() {});
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.ticket;
    final active =
        t.githubIssueNumber != null &&
        t.type != TicketType.question &&
        t.rawStatus == t.status.value &&
        (t.status == TicketStatus.received ||
            t.status == TicketStatus.validated ||
            t.status == TicketStatus.inProgress);
    if (!active) {
      _arm(null);
      return const SizedBox.shrink();
    }
    final launches = ref.watch(ticketLaunchesProvider(t.id));
    // La dernière analyse décide du blocage « attend une réponse », qui ne
    // compte que pour un ticket Validé ; la livraison, pour un ticket En cours.
    final analysis = t.status == TicketStatus.validated
        ? ref.watch(ticketAnalysisProvider(t.id))
        : null;
    final delivery = t.status == TicketStatus.inProgress
        ? ref.watch(ticketDeliveryProvider(t.id))
        : null;
    if (launches.hasError ||
        !launches.hasValue ||
        (analysis != null && !analysis.hasValue) ||
        (delivery != null && !delivery.hasValue)) {
      _arm(null);
      return const SizedBox.shrink();
    }
    final decisions = adminTicketDecisions(
      t,
      launches: launches.value,
      now: DateTime.now(),
      analysis: analysis?.value,
      delivery: delivery?.value,
    );
    _arm(decisions.runningUntil);
    final action = decisions.launchAction;
    final since = decisions.runningSince;
    if (action != null && since != null) {
      return Semantics(
        label: ticketLaunchRunningLine(action, since, DateTime.now()),
        excludeSemantics: true,
        child: TicketLaunchStateChip(label: '${action.noun} en cours'),
      );
    }
    if (decisions.relaunchOf != null && !decisions.relaunchAfterBlock) {
      return const TicketLaunchStateChip(
        label: 'Relance possible',
        relaunch: true,
      );
    }
    return const SizedBox.shrink();
  }
}

/// Puce « PR prête » d'un ticket En cours dont la pull request peut être
/// livrée (`tickets/{id}/admin/delivery.ready`). Rien tant que l'état n'est
/// pas lu, ni s'il ne se lit pas : la fiche le dit.
class _DeliveryReadyChip extends ConsumerWidget {
  final String ticketId;
  const _DeliveryReadyChip({required this.ticketId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ready = ref.watch(ticketDeliveryProvider(ticketId)).value?.ready;
    if (ready != true) return const SizedBox.shrink();
    return Semantics(
      label: 'Pull request prête à livrer',
      excludeSemantics: true,
      child: const TicketDeliveryReadyChip(),
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

  /// Le ticket dont une validation ou un lancement est en cours : un seul à
  /// la fois. Le même `State` sert à tous les tickets (écran large) : un
  /// lancement laissé en route sur le ticket A ne bloque pas le ticket B.
  String? _busyTicketId;

  bool get _busy => _busyTicketId == widget.ticket.id;

  /// La décision en cours est une validation : seul « Valider » montre alors
  /// l'indicateur, pas pendant une réponse ou un lancement.
  bool _validating = false;

  void _setBusy(String ticketId) => setState(() => _busyTicketId = ticketId);

  /// Libère [ticketId], sauf si un autre ticket a pris la place entre-temps.
  void _clearBusy(String ticketId) {
    if (!mounted || _busyTicketId != ticketId) return;
    setState(() => _busyTicketId = null);
  }

  /// Redessine la fiche à l'échéance du lancement en cours, pour que
  /// « … en cours depuis » laisse place à « Relancer… » sans geste.
  Timer? _runTimer;
  DateTime? _runTimerAt;

  void _armRunTimer(DateTime? until) {
    if (until == _runTimerAt) return;
    _cancelRunTimer();
    if (until == null) return;
    _runTimerAt = until;
    final delay = until.difference(DateTime.now());
    // Une seconde de marge : à l'instant exact, la règle compare encore
    // « avant l'échéance ».
    _runTimer = Timer(
      (delay.isNegative ? Duration.zero : delay) + const Duration(seconds: 1),
      () {
        _runTimerAt = null;
        if (mounted) setState(() {});
      },
    );
  }

  void _cancelRunTimer() {
    _runTimer?.cancel();
    _runTimer = null;
    _runTimerAt = null;
  }

  /// Motif du refus : gardé si l'administrateur ferme puis rouvre la boîte.
  final _reasonController = TextEditingController();

  /// Le motif a été publié sans que l'Issue soit fermée : il ne change plus.
  bool _reasonLocked = false;

  /// Brouillon de la réponse à l'analyse : gardé si l'administrateur ferme
  /// puis rouvre la boîte, vidé après un succès ou un changement de ticket.
  final _answerController = TextEditingController();

  /// La réponse a été publiée sans que les étiquettes changent : elle ne
  /// change plus, et « Publier » finit le passage à Reçu.
  bool _answerLocked = false;

  @override
  void didUpdateWidget(covariant _AdminTicketDetail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ticket.id != widget.ticket.id) {
      _cancelRunTimer();
      _reasonController.clear();
      _reasonLocked = false;
      _answerController.clear();
      _answerLocked = false;
    }
  }

  @override
  void dispose() {
    _cancelRunTimer();
    _reasonController.dispose();
    _answerController.dispose();
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
        content: const Text('Vous pourrez ensuite lancer le développement.'),
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
    final ticketId = widget.ticket.id;
    _validating = true;
    _setBusy(ticketId);
    try {
      await ref.read(ticketRepositoryProvider).validate(ticketId);
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
      _validating = false;
      _clearBusy(ticketId);
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

  /// « Répondre » : publie les précisions de l'administrateur sous la
  /// dernière analyse. Pendant l'envoi, la boîte peut être fermée : le
  /// résultat s'affiche ensuite par le messenger capturé.
  Future<void> _answer() async {
    final ticket = widget.ticket;
    final analysisAt = ref
        .read(ticketAnalysisProvider(ticket.id))
        .value
        ?.lastAnalysisAt;
    // Capturés avant l'appel : la boîte peut être fermée pendant l'envoi, et
    // la fiche quittée, avant que le résultat n'arrive.
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;
    Future<String>? pending;
    _setBusy(ticket.id);
    try {
      final result = await showDialog<_AnswerDialogResult>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _AnswerTicketDialog(
          controller: _answerController,
          locked: _answerLocked,
          onLocked: () {
            if (mounted && widget.ticket.id == ticket.id) {
              setState(() => _answerLocked = true);
            }
          },
          analysisAt: analysisAt,
          validated: ticket.status == TicketStatus.validated,
          submit: (text) => pending = ref
              .read(ticketRepositoryProvider)
              .answer(ticket.id, text),
        ),
      );
      String? failure;
      var published = result == _AnswerDialogResult.answered;
      if (result == _AnswerDialogResult.detached) {
        // « Fermer » pendant l'envoi : l'appel continue, son résultat
        // s'affiche ici.
        final inFlight = pending;
        if (inFlight == null) return;
        try {
          await inFlight;
          published = true;
        } on TicketDecisionError catch (e) {
          // Déjà remontée par `TicketRepository` (feature `tickets`).
          failure = e.message;
          if (e.partial && mounted && widget.ticket.id == ticket.id) {
            setState(() => _answerLocked = true);
          }
        } catch (e) {
          // Déjà remontée par `TicketRepository` (feature `tickets`).
          failure =
              'Réponse non publiée : ${shortErrorMessage(e)} Votre texte '
              'est gardé.';
        }
      }
      if (published && mounted && widget.ticket.id == ticket.id) {
        _answerController.clear();
        setState(() => _answerLocked = false);
      }
      if (!messenger.mounted) return;
      if (published) {
        messenger.showSuccessMessage(
          'Réponse publiée. Le ticket repasse à Reçu : lancez l\'analyse.',
          scheme: scheme,
        );
      } else if (failure != null) {
        messenger.showErrorMessage(failure, scheme: scheme);
      }
    } finally {
      _clearBusy(ticket.id);
    }
  }

  Future<void> _launch(
    TicketLaunchAction action,
    DateTime? relaunchOf, {
    int? prNumber,
    bool relaunchAfterBlock = false,
  }) async {
    final ticket = widget.ticket;
    final issue = ticket.githubIssueNumber;
    if (issue == null) return;
    final status = ref.read(ticketsStatusProvider);
    final limit = ref.read(ticketLaunchesPerDayProvider).value;
    final todayStatus = status.hasError ? null : status.value;
    final remaining = limit == null || todayStatus == null
        ? null
        : (limit - todayStatus.launchesTodayAt(DateTime.now()))
              .clamp(0, limit)
              .toInt();
    // Capturés avant l'appel : la boîte peut être fermée pendant l'envoi, et
    // la fiche quittée, avant que le résultat n'arrive.
    final messenger = ScaffoldMessenger.of(context);
    final scheme = Theme.of(context).colorScheme;
    Future<TicketLaunchResult>? pending;
    _setBusy(ticket.id);
    try {
      var outcome = await showDialog<_LaunchDialogOutcome>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _LaunchTicketDialog(
          action: action,
          issueNumber: issue,
          relaunchOf: relaunchOf,
          relaunchAfterBlock: relaunchAfterBlock,
          prNumber: prNumber,
          ticketType: ticket.type,
          remaining: remaining,
          limit: limit,
          submit: () => pending = ref
              .read(ticketRepositoryProvider)
              .launch(ticket.id, action),
        ),
      );
      if (outcome?.kind == _LaunchDialogResult.detached) {
        // « Fermer » pendant l'envoi : l'appel continue, son résultat
        // s'affiche ici. La section Lancements se met à jour seule.
        final inFlight = pending;
        if (inFlight == null) return;
        outcome = await _settleLaunch(inFlight);
      }
      if (outcome == null) return;
      final (String text, bool isError) = switch (outcome.kind) {
        _LaunchDialogResult.launched => (
          'Session lancée. Le lien est dans la section Lancements.',
          false,
        ),
        // Un 5xx de Claude a son message ; sans réponse, le message
        // générique du résultat inconnu.
        _LaunchDialogResult.unknown => (
          outcome.message ??
              'Résultat inconnu : vérifiez sur claude.ai/code avant de '
                  'relancer.',
          true,
        ),
        _LaunchDialogResult.lost => (
          'Réponse perdue. Regardez la section Lancements avant de '
              'relancer.',
          true,
        ),
        // Un refus arrivé après « Fermer » : rien n'a été lancé.
        _LaunchDialogResult.refused => (
          outcome.message ?? 'Lancement refusé.',
          true,
        ),
        // Jamais rendu par `_settleLaunch` : la réponse est tenue pour perdue.
        _LaunchDialogResult.detached => (
          'Réponse perdue. Regardez la section Lancements avant de '
              'relancer.',
          true,
        ),
      };
      // Le messenger capturé sert aussi quand la fiche a été quittée.
      if (!messenger.mounted) return;
      if (isError) {
        messenger.showErrorMessage(text, scheme: scheme);
      } else {
        messenger.showSuccessMessage(text, scheme: scheme);
      }
    } finally {
      _clearBusy(ticket.id);
    }
  }

  /// Ouvre [url] hors de l'application ; [failure] s'affiche en cas d'échec.
  Future<void> _openLink(
    String url, {
    required String failure,
    required String step,
  }) async {
    try {
      final ok = await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      );
      if (!ok && mounted) context.showErrorSnackBar(failure);
    } catch (e, st) {
      reportUnexpectedError(
        feature: 'tickets',
        error: e,
        stackTrace: st,
        context: {'step': step, 'ticket_id': widget.ticket.id},
      );
      if (mounted) context.showErrorSnackBar(failure);
    }
  }

  Future<void> _openGithub(String url) => _openLink(
    url,
    failure: 'Impossible d\'ouvrir GitHub.',
    step: 'open_github',
  );

  /// Ouvre une session Claude Code, seulement sur `https://claude.ai`.
  Future<void> _openSession(String? url) async {
    final uri = openableSessionLink(url);
    if (uri == null) {
      context.showErrorSnackBar('Lien de session invalide.');
      return;
    }
    await _openLink(
      uri.toString(),
      failure: 'Impossible d\'ouvrir la session.',
      step: 'open_session',
    );
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

  /// Le verrou des livraisons quand il est actif et tenu par un autre
  /// ticket, sinon `null` (absent, échu, illisible : « Livrer » reste
  /// offert, le serveur tranche).
  TicketDeliveryLock? _lockElsewhere(String ticketId, DateTime now) {
    final status = ref.watch(ticketsStatusProvider);
    final lock = status.hasError ? null : status.value?.deliveryRunning;
    if (lock == null || lock.ticketId == null || lock.ticketId == ticketId) {
      return null;
    }
    String? lockedStatus;
    for (final t in ref.watch(adminTicketsProvider).value ?? const <Ticket>[]) {
      if (t.id == lock.ticketId) lockedStatus = t.rawStatus;
    }
    final active = ticketDeliveryLockActive(
      lock: lock,
      lockedTicketRawStatus: lockedStatus,
      now: now,
    );
    return active ? lock : null;
  }

  void _openOtherTicket(String ticketId) {
    final location = AppRoutes.adminTicketDetail(ticketId);
    if (MediaQuery.sizeOf(context).width >= PlatformUtils.wideBreakpoint) {
      context.go(location);
    } else {
      context.push(location);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ticket = widget.ticket;
    final theme = Theme.of(context);
    final author = ref.watch(memberNameProvider(ticket.authorUid)) ?? '…';
    final created = ticket.createdAt;
    final url = ticket.githubUrl;
    final issue = ticket.githubIssueNumber;
    final screenshot = ticket.screenshotPath;
    final reply = ticket.replyText;
    final launchesAsync = ref.watch(ticketLaunchesProvider(ticket.id));
    final analysisAsync = ref.watch(ticketAnalysisProvider(ticket.id));
    final deliveryAsync = ref.watch(ticketDeliveryProvider(ticket.id));
    final delivery = deliveryAsync.hasError ? null : deliveryAsync.value;
    // Lus par la boîte de lancement (lancements restants) : surveillés ici
    // pour être chargés avant l'appui, sur la fiche seule au téléphone.
    ref.watch(ticketsStatusProvider);
    ref.watch(ticketLaunchesPerDayProvider);
    final now = DateTime.now();
    final decisions = adminTicketDecisions(
      ticket,
      launches: launchesAsync.hasError ? null : launchesAsync.value,
      launchesLoading: launchesAsync.isLoading && !launchesAsync.hasValue,
      now: now,
      analysis: analysisAsync.hasError ? null : analysisAsync.value,
      delivery: delivery,
    );
    final hint = decisions.validateHint;
    final lockElsewhere = _lockElsewhere(ticket.id, now);
    final deliveryBar =
        decisions.launchAction == TicketLaunchAction.delivery && issue != null
        ? ticketDeliveryBar(
            run: TicketLaunchRunState(
              runningSince: decisions.runningSince,
              relaunchOf: decisions.relaunchOf,
              blocked: decisions.relaunchAfterBlock,
            ),
            deliveryLoading:
                (deliveryAsync.isLoading && !deliveryAsync.hasValue) ||
                (launchesAsync.isLoading && !launchesAsync.hasValue),
            deliveryError: deliveryAsync.hasError,
            delivery: delivery,
            issueNumber: issue,
            lockElsewhere: lockElsewhere,
            now: now,
          )
        : null;
    final prLink = delivery?.openablePrLink;
    // À l'échéance du lancement en cours, ou du verrou tenu par un autre
    // ticket, la fiche se redessine.
    _armRunTimer(decisions.runningUntil ?? lockElsewhere?.retryAfter);
    final launchAction = decisions.canLaunchAnalysis
        ? TicketLaunchAction.analysis
        : decisions.canLaunchDevelopment
        ? TicketLaunchAction.development
        : null;
    final runningSince = decisions.runningSince;
    final runningAction = decisions.launchAction;

    final detailsColumn = Column(
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
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            TicketStatusChip(status: ticket.status),
            if (ticket.isInAnomaly) const TicketAnomalyChip(),
            if (issue != null)
              SelectableText(
                'Issue #$issue',
                style: theme.textTheme.labelLarge,
              ),
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
              if (prLink != null &&
                  (ticket.status == TicketStatus.inProgress ||
                      ticket.status == TicketStatus.delivered))
                OutlinedButton.icon(
                  onPressed: () => _openGithub(prLink.toString()),
                  icon: const Icon(Icons.open_in_new),
                  label: Text('Ouvrir la PR #${delivery?.prNumber}'),
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
        TicketInfoLine('Plateforme : ${ticketPlatformLabel(ticket.platform)}'),
        TicketInfoLine('Écran : ${ticketScreenLabel(ticket.screen)}'),
        const SizedBox(height: 16),
        Text('Description', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        SelectableText(ticket.description),
        if (screenshot != null) ...[
          const SizedBox(height: 16),
          TicketScreenshotView(path: screenshot, height: 360),
        ],
        if (ticket.status == TicketStatus.inProgress ||
            ticket.status == TicketStatus.delivered ||
            (delivery?.reports.isNotEmpty ?? false)) ...[
          const SizedBox(height: 24),
          _DeliverySection(ticket: ticket, onOpenGithub: _openGithub),
        ],
        const SizedBox(height: 24),
        _LaunchesSection(
          ticketId: ticket.id,
          onOpenSession: _openSession,
          onCopyLink: _copyLink,
        ),
        const SizedBox(height: 24),
        _AnalysesSection(ticket: ticket, onOpenGithub: _openGithub),
      ],
    );

    if (!decisions.hasAction) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: detailsColumn,
      );
    }

    // Une ligne d'information au plus au-dessus des boutons : le blocage,
    // un lancement en cours, ou une réponse que la prochaine analyse lira.
    final lastAnalysisAt = decisions.lastAnalysisAt;
    final pendingAnswerAt = decisions.pendingAnswerAt;
    final (IconData, String)? info = deliveryBar != null
        ? (_deliveryLineIcon(deliveryBar.kind), deliveryBar.text)
        : decisions.awaitingReply
        ? (
            Icons.mark_chat_unread_outlined,
            lastAnalysisAt == null
                ? 'La dernière analyse attend votre réponse.'
                : 'La dernière analyse, du '
                      '${formatTicketDateTime(lastAnalysisAt)}, attend votre '
                      'réponse.',
          )
        : runningSince != null && runningAction != null
        ? (
            Icons.hourglass_top,
            ticketLaunchRunningLine(runningAction, runningSince, now),
          )
        : pendingAnswerAt != null
        ? (
            Icons.mark_chat_unread_outlined,
            'Vos précisions du ${formatTicketDateTime(pendingAnswerAt)} '
                'seront lues par la prochaine analyse.',
          )
        : null;

    // « Répondre » est masqué pendant une décision ou un lancement de la
    // fiche : la boîte ne s'ouvre pas sur un ticket qui change.
    final showReply = decisions.canReply && !_busy;
    final replyIsPrimary = showReply && decisions.awaitingReply;
    final secondary = <Widget>[
      if (decisions.canRefuse)
        OutlinedButton.icon(
          onPressed: _busy ? null : _refuse,
          icon: const Icon(AppIcons.ticketStatusRefused),
          label: const Text('Refuser'),
        ),
      if (showReply && !replyIsPrimary)
        OutlinedButton.icon(
          onPressed: _answer,
          icon: const Icon(Icons.reply),
          label: const Text('Répondre'),
        ),
    ];
    final Widget? primary;
    if (replyIsPrimary) {
      primary = FilledButton.icon(
        onPressed: _answer,
        icon: const Icon(Icons.reply),
        label: const Text('Répondre'),
      );
    } else if (decisions.canValidate) {
      primary = FilledButton.icon(
        onPressed: _busy ? null : _validate,
        icon: _busy && _validating
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(AppIcons.ticketStatusValidated),
        label: const Text('Valider'),
      );
    } else if (launchAction != null) {
      primary = _LaunchButton(
        action: launchAction,
        relaunch: decisions.relaunchOf != null,
        onPressed: _busy
            ? null
            : () => _launch(launchAction, decisions.relaunchOf),
      );
    } else if (decisions.canDeliver && deliveryBar?.action != null) {
      final relaunch = deliveryBar!.action == TicketDeliveryAction.relaunch;
      primary = _LaunchButton(
        action: TicketLaunchAction.delivery,
        relaunch: relaunch,
        onPressed: _busy
            ? null
            : () => _launch(
                TicketLaunchAction.delivery,
                relaunch ? decisions.relaunchOf : null,
                prNumber: delivery?.prNumber,
                relaunchAfterBlock: relaunch && decisions.relaunchAfterBlock,
              ),
      );
    } else {
      primary = null;
    }

    final bar = SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (info != null) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Icon(
                      info.$1,
                      size: 20,
                      color:
                          deliveryBar?.kind == TicketDeliveryLineKind.ready ||
                              deliveryBar?.kind ==
                                  TicketDeliveryLineKind.expired
                          ? theme.colorScheme.primary
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Semantics(
                      container: true,
                      liveRegion: deliveryBar != null,
                      child: TicketInfoLine(info.$2),
                    ),
                  ),
                  if (deliveryBar?.kind == TicketDeliveryLineKind.unreadable)
                    IconButton(
                      onPressed: () =>
                          ref.invalidate(ticketDeliveryProvider(ticket.id)),
                      icon: const Icon(Icons.refresh),
                      tooltip: 'Réessayer',
                    ),
                ],
              ),
              if (deliveryBar?.elsewhereTicketId case final otherId?)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    onPressed: () => _openOtherTicket(otherId),
                    child: Text(
                      'Ouvrir le ticket #${deliveryBar?.elsewhereIssueNumber}',
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
            // Secondaires à gauche, une seule action principale à droite. Trop
            // large (texte agrandi, téléphone), la barre passe sur deux lignes,
            // l'action principale en bas à droite.
            OverflowBar(
              alignment: MainAxisAlignment.spaceBetween,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: 8,
              overflowSpacing: 8,
              children: [
                Wrap(spacing: 8, runSpacing: 8, children: secondary),
                ?primary,
              ],
            ),
          ],
        ),
      ),
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // La barre reste en bas tant qu'elle laisse de quoi lire la fiche.
        // Sur un écran bas (paysage, texte agrandi, bandeaux), elle suit la
        // fiche en fin de défilement plutôt que de la masquer.
        if (constraints.maxHeight >= PlatformUtils.pinnedActionBarMinHeight) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: detailsColumn,
                ),
              ),
              const Divider(height: 1),
              bar,
            ],
          );
        }
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(padding: const EdgeInsets.all(16), child: detailsColumn),
              const Divider(height: 1),
              bar,
            ],
          ),
        );
      },
    );
  }
}

/// Icône de la ligne d'état d'un ticket En cours.
IconData _deliveryLineIcon(TicketDeliveryLineKind kind) => switch (kind) {
  TicketDeliveryLineKind.running ||
  TicketDeliveryLineKind.elsewhere => Icons.hourglass_top,
  TicketDeliveryLineKind.loading ||
  TicketDeliveryLineKind.ciRunning => Icons.pending_outlined,
  TicketDeliveryLineKind.unreadable ||
  TicketDeliveryLineKind.blocked => Icons.error_outline,
  TicketDeliveryLineKind.multiplePrs ||
  TicketDeliveryLineKind.ciFailed => Icons.warning_amber_outlined,
  TicketDeliveryLineKind.noPr => Icons.info_outline,
  TicketDeliveryLineKind.expired ||
  TicketDeliveryLineKind.ready => Icons.check_circle_outline,
};

/// « Lancer l'analyse » / « Lancer le développement » / « Livrer », ou leur
/// variante « Relancer… » quand le lancement précédent n'a rien changé au
/// ticket (ou, pour une livraison, s'est arrêté sur un blocage).
class _LaunchButton extends StatelessWidget {
  final TicketLaunchAction action;
  final bool relaunch;
  final VoidCallback? onPressed;

  const _LaunchButton({
    required this.action,
    required this.relaunch,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final label = switch ((action, relaunch)) {
      (TicketLaunchAction.analysis, false) => 'Lancer l\'analyse',
      (TicketLaunchAction.analysis, true) => 'Relancer l\'analyse',
      (TicketLaunchAction.development, false) => 'Lancer le développement',
      (TicketLaunchAction.development, true) => 'Relancer le développement',
      (TicketLaunchAction.delivery, false) => 'Livrer',
      (TicketLaunchAction.delivery, true) => 'Relancer la livraison',
    };
    if (relaunch) {
      return FilledButton.tonalIcon(
        onPressed: onPressed,
        icon: const Icon(Icons.refresh),
        label: Text(label),
      );
    }
    return FilledButton.icon(
      onPressed: onPressed,
      icon: Icon(switch (action) {
        TicketLaunchAction.analysis => AppIcons.ticketLaunchAnalysis,
        TicketLaunchAction.development => AppIcons.ticketLaunchDevelopment,
        TicketLaunchAction.delivery => AppIcons.ticketDeliver,
      }),
      label: Text(label),
    );
  }
}

/// Ce que la boîte de lancement rend en se fermant, ou ce qu'un appel rend
/// une fois la boîte fermée.
enum _LaunchDialogResult {
  launched,
  unknown,
  lost,

  /// Refus du serveur : rien n'a été lancé.
  refused,

  /// Boîte fermée par « Fermer » pendant l'envoi : l'appel continue, et
  /// l'appelant en attend le résultat.
  detached,
}

/// Ce que la boîte rend, avec le message du serveur pour un résultat inconnu
/// ou un refus.
typedef _LaunchDialogOutcome = ({
  _LaunchDialogResult kind,
  String? message,
  String? reason,
});

/// Attend la réponse d'un lancement et la range dans un des résultats. Les
/// erreurs sont déjà remontées par `TicketRepository.launch` (feature
/// `tickets`).
Future<_LaunchDialogOutcome> _settleLaunch(
  Future<TicketLaunchResult> pending,
) async {
  try {
    final result = await pending;
    return result.outcome == TicketLaunchOutcome.launched
        ? (kind: _LaunchDialogResult.launched, message: null, reason: null)
        : (
            kind: _LaunchDialogResult.unknown,
            message: result.message,
            reason: null,
          );
  } on TicketLaunchError catch (e) {
    // Déjà remontée par `TicketRepository` (feature `tickets`).
    return (
      kind: _LaunchDialogResult.refused,
      message: e.message,
      reason: e.reason,
    );
  } catch (_) {
    // Déjà remontée par `TicketRepository` (feature `tickets`) : la réponse
    // s'est perdue, la session a pu partir.
    return (kind: _LaunchDialogResult.lost, message: null, reason: null);
  }
}

/// Boîte « Lancer l'analyse de ce ticket ? » / « Lancer le développement de
/// ce ticket ? ».
///
/// Reste ouverte sur un refus du serveur, avec son message : rien n'a été
/// lancé. Se ferme sur un succès, un résultat inconnu, ou une réponse perdue
/// (l'appelant le dit par un message). Pendant l'envoi, « Fermer » (ou le
/// retour) la ferme sans couper l'appel : l'appelant en affiche le résultat.
class _LaunchTicketDialog extends StatefulWidget {
  final TicketLaunchAction action;
  final int issueNumber;
  final DateTime? relaunchOf;

  /// Livraison : la relance suit un blocage relevé, pas l'échéance.
  final bool relaunchAfterBlock;

  /// Livraison : la PR prête, et le type du ticket rappelé dans la boîte.
  final int? prNumber;
  final TicketType ticketType;

  /// Lancements restants aujourd'hui, ou `null` s'ils ne se lisent pas.
  final int? remaining;
  final int? limit;
  final Future<TicketLaunchResult> Function() submit;

  const _LaunchTicketDialog({
    required this.action,
    required this.issueNumber,
    required this.relaunchOf,
    this.relaunchAfterBlock = false,
    this.prNumber,
    required this.ticketType,
    required this.remaining,
    required this.limit,
    required this.submit,
  });

  @override
  State<_LaunchTicketDialog> createState() => _LaunchTicketDialogState();
}

class _LaunchTicketDialogState extends State<_LaunchTicketDialog> {
  bool _sending = false;
  String? _error;

  /// La PR modifie un fichier sensible : « Livrer » reste grisé, rien ne
  /// partira tant qu'elle n'est pas fusionnée à la main.
  bool _sensitive = false;

  /// La boîte a déjà demandé sa fermeture : un second `pop` fermerait la
  /// fiche (« Fermer » et la réponse arrivés dans la même image).
  bool _closing = false;

  void _close(_LaunchDialogOutcome? outcome) {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).pop(outcome);
  }

  /// « Fermer » pendant l'envoi : l'appel continue, l'appelant l'attend.
  void _detach() =>
      _close((kind: _LaunchDialogResult.detached, message: null, reason: null));

  Future<void> _submit() async {
    setState(() {
      _error = null;
      _sending = true;
    });
    final outcome = await _settleLaunch(widget.submit());
    if (!mounted || _closing) return;
    if (outcome.kind == _LaunchDialogResult.refused) {
      setState(() {
        _error = outcome.message;
        _sending = false;
        if (outcome.reason == kTicketDeliverySensitiveReason) _sensitive = true;
      });
      return;
    }
    _close(outcome);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final muted = textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant);
    final error = _error;
    final remaining = widget.remaining;
    final limit = widget.limit;
    final exhausted = remaining != null && remaining <= 0;
    final relaunchOf = widget.relaunchOf;
    final isDelivery = widget.action == TicketLaunchAction.delivery;
    final pr = widget.prNumber == null ? 'la PR' : 'la PR #${widget.prNumber}';
    final String quotaLine;
    if (remaining == null || limit == null) {
      quotaLine = 'Lancements restants aujourd\'hui : inconnu.';
    } else if (exhausted) {
      quotaLine =
          'Vous avez lancé $limit sessions aujourd\'hui. Réessayez demain.';
    } else {
      quotaLine = 'Lancements restants aujourd\'hui : $remaining sur $limit.';
    }

    Widget box(IconData icon, String text) => Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: Icon(icon, color: cs.onSurfaceVariant)),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: muted)),
        ],
      ),
    );

    return PopScope(
      canPop: !_sending,
      // Le retour pendant l'envoi vaut « Fermer ».
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _sending) _detach();
      },
      child: AlertDialog(
        scrollable: true,
        title: Text(switch (widget.action) {
          TicketLaunchAction.analysis => 'Lancer l\'analyse de ce ticket ?',
          TicketLaunchAction.development =>
            'Lancer le développement de ce ticket ?',
          TicketLaunchAction.delivery => 'Livrer ce ticket ?',
        }),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(switch (widget.action) {
              TicketLaunchAction.analysis =>
                'Une session Claude Code va lire l\'Issue '
                    '#${widget.issueNumber} et publier son analyse sur '
                    'GitHub.',
              TicketLaunchAction.development =>
                'Une session Claude Code va écrire le code de l\'Issue '
                    '#${widget.issueNumber} et ouvrir une pull request. '
                    'Elle ne fusionne rien.',
              TicketLaunchAction.delivery =>
                'Une session Claude Code va mettre $pr à jour avec master, '
                    'la fusionner, puis suivre le déploiement.',
            }),
            if (isDelivery) ...[
              const SizedBox(height: 12),
              const Text(
                'La fusion met l\'application en ligne pour toute la '
                'famille. Appuyer sur « Livrer » vaut accord de fusion.',
              ),
              const SizedBox(height: 12),
              Text('Type du ticket : ${widget.ticketType.label}.'),
            ],
            const SizedBox(height: 12),
            Text(quotaLine),
            if (relaunchOf != null) ...[
              const SizedBox(height: 12),
              box(
                Icons.warning_amber_outlined,
                !isDelivery
                    ? 'Le lancement du ${formatTicketDateTime(relaunchOf)} '
                          'n\'a rien changé au ticket. Vérifiez sur '
                          'claude.ai/code qu\'aucune session ne tourne encore.'
                    : widget.relaunchAfterBlock
                    ? 'La livraison du ${formatTicketDateTime(relaunchOf)} '
                          's\'est arrêtée. Lisez « Livraison — '
                          'blocage » avant de relancer.'
                    : 'La livraison du ${formatTicketDateTime(relaunchOf)} '
                          'n\'a rien fusionné en trois heures. Vérifiez sur '
                          'claude.ai/code qu\'aucune session ne tourne encore.',
              ),
            ],
            const SizedBox(height: 12),
            box(
              Icons.payments_outlined,
              'Facturé sur l\'abonnement Claude de l\'administrateur. Ce coût '
              'n\'apparaît pas dans le suivi des coûts de l\'application.',
            ),
            if (_sending) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  'Lancement en cours. Vous pouvez fermer : le résultat '
                  's\'affichera dans la section Lancements.',
                  style: muted,
                ),
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(error, style: TextStyle(color: cs.error)),
              ),
            ],
          ],
        ),
        actions: [
          // Avant l'appui sur « Lancer », rien n'est appelé. Pendant l'envoi,
          // « Fermer » laisse l'appel aller à son terme.
          // Une livraison fusionne et déploie : le focus part sur
          // « Annuler », pas sur l'action.
          TextButton(
            autofocus: isDelivery,
            onPressed: _sending ? _detach : () => _close(null),
            child: Text(_sending ? 'Fermer' : 'Annuler'),
          ),
          FilledButton(
            onPressed: _sending || exhausted || _sensitive ? null : _submit,
            child: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    relaunchOf != null
                        ? 'Relancer'
                        : isDelivery
                        ? 'Livrer'
                        : 'Lancer',
                  ),
          ),
        ],
      ),
    );
  }
}

/// Section « Lancements (N) » de la fiche : les sessions lancées sur ce
/// ticket, plus récente en tête.
class _LaunchesSection extends ConsumerWidget {
  final String ticketId;
  final Future<void> Function(String? url) onOpenSession;
  final Future<void> Function(String url) onCopyLink;

  const _LaunchesSection({
    required this.ticketId,
    required this.onOpenSession,
    required this.onCopyLink,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ref
        .watch(ticketLaunchesProvider(ticketId))
        .when(
          skipLoadingOnRefresh: false,
          // Hauteur minimale, pas fixe : à 200 % le libellé passe sur deux
          // lignes et déborderait d'une boîte de 120 px.
          loading: () => ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 120),
            child: const AppLoadingState(label: 'Chargement des lancements…'),
          ),
          error: (error, _) => AppErrorState(
            error: error,
            compact: true,
            title: 'Impossible de charger les lancements.',
            onRetry: () => ref.invalidate(ticketLaunchesProvider(ticketId)),
          ),
          data: (launches) {
            final list = launches ?? const <TicketLaunch>[];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Lancements (${list.length})',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                if (list.isEmpty)
                  const TicketInfoLine('Aucune session lancée pour ce ticket.')
                else
                  for (final (i, launch) in list.indexed) ...[
                    if (i > 0) const SizedBox(height: 12),
                    _LaunchCard(
                      launch: launch,
                      onOpenSession: onOpenSession,
                      onCopyLink: onCopyLink,
                    ),
                  ],
              ],
            );
          },
        );
  }
}

class _LaunchCard extends StatelessWidget {
  final TicketLaunch launch;
  final Future<void> Function(String? url) onOpenSession;
  final Future<void> Function(String url) onCopyLink;

  const _LaunchCard({
    required this.launch,
    required this.onOpenSession,
    required this.onCopyLink,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final at = launch.launchedAt;
    final by = launch.launchedByName.isEmpty ? '…' : launch.launchedByName;
    final url = launch.sessionUrl;
    final (
      IconData icon,
      Color color,
      String result,
    ) = switch (launch.outcome) {
      TicketLaunchOutcome.launched => (
        Icons.check_circle_outline,
        cs.primary,
        'Session créée',
      ),
      TicketLaunchOutcome.failed => (
        Icons.error_outline,
        cs.error,
        'Échec : ${launch.errorReason ?? 'raison inconnue'}',
      ),
      TicketLaunchOutcome.unknown || null => (
        Icons.help_outline,
        cs.onSurfaceVariant,
        'Résultat inconnu : vérifiez sur claude.ai/code',
      ),
    };
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
            launch.action?.historyTitle ?? 'Lancement',
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: 4),
          TicketInfoLine(
            at == null ? 'par $by' : 'le ${formatTicketDateTime(at)} par $by',
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(child: Icon(icon, size: 20, color: color)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  result,
                  style: theme.textTheme.bodyMedium?.copyWith(color: color),
                ),
              ),
            ],
          ),
          if (launch.outcome == TicketLaunchOutcome.launched &&
              url != null) ...[
            const SizedBox(height: 4),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: () => onOpenSession(url),
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Ouvrir la session'),
                ),
                IconButton(
                  onPressed: () => onCopyLink(url),
                  icon: const Icon(Icons.link),
                  tooltip: 'Copier le lien',
                ),
              ],
            ),
            const TicketInfoLine(
              'Visible seulement depuis le compte Claude de '
              'l\'administrateur.',
            ),
          ],
          // L'application ne sait pas arrêter une session : la routine
          // n'offre que le lancement.
          if (launch.outcome == TicketLaunchOutcome.launched)
            const TicketInfoLine(
              'Pour l\'arrêter, ouvrez-la sur claude.ai/code.',
            ),
        ],
      ),
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

/// Ce que la boîte « Répondre à l'analyse » rend en se fermant (`null` :
/// annulée avant l'envoi).
enum _AnswerDialogResult {
  answered,

  /// Fermée par « Fermer » pendant l'envoi : l'appel continue, et l'appelant
  /// en attend le résultat.
  detached,
}

/// Boîte « Répondre à l'analyse » : la réponse part sur GitHub, dépôt public,
/// sous la dernière analyse, et le ticket repasse à Reçu.
///
/// Reste ouverte sur un refus du serveur ou une panne, texte gardé. Pendant
/// l'envoi, « Fermer » (ou le retour, ou Échap) la ferme sans couper l'appel :
/// l'appelant en affiche le résultat.
class _AnswerTicketDialog extends StatefulWidget {
  final TextEditingController controller;

  /// Réponse déjà publiée lors d'un échec partiel : le texte ne change plus.
  final bool locked;
  final VoidCallback onLocked;

  /// Date de la dernière analyse, pour le sous-titre, ou `null`.
  final DateTime? analysisAt;

  /// Ticket Validé : la réponse retire la validation.
  final bool validated;
  final Future<String> Function(String text) submit;

  const _AnswerTicketDialog({
    required this.controller,
    required this.locked,
    required this.onLocked,
    required this.analysisAt,
    required this.validated,
    required this.submit,
  });

  @override
  State<_AnswerTicketDialog> createState() => _AnswerTicketDialogState();
}

class _AnswerTicketDialogState extends State<_AnswerTicketDialog> {
  final _focus = FocusNode();
  bool _sending = false;
  String? _fieldError;
  String? _error;
  late bool _locked = widget.locked;

  /// La boîte a déjà demandé sa fermeture : un second `pop` fermerait la
  /// fiche (« Fermer » et la réponse arrivés dans la même image).
  bool _closing = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  void _close(_AnswerDialogResult? result) {
    if (_closing || !mounted) return;
    _closing = true;
    Navigator.of(context).pop(result);
  }

  void _detach() => _close(_AnswerDialogResult.detached);

  void _showFieldError(String message) {
    setState(() {
      _fieldError = message;
      _sending = false;
    });
    // Le champ est encore désactivé tant que l'image suivante n'est pas
    // construite : le focus se pose après elle.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  Future<void> _submit() async {
    final text = widget.controller.text;
    final fieldError = ticketAnswerFieldError(text);
    if (fieldError != null) {
      _showFieldError(fieldError);
      return;
    }
    setState(() {
      _fieldError = null;
      _error = null;
      _sending = true;
    });
    try {
      await widget.submit(text.trim());
      _close(_AnswerDialogResult.answered);
    } on TicketDecisionError catch (e) {
      // Déjà remontée par `TicketRepository` (feature `tickets`).
      if (!mounted || _closing) return;
      if (e.field == 'answer') {
        _showFieldError(e.message);
      } else {
        setState(() {
          _error = e.message;
          _sending = false;
          if (e.partial) _locked = true;
        });
        if (e.partial) widget.onLocked();
      }
    } catch (e) {
      // Déjà remontée par `TicketRepository` (feature `tickets`).
      if (!mounted || _closing) return;
      setState(() {
        _error =
            'Réponse non publiée : ${shortErrorMessage(e)} Votre texte est '
            'gardé.';
        _sending = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final muted = textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant);
    final error = _error;
    final analysisAt = widget.analysisAt;
    return PopScope(
      canPop: !_sending,
      // Le retour (ou Échap) pendant l'envoi vaut « Fermer ».
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _sending) _detach();
      },
      child: AlertDialog(
        scrollable: true,
        title: const Text('Répondre à l\'analyse'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (analysisAt != null) ...[
              Text(
                'Analyse du ${formatTicketDateTime(analysisAt)}',
                style: muted,
              ),
              const SizedBox(height: 12),
            ],
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ExcludeSemantics(
                    child: Icon(Icons.public, color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Publié sur GitHub, dépôt public. N\'y mettez ni '
                          'nom, ni e-mail, ni donnée privée.',
                          style: muted,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Le ticket repassera à « Reçu ». Relancez ensuite '
                          'l\'analyse pour qu\'elle lise votre réponse.',
                          style: muted,
                        ),
                        if (widget.validated) ...[
                          const SizedBox(height: 8),
                          Text('La validation sera retirée.', style: muted),
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
              focusNode: _focus,
              enabled: !_sending,
              readOnly: _locked,
              autofocus: true,
              minLines: 4,
              maxLines: 10,
              maxLength: kTicketAnswerMaxChars,
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                labelText: 'Votre réponse',
                helperText: 'Répondez aux questions de l\'analyse.',
                helperMaxLines: 3,
                errorText: _fieldError,
                errorMaxLines: 3,
              ),
            ),
            if (_locked && error == null) ...[
              const SizedBox(height: 8),
              Text(
                'Cette réponse est déjà publiée sur GitHub. Publier remet le '
                'ticket à Reçu.',
                style: muted,
              ),
            ],
            if (_sending) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(
                  'Publication en cours. Vous pouvez fermer : le résultat '
                  's\'affichera dans un message.',
                  style: muted,
                ),
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Text(error, style: TextStyle(color: cs.error)),
              ),
            ],
          ],
        ),
        actions: [
          // Avant l'appui sur « Publier », rien n'est appelé. Pendant
          // l'envoi, « Fermer » laisse l'appel aller à son terme.
          TextButton(
            onPressed: _sending ? _detach : () => _close(null),
            child: Text(_sending ? 'Fermer' : 'Annuler'),
          ),
          FilledButton(
            onPressed: _sending ? null : _submit,
            child: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Publier'),
          ),
        ],
      ),
    );
  }
}

/// Section « Livraison (N) » de la fiche : les comptes rendus
/// « ## Livraison — blocage » et « ## Livraison — terminée » publiés par la
/// session de livraison, dans l'ordre chronologique.
class _DeliverySection extends ConsumerWidget {
  final Ticket ticket;
  final Future<void> Function(String url) onOpenGithub;

  const _DeliverySection({required this.ticket, required this.onOpenGithub});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return ref
        .watch(ticketDeliveryProvider(ticket.id))
        .when(
          skipLoadingOnRefresh: false,
          loading: () => ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 120),
            child: const AppLoadingState(label: 'Chargement de la livraison…'),
          ),
          error: (error, _) => AppErrorState(
            error: error,
            compact: true,
            title: 'Impossible de charger la livraison.',
            onRetry: () => ref.invalidate(ticketDeliveryProvider(ticket.id)),
          ),
          data: (delivery) {
            final reports = delivery?.reports ?? const <TicketDeliveryReport>[];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Livraison (${reports.length})',
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                if (reports.isEmpty)
                  const TicketInfoLine('Aucun compte rendu de livraison.')
                else
                  for (final (i, r) in reports.indexed) ...[
                    if (i > 0) const SizedBox(height: 12),
                    _DeliveryReportCard(
                      report: r,
                      githubUrl: ticket.githubUrl,
                      onOpenGithub: onOpenGithub,
                    ),
                  ],
              ],
            );
          },
        );
  }
}

class _DeliveryReportCard extends StatelessWidget {
  final TicketDeliveryReport report;
  final String? githubUrl;
  final Future<void> Function(String url) onOpenGithub;

  const _DeliveryReportCard({
    required this.report,
    required this.githubUrl,
    required this.onOpenGithub,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final blocked = report.kind == TicketDeliveryReportKind.blocked;
    final fg = blocked ? cs.onErrorContainer : null;
    final at = report.createdAt;
    final title = blocked
        ? (at == null ? 'Blocage' : 'Blocage du ${formatTicketDateTime(at)}')
        : (at == null
              ? 'Livraison terminée'
              : 'Livraison terminée le ${formatTicketDateTime(at)}');
    final url = githubUrl;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: blocked ? cs.errorContainer : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Icon(
                  blocked ? Icons.error_outline : Icons.check_circle_outline,
                  size: 20,
                  color: fg ?? cs.primary,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: theme.textTheme.labelLarge?.copyWith(color: fg),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          MarkdownBody(
            data: ticketDeliveryReportDisplayBody(report.body),
            selectable: true,
            extensionSet: md.ExtensionSet.gitHubFlavored,
            styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
              p: theme.textTheme.bodyMedium?.copyWith(height: 1.5, color: fg),
              listBullet: theme.textTheme.bodyMedium?.copyWith(
                height: 1.5,
                color: fg,
              ),
            ),
            onTapLink: (_, href, _) {
              final uri = openableAnalysisLink(href);
              if (uri != null) onOpenGithub(uri.toString());
            },
            // Aucune image n'est chargée, comme dans les analyses.
            imageBuilder: (_, _, alt) => Text(
              ticketAnalysisImagePlaceholder(alt),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontStyle: FontStyle.italic,
                color: fg ?? cs.onSurfaceVariant,
              ),
            ),
          ),
          if (report.truncated) ...[
            const SizedBox(height: 8),
            const TicketInfoLine('Compte rendu tronqué, voir GitHub.'),
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

/// Section « Analyses (N) » de la fiche : les analyses du mainteneur
/// relevées sur l'Issue, en Markdown, dans l'ordre chronologique, et les
/// réponses de l'administrateur intercalées à leur date. N compte les
/// analyses seules.
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
          // Hauteur minimale, pas fixe : à 200 % le libellé passe sur deux
          // lignes et déborderait d'une boîte de 120 px.
          loading: () => ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 120),
            child: const AppLoadingState(label: 'Chargement des analyses…'),
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
                  'Analyses (${doc?.analysisCount ?? 0})',
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
    final isReply = analysis.kind == TicketAnalysisKind.reply;
    // Une réponse de l'administrateur se distingue d'une analyse par sa
    // couleur et son icône ; son texte suit la couleur de son fond.
    final fg = isReply ? cs.onSecondaryContainer : cs.onSurface;
    final Widget header;
    if (isReply) {
      header = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(child: Icon(Icons.reply, size: 20, color: fg)),
          const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                created == null
                    ? 'Votre réponse'
                    : 'Votre réponse du ${formatTicketDateTime(created)}',
                style: theme.textTheme.labelLarge?.copyWith(color: fg),
              ),
            ),
          ),
        ],
      );
    } else {
      final unverified = analysis.kind == TicketAnalysisKind.unverifiedReply;
      final title = Semantics(
        header: true,
        child: Text(
          unverified
              ? (created == null
                    ? 'Précisions'
                    : 'Précisions du ${formatTicketDateTime(created)}')
              : (created == null
                    ? 'Analyse'
                    : 'Analyse du ${formatTicketDateTime(created)}'),
          style: theme.textTheme.labelLarge,
        ),
      );
      // Une `## Précisions…` que l'application n'a pas publiée (une session
      // signe comme le même compte) ne se présente pas comme votre réponse.
      header = unverified
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                title,
                const TicketInfoLine('Non publiée depuis l\'application.'),
              ],
            )
          : title;
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isReply ? cs.secondaryContainer : cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          header,
          const SizedBox(height: 8),
          MarkdownBody(
            data: ticketAnalysisDisplayBody(analysis.body),
            selectable: true,
            extensionSet: md.ExtensionSet.gitHubFlavored,
            styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
              h1: theme.textTheme.titleLarge?.copyWith(color: fg),
              h2: theme.textTheme.titleMedium?.copyWith(color: fg),
              h3: theme.textTheme.titleSmall?.copyWith(color: fg),
              h4: theme.textTheme.titleSmall?.copyWith(color: fg),
              h5: theme.textTheme.bodyMedium?.copyWith(color: fg),
              h6: theme.textTheme.bodyMedium?.copyWith(color: fg),
              strong: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: fg,
              ),
              em: theme.textTheme.bodyMedium?.copyWith(
                fontStyle: FontStyle.italic,
                color: fg,
              ),
              code: MarkdownStyleSheet.fromTheme(
                theme,
              ).code?.copyWith(color: fg),
              blockquoteDecoration: BoxDecoration(
                color: cs.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(4),
              ),
              a: theme.textTheme.bodyMedium?.copyWith(
                decoration: TextDecoration.underline,
                color: fg,
              ),
              tableHead: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: fg,
              ),
              tableBody: theme.textTheme.bodyMedium?.copyWith(color: fg),
              p: theme.textTheme.bodyMedium?.copyWith(height: 1.5, color: fg),
              listBullet: theme.textTheme.bodyMedium?.copyWith(
                height: 1.5,
                color: fg,
              ),
              blockquote: theme.textTheme.bodyMedium?.copyWith(
                fontStyle: FontStyle.italic,
                color: fg,
              ),
            ),
            onTapLink: (_, href, _) => _openLink(context, href),
            // Aucune image n'est chargée : une adresse tierce verrait passer
            // l'administrateur, et le texte suffit à l'analyse.
            imageBuilder: (_, _, alt) => Text(
              ticketAnalysisImagePlaceholder(alt),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontStyle: FontStyle.italic,
                color: fg,
              ),
            ),
          ),
          if (analysis.truncated) ...[
            const SizedBox(height: 8),
            TicketInfoLine(
              isReply
                  ? 'Réponse tronquée, voir GitHub.'
                  : 'Analyse tronquée, voir GitHub.',
            ),
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
