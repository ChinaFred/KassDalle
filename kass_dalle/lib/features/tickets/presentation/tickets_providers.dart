import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/gemini_providers.dart';
import '../../auth/presentation/auth_providers.dart';
import '../data/ticket_repository.dart';
import '../domain/ticket.dart';
import '../domain/ticket_form.dart';

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

/// Tickets arrivés à Répondu, Refusé ou Livré que leur auteur n'a pas
/// encore ouverts : le point sur la puce du compte.
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

/// Depuis quand le jeton GitHub est refusé, ou `null`.
final ticketsTokenInvalidSinceProvider = StreamProvider<DateTime?>((ref) {
  if (!ref.watch(isAdminProvider)) return Stream.value(null);
  return ref.watch(ticketRepositoryProvider).watchTokenInvalidSince();
});

/// Filtre de statut de l'écran d'administration, voir
/// [kAdminTicketAnomalyFilter].
class AdminTicketStatusFilterNotifier extends Notifier<String?> {
  @override
  String? build() => null;

  void set(String? value) => state = value;
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
