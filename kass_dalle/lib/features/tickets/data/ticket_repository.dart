import 'dart:async';
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart' show kIsWeb;

import '../../../core/services/error_report_service.dart';
import '../../../core/services/error_reporting.dart';
import '../../../core/services/gemini_service.dart';
import '../../../core/utils/platform_utils.dart';
import '../domain/ticket.dart';
import '../domain/ticket_analysis.dart';
import '../domain/ticket_form.dart';
import '../domain/ticket_launch.dart';

/// Lecture des tickets, envoi d'un ticket et de sa capture.
///
/// Les tickets s'écrivent par les Cloud Functions seules. Le client lit les
/// siens (l'administrateur, tous), appelle `submitTicket`, envoie la capture
/// sur `tickets/{uid}/{ticketId}/…` puis la rattache par
/// `attachTicketScreenshot`, et note `seen_by_author_at` à l'ouverture du
/// détail — la seule écriture que les règles lui laissent.
class TicketRepository {
  final FirebaseFirestore _db;
  final FirebaseStorage? _storageOverride;
  final GeminiService _callables;
  final ErrorReportService _errorReportService;

  static const collection = 'tickets';
  static const _feature = 'tickets';

  TicketRepository({
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
    GeminiService? callables,
    ErrorReportService? errorReportService,
  }) : _db = firestore ?? FirebaseFirestore.instance,
       _storageOverride = storage,
       _callables = callables ?? GeminiService(),
       _errorReportService =
           errorReportService ?? ErrorReportService(firestore: firestore);

  /// Résolu au premier usage : les tests qui ne touchent pas Storage
  /// construisent le repository sans application Firebase.
  FirebaseStorage get _storage => _storageOverride ?? FirebaseStorage.instance;

  CollectionReference<Map<String, dynamic>> get _col =>
      _db.collection(collection);

  // ── Lecture ─────────────────────────────────────────────────────────────────

  /// Les tickets de [uid], du plus récent au plus ancien.
  ///
  /// Tri côté client : un `orderBy` sur `created_at` après le filtre par
  /// auteur exigerait un index composite, pour une liste de quelques dizaines
  /// de documents.
  Stream<List<Ticket>> watchMyTickets(String uid) {
    return _reported(
      _col.where('author_uid', isEqualTo: uid).snapshots().map(_sortedTickets),
      step: 'watch_my_tickets',
    );
  }

  /// Les tickets de toute la famille, du plus récent au plus ancien
  /// (administrateur). Les filtres de l'écran s'appliquent côté client.
  Stream<List<Ticket>> watchAllTickets({int limit = 300}) {
    return _reported(
      _col
          .orderBy('created_at', descending: true)
          .limit(limit)
          .snapshots()
          .map(_sortedTickets),
      step: 'watch_all_tickets',
    );
  }

  /// Nombre de tickets en anomalie, pour le badge d'Administration.
  ///
  /// Un ticket en anomalie est encore `sending` : le filtre d'égalité ne
  /// demande aucun index, le seuil d'essais se lit sur les documents rendus.
  Stream<int> watchAnomalyCount() {
    return _reported(
      _col
          .where('status', isEqualTo: TicketStatus.sending.value)
          .snapshots()
          .map(
            (snap) => snap.docs
                .map((d) => Ticket.fromMap(d.id, d.data()))
                .where((t) => t.isInAnomaly)
                .length,
          ),
      step: 'watch_anomaly_count',
    );
  }

  /// Nombre de tickets à traiter (Reçus ou Analysés) : pastille du compte,
  /// entrée « Tickets à traiter » et puce « À traiter » (administrateur).
  Stream<int> watchToProcessCount() {
    return _reported(
      _col
          .where(
            'status',
            whereIn: [for (final s in kAdminTicketToProcessStatuses) s.value],
          )
          .snapshots()
          .map((snap) => snap.size),
      step: 'watch_to_process_count',
    );
  }

  /// Les analyses relevées sur l'Issue de [ticketId]
  /// (`tickets/{ticketId}/admin/analysis`), ou `null` tant qu'aucun relevé
  /// n'a eu lieu. Lisible par l'administrateur seul.
  Stream<TicketAnalysisDoc?> watchAnalysis(String ticketId) {
    return _reported(
      _col.doc(ticketId).collection('admin').doc('analysis').snapshots().map((
        snap,
      ) {
        final data = snap.data();
        return snap.exists && data != null
            ? TicketAnalysisDoc.fromMap(data)
            : null;
      }),
      step: 'watch_analysis',
    );
  }

  /// L'historique des lancements de sessions de [ticketId]
  /// (`tickets/{ticketId}/admin/launches`), plus récent en tête ; liste vide
  /// tant qu'aucun lancement n'a eu lieu. Lisible par l'administrateur seul.
  Stream<List<TicketLaunch>> watchLaunches(String ticketId) {
    return _reported(
      _col
          .doc(ticketId)
          .collection('admin')
          .doc('launches')
          .snapshots()
          .map((snap) => ticketLaunchesFromDoc(snap.data())),
      step: 'watch_launches',
    );
  }

  /// `app_config/tickets_status` : jetons refusés (GitHub, routines) et
  /// compteurs des lancements. Lisible par l'administrateur seul.
  Stream<TicketsStatus> watchStatus() {
    return _reported(
      _db
          .collection('app_config')
          .doc('tickets_status')
          .snapshots()
          .map((snap) => TicketsStatus.fromMap(snap.data())),
      step: 'watch_tickets_status',
    );
  }

  /// Le plafond quotidien des lancements de sessions
  /// (`app_config/tickets.launches_per_day`).
  ///
  /// Document ou champ absent : [kTicketDefaultLaunchesPerDay], le réglage
  /// par défaut du serveur, verrouillé par la fixture
  /// `ticket_decisions.json`. Champ présent mais pas un entier de 1 à
  /// [kTicketMaxLaunchesPerDay] : le serveur refuse tout lancement ; `null` (« inconnu ») et
  /// rapport d'erreur. Une lecture refusée rend aussi `null`.
  Future<int?> fetchLaunchesPerDay() async {
    try {
      final snap = await _db.collection('app_config').doc('tickets').get();
      final data = snap.data();
      if (!snap.exists || data == null) return kTicketDefaultLaunchesPerDay;
      if (!data.containsKey('launches_per_day')) {
        return kTicketDefaultLaunchesPerDay;
      }
      final raw = data['launches_per_day'];
      if (raw is int && raw > 0 && raw <= kTicketMaxLaunchesPerDay) return raw;
      if (raw is double &&
          raw > 0 &&
          raw <= kTicketMaxLaunchesPerDay &&
          raw == raw.truncateToDouble()) {
        return raw.toInt();
      }
      await _errorReportService.reportError(
        feature: _feature,
        error: FormatException(
          'app_config/tickets.launches_per_day illisible',
          '$raw',
        ),
        context: {'step': 'fetch_launches_per_day'},
      );
      return null;
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: _feature,
        error: e,
        stackTrace: st,
        context: {'step': 'fetch_launches_per_day'},
      );
      return null;
    }
  }

  /// Le plafond quotidien d'un membre (`app_config/tickets`,
  /// `per_member_per_day`), quand le document le règle.
  ///
  /// Document ou champ absent : `null`, sans rapport — le serveur applique
  /// alors son réglage par défaut, que le client ne recopie pas (pas de
  /// logique dupliquée) ; le formulaire se rabat sur `remaining_today` du
  /// dernier envoi. Champ présent mais pas un entier strictement positif : le
  /// serveur refuse tout envoi ; `null`, remonté par un rapport d'erreur. Une
  /// lecture refusée rend aussi `null`.
  Future<int?> fetchPerMemberDailyLimit() async {
    try {
      final snap = await _db.collection('app_config').doc('tickets').get();
      final data = snap.data();
      if (!snap.exists || data == null) return null;
      if (!data.containsKey('per_member_per_day')) return null;
      final raw = data['per_member_per_day'];
      if (raw is int && raw > 0) return raw;
      if (raw is double && raw > 0 && raw == raw.truncateToDouble()) {
        return raw.toInt();
      }
      await _errorReportService.reportError(
        feature: _feature,
        error: FormatException(
          'app_config/tickets.per_member_per_day illisible',
          '$raw',
        ),
        context: {'step': 'fetch_limits'},
      );
      return null;
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: _feature,
        error: e,
        stackTrace: st,
        context: {'step': 'fetch_limits'},
      );
      return null;
    }
  }

  /// Les octets de la capture rangée sous [path].
  Future<Uint8List> loadScreenshot(String path) async {
    try {
      final data = await _storage.ref(path).getData(kTicketScreenshotMaxBytes);
      if (data == null) {
        throw StateError('Capture vide : $path');
      }
      return data;
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: _feature,
        error: e,
        stackTrace: st,
        context: {'step': 'load_screenshot', 'path': path},
      );
      rethrow;
    }
  }

  // ── Écriture ────────────────────────────────────────────────────────────────

  /// Envoie un ticket, puis sa capture s'il y en a une.
  ///
  /// Lève un [TicketSubmitError] quand le ticket n'est pas créé. Une capture
  /// qui ne part pas ne fait pas échouer l'envoi : le ticket existe déjà, le
  /// résultat le signale par [TicketSubmitResult.screenshotFailed].
  Future<TicketSubmitResult> submit({
    required String uid,
    required TicketType type,
    required String title,
    required String description,
    required String screen,
    required String appVersion,
    required String platform,
    TicketScreenshot? screenshot,
  }) async {
    final payload = <String, dynamic>{
      'type': type.value,
      'title': title.trim(),
      'description': description.trim(),
      'screen': screen,
      'app_version': appVersion,
      'platform': platform,
    };
    final TicketSubmitResult result;
    try {
      result = TicketSubmitResult.fromMap(
        await _callables.submitTicket(payload),
      );
    } on GeminiCallableException catch (e, st) {
      final error = ticketSubmitErrorFrom(
        code: callableErrorCode(e),
        message: e.message,
        details: e.details,
      );
      // Un plafond atteint est une réponse attendue, pas une panne.
      if (error is! TicketMemberLimitReached &&
          error is! TicketGlobalLimitReached) {
        await _errorReportService.reportError(
          userId: uid,
          feature: _feature,
          error: e,
          stackTrace: st,
          context: {'step': 'submit', 'code': e.code, 'type': type.value},
        );
      }
      throw error;
    } catch (e, st) {
      await _errorReportService.reportError(
        userId: uid,
        feature: _feature,
        error: e,
        stackTrace: st,
        context: {'step': 'submit', 'type': type.value},
      );
      // Hors réponse du serveur : coupure réseau, délai, réponse illisible.
      throw const TicketNetworkError();
    }

    if (screenshot == null) return result;
    final path = ticketScreenshotPath(
      uid: uid,
      ticketId: result.ticketId,
      extension: screenshot.extension,
    );
    try {
      await _storage
          .ref(path)
          .putData(
            screenshot.bytes,
            SettableMetadata(contentType: screenshot.contentType),
          );
      await _callables.attachTicketScreenshot(
        ticketId: result.ticketId,
        path: path,
      );
      return result;
    } catch (e, st) {
      await _errorReportService.reportError(
        userId: uid,
        feature: _feature,
        error: e,
        stackTrace: st,
        context: {
          'step': 'attach_screenshot',
          'ticket_id': result.ticketId,
          'bytes': screenshot.bytes.length,
        },
      );
      return result.withScreenshotFailed();
    }
  }

  /// Note que l'auteur a vu le dernier statut de [ticketId].
  ///
  /// L'horodatage est celui du serveur : la règle exige `request.time`.
  /// Au mieux : un échec est remonté, et le point de notification reste
  /// allumé jusqu'à la prochaine ouverture.
  Future<void> markSeen(String ticketId) async {
    try {
      await _col.doc(ticketId).update({
        'seen_by_author_at': FieldValue.serverTimestamp(),
      });
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: _feature,
        error: e,
        stackTrace: st,
        context: {'step': 'mark_seen', 'ticket_id': ticketId},
      );
    }
  }

  /// Relance l'envoi d'un ticket en anomalie. Rend le statut obtenu.
  Future<String> retrySend(String ticketId) async {
    try {
      return await _callables.retryTicketSend(ticketId);
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: _feature,
        error: e,
        stackTrace: st,
        context: {'step': 'retry_send', 'ticket_id': ticketId},
      );
      rethrow;
    }
  }

  /// Valide [ticketId] (administrateur). Lève [TicketDecisionError] pour un
  /// refus du serveur ; toute autre erreur est relancée telle quelle.
  Future<String> validate(String ticketId) {
    return _decide(
      step: 'validate',
      ticketId: ticketId,
      call: () => _callables.validateTicket(ticketId),
    );
  }

  /// Refuse [ticketId] avec [reason] (administrateur). Lève
  /// [TicketDecisionError] pour un refus du serveur, échec partiel compris ;
  /// toute autre erreur est relancée telle quelle.
  Future<String> refuse(String ticketId, String reason) {
    return _decide(
      step: 'refuse',
      ticketId: ticketId,
      call: () => _callables.refuseTicket(ticketId, reason.trim()),
    );
  }

  /// Lance la routine [action] sur [ticketId] (administrateur).
  ///
  /// Lève [TicketLaunchError] pour un refus du serveur (rien n'a été lancé) ;
  /// toute autre erreur est relancée telle quelle : la réponse s'est perdue,
  /// et rien ne dit si la session est partie.
  Future<TicketLaunchResult> launch(
    String ticketId,
    TicketLaunchAction action,
  ) async {
    final step = 'launch_${action.value}';
    try {
      final data = switch (action) {
        TicketLaunchAction.analysis => await _callables.launchTicketAnalysis(
          ticketId,
        ),
        TicketLaunchAction.development =>
          await _callables.launchTicketDevelopment(ticketId),
      };
      return TicketLaunchResult.fromMap(data);
    } on GeminiCallableException catch (e, st) {
      await _errorReportService.reportError(
        feature: _feature,
        error: e,
        stackTrace: st,
        context: {'step': step, 'ticket_id': ticketId, 'code': e.code},
      );
      final known = ticketDecisionErrorFrom(
        message: e.message,
        details: e.details,
      );
      if (known != null) throw TicketLaunchError(known.message);
      rethrow;
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: _feature,
        error: e,
        stackTrace: st,
        context: {'step': step, 'ticket_id': ticketId},
      );
      rethrow;
    }
  }

  Future<String> _decide({
    required String step,
    required String ticketId,
    required Future<String> Function() call,
  }) async {
    try {
      return await call();
    } on GeminiCallableException catch (e, st) {
      await _errorReportService.reportError(
        feature: _feature,
        error: e,
        stackTrace: st,
        context: {'step': step, 'ticket_id': ticketId, 'code': e.code},
      );
      final known = ticketDecisionErrorFrom(
        message: e.message,
        details: e.details,
      );
      if (known != null) throw known;
      rethrow;
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: _feature,
        error: e,
        stackTrace: st,
        context: {'step': step, 'ticket_id': ticketId},
      );
      rethrow;
    }
  }

  // ── Outils ──────────────────────────────────────────────────────────────────

  List<Ticket> _sortedTickets(QuerySnapshot<Map<String, dynamic>> snap) {
    final list = snap.docs.map((d) => Ticket.fromMap(d.id, d.data())).toList();
    // Un ticket sans horodatage vient d'être écrit : il passe en tête.
    final far = DateTime.utc(9999);
    list.sort((a, b) => (b.createdAt ?? far).compareTo(a.createdAt ?? far));
    return list;
  }

  /// Remonte l'erreur d'un flux avant de la laisser à l'écran.
  Stream<T> _reported<T>(Stream<T> source, {required String step}) {
    return source.transform(
      StreamTransformer<T, T>.fromHandlers(
        handleError: (error, stackTrace, sink) {
          reportUnexpectedError(
            service: _errorReportService,
            feature: _feature,
            error: error,
            stackTrace: stackTrace,
            context: {'step': step},
          );
          sink.addError(error, stackTrace);
        },
      ),
    );
  }
}

/// La plateforme de l'application, telle que `submitTicket` l'attend, ou
/// `null` hors des quatre plateformes servies (macOS, Linux de développement).
String? currentTicketPlatform() {
  if (kIsWeb) return 'web';
  if (PlatformUtils.isAndroidApp) return 'android';
  if (PlatformUtils.isWindowsApp) return 'windows';
  if (PlatformUtils.isMobile) return 'ios';
  return null;
}
