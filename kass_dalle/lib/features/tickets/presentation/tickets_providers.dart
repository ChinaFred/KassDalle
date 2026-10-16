import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/gemini_providers.dart';
import '../../auth/presentation/auth_providers.dart';
import '../data/ticket_repository.dart';
import '../domain/ticket.dart';
import '../domain/ticket_analysis.dart';
import '../domain/ticket_delivery.dart';
import '../domain/ticket_form.dart';
import '../domain/ticket_launch.dart';

final ticketRepositoryProvider = Provider<TicketRepository>((ref) {
  return TicketRepository(callables: ref.watch(geminiServiceProvider));
});

// ── Côté membre ─────────────────────────────────────────────────────────────

/// Les tickets du compte connecté, du plus récent au plus ancien.
final myTicketsProvider = StreamProvider<List<Ticket>>((ref) {
  final user = ref.watch(appUserProvider).value;
  // Les règles refusent la lecture à un compte en attente ou révoqué.
  if (user == null || !user.canRead) return Stream.value(const []);
  return ref.watch(ticketRepositoryProvider).watchMyTickets(user.uid);
});

/// Un ticket du compte connecté, lu dans [myTicketsProvider] : `null` s'il
/// n'en fait pas partie (supprimé, ou d'un autre compte).
final myTicketProvider = Provider.family<AsyncValue<Ticket?>, String>((
  ref,
  ticketId,
) {
  return ref.watch(myTicketsProvider).whenData((tickets) {
    for (final t in tickets) {
      if (t.id == ticketId) return t;
    }
    return null;
  });
});

/// Tickets de l'utilisateur dont le statut a changé depuis sa dernière
/// ouverture (ou jamais ouverts), hors « Envoi en cours » : la pastille de
/// « Mes tickets ».
final unseenTicketsCountProvider = Provider<int>((ref) {
  final tickets = ref.watch(myTicketsProvider).value ?? const <Ticket>[];
  return tickets.where((t) => t.hasUnseenUpdate).length;
});

/// Le plafond quotidien d'un membre, lu dans `app_config/tickets` ; `null`
/// pour l'administrateur, qui n'en a pas, et quand il ne se lit pas.
final ticketMemberDailyLimitProvider = FutureProvider.autoDispose<int?>((
  ref,
) async {
  final user = ref.watch(appUserProvider).value;
  if (user == null || user.isAdmin || !user.canRead) return null;
  return ref.watch(ticketRepositoryProvider).fetchPerMemberDailyLimit();
});

/// `remaining_today` du dernier envoi, avec son jour de Paris.
class LastTicketRemainingNotifier extends Notifier<TicketServerRemaining?> {
  @override
  TicketServerRemaining? build() => null;

  void record(int? remaining, DateTime now) {
    state = remaining == null
        ? null
        : (day: parisDayKey(now), remaining: remaining);
  }
}

final lastTicketRemainingProvider =
    NotifierProvider<LastTicketRemainingNotifier, TicketServerRemaining?>(
      LastTicketRemainingNotifier.new,
    );

/// Les envois qui restent aujourd'hui au membre, ou `null` (administrateur,
/// ou rien pour le dire). Voir [remainingTicketsToday].
final remainingTicketsTodayProvider = Provider.autoDispose<int?>((ref) {
  if (ref.watch(isAdminProvider)) return null;
  final mine = ref.watch(myTicketsProvider).value;
  if (mine == null) return null;
  return remainingTicketsToday(
    perMemberPerDay: ref.watch(ticketMemberDailyLimitProvider).value,
    myTickets: mine,
    now: DateTime.now(),
    lastServerRemaining: ref.watch(lastTicketRemainingProvider),
  );
});

/// Image de l'écran prise par le shell à l'appui sur « Signaler ou
/// proposer », en attente du formulaire qui la reprend.
class PendingTicketCaptureNotifier extends Notifier<Uint8List?> {
  @override
  Uint8List? build() => null;

  void set(Uint8List? bytes) => state = bytes;

  /// Rend l'image et l'oublie : un second formulaire ne la reprend pas.
  Uint8List? take() {
    final bytes = state;
    state = null;
    return bytes;
  }
}

final pendingTicketCaptureProvider =
    NotifierProvider<PendingTicketCaptureNotifier, Uint8List?>(
      PendingTicketCaptureNotifier.new,
    );

/// Les octets d'une capture, par chemin Storage.
final ticketScreenshotProvider = FutureProvider.autoDispose
    .family<Uint8List, String>((ref, path) {
      return ref.watch(ticketRepositoryProvider).loadScreenshot(path);
    });

// ── Côté administrateur ─────────────────────────────────────────────────────

/// Tous les tickets, pour Admin › Tickets des membres.
final adminTicketsProvider = StreamProvider<List<Ticket>>((ref) {
  if (!ref.watch(isAdminProvider)) return Stream.value(const []);
  return ref.watch(ticketRepositoryProvider).watchAllTickets();
});

/// Un ticket de la famille, lu dans [adminTicketsProvider].
final adminTicketProvider = Provider.family<AsyncValue<Ticket?>, String>((
  ref,
  ticketId,
) {
  return ref.watch(adminTicketsProvider).whenData((tickets) {
    for (final t in tickets) {
      if (t.id == ticketId) return t;
    }
    return null;
  });
});

/// Nombre de tickets en anomalie : badge de la tuile d'Administration.
/// Zéro hors administrateur, que les règles empêchent de lire.
final ticketAnomalyCountProvider = StreamProvider<int>((ref) {
  if (!ref.watch(isAdminProvider)) return Stream.value(0);
  return ref.watch(ticketRepositoryProvider).watchAnomalyCount();
});

/// Identifiants des tickets à traiter (Reçus, Analysés ou Validés). Vide, sans
/// requête, hors administrateur.
final adminTicketsToProcessIdsProvider = StreamProvider<Set<String>>((ref) {
  if (!ref.watch(isAdminProvider)) return Stream.value(const <String>{});
  return ref.watch(ticketRepositoryProvider).watchToProcessIds();
});

/// Nombre de tickets à traiter : entrée « Tickets à traiter » du menu et
/// puce « À traiter ».
final adminTicketsToProcessCountProvider = Provider<AsyncValue<int>>((ref) {
  return ref.watch(adminTicketsToProcessIdsProvider).whenData((s) => s.length);
});

/// Tickets à signaler sur la puce du compte. Administrateur : les tickets à
/// traiter seuls. Autres rôles : ceux de l'utilisateur avec un suivi non lu.
final accountTicketsBadgeCountProvider = Provider<int>((ref) {
  if (ref.watch(isAdminProvider)) {
    return (ref.watch(adminTicketsToProcessIdsProvider).value ??
            const <String>{})
        .length;
  }
  return ref.watch(unseenTicketsCountProvider);
});

/// Les analyses d'un ticket (`tickets/{id}/admin/analysis`), en flux ;
/// `null` tant qu'aucun relevé n'a eu lieu.
final ticketAnalysisProvider = StreamProvider.autoDispose
    .family<TicketAnalysisDoc?, String>((ref, ticketId) {
      if (!ref.watch(isAdminProvider)) return Stream.value(null);
      return ref.watch(ticketRepositoryProvider).watchAnalysis(ticketId);
    });

/// L'historique des lancements de sessions d'un ticket
/// (`tickets/{id}/admin/launches`), en flux ; `null` hors administrateur.
final ticketLaunchesProvider = StreamProvider.autoDispose
    .family<List<TicketLaunch>?, String>((ref, ticketId) {
      if (!ref.watch(isAdminProvider)) return Stream.value(null);
      return ref.watch(ticketRepositoryProvider).watchLaunches(ticketId);
    });

/// L'état de livraison d'un ticket (`tickets/{id}/admin/delivery` : « PR
/// prête », comptes rendus), en flux ; `null` tant qu'il n'existe pas, ou hors
/// administrateur.
final ticketDeliveryProvider = StreamProvider.autoDispose
    .family<TicketDelivery?, String>((ref, ticketId) {
      if (!ref.watch(isAdminProvider)) return Stream.value(null);
      return ref.watch(ticketRepositoryProvider).watchDelivery(ticketId);
    });

/// `app_config/tickets_status` : jeton GitHub et jetons des routines
/// refusés, compteurs des lancements. `null` hors administrateur.
final ticketsStatusProvider = StreamProvider<TicketsStatus?>((ref) {
  if (!ref.watch(isAdminProvider)) return Stream.value(null);
  return ref.watch(ticketRepositoryProvider).watchStatus();
});

/// Plafond quotidien des lancements du compte connecté
/// (`app_config/tickets.launches_per_day`, 10 par défaut ; 50 pour le
/// fondateur, [ticketLaunchLimitFor]) ; `null` s'il ne se lit pas, ou hors
/// administrateur.
final ticketLaunchesPerDayProvider = FutureProvider.autoDispose<int?>((
  ref,
) async {
  if (!ref.watch(isAdminProvider)) return null;
  final isFounder = ref.watch(appUserProvider).value?.isFounder ?? false;
  final configured = await ref
      .watch(ticketRepositoryProvider)
      .fetchLaunchesPerDay();
  if (configured == null) return null;
  return ticketLaunchLimitFor(configured, isFounder: isFounder);
});

/// Filtre de statut de l'écran d'administration, voir
/// [kAdminTicketTodoFilter] et [kAdminTicketAnomalyFilter].
///
/// Global et sans `autoDispose` : sur grand écran, chaque ticket ouvert
/// reconstruit l'écran, et le filtre choisi doit survivre. Il n'est donc
/// jamais remis à zéro par l'écran : ce sont les points d'entrée (tuile
/// d'Administration, menu du compte) qui posent « À traiter » par
/// [enterToProcess] avant de naviguer.
class AdminTicketStatusFilterNotifier extends Notifier<String?> {
  bool _entryPending = false;

  @override
  String? build() => null;

  void set(String? value) {
    _entryPending = false;
    state = value;
  }

  /// Pose « À traiter » à l'entrée dans l'écran. Le premier compteur reçu
  /// ([settleEntry]) bascule sur « Tous » s'il n'y a rien à traiter.
  void enterToProcess() {
    _entryPending = true;
    state = kAdminTicketTodoFilter;
  }

  /// Une seule fois après [enterToProcess] : zéro ticket à traiter, et le
  /// filtre toujours sur « À traiter », bascule sur « Tous ».
  void settleEntry(int toProcessCount) {
    if (!_entryPending) return;
    _entryPending = false;
    if (toProcessCount == 0 && state == kAdminTicketTodoFilter) state = null;
  }
}

final adminTicketStatusFilterProvider =
    NotifierProvider<AdminTicketStatusFilterNotifier, String?>(
      AdminTicketStatusFilterNotifier.new,
    );

/// Filtre de type : `null` pour « Tous les types ».
class AdminTicketTypeFilterNotifier extends Notifier<TicketType?> {
  @override
  TicketType? build() => null;

  void set(TicketType? value) => state = value;
}

final adminTicketTypeFilterProvider =
    NotifierProvider<AdminTicketTypeFilterNotifier, TicketType?>(
      AdminTicketTypeFilterNotifier.new,
    );
