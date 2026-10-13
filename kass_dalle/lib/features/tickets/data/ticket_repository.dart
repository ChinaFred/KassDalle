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
import '../domain/ticket_form.dart';

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

  /// Depuis quand le jeton GitHub est refusé (`app_config/tickets_status`),
  /// ou `null` s'il fonctionne. Lisible par l'administrateur seul.
  Stream<DateTime?> watchTokenInvalidSince() {
    return _reported(
      _db
          .collection('app_config')
          .doc('tickets_status')
          .snapshots()
          .map((snap) => parseTicketDate(snap.data()?['token_invalid_since'])),
      step: 'watch_token_status',
    );
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
