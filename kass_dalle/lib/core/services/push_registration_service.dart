import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../utils/platform_utils.dart';
import 'error_report_service.dart';

/// Type porté par la notification de nouvelle version
/// (`functions/src/release_notifications/notify.ts`).
const kApkReleaseMessageType = 'apk_release';

/// Le message est-il la notification de nouvelle version ?
bool isApkReleaseMessage(Map<String, dynamic> data) =>
    data['type'] == kApkReleaseMessageType;

/// Types des notifications de ticket
/// (`functions/src/tickets/pushRules.ts`) : analyse publiée, réponse attendue,
/// développement livré.
const kTicketMessageTypes = {
  'ticket_analyzed',
  'ticket_needs_reply',
  'ticket_delivered',
};

/// Identifiant du ticket porté par une notification de ticket, ou `null` si le
/// message n'en est pas une ou n'a pas d'identifiant exploitable.
String? ticketIdFromMessage(Map<String, dynamic> data) {
  if (!kTicketMessageTypes.contains(data['type'])) return null;
  final id = data['ticket_id'];
  return id is String && id.isNotEmpty ? id : null;
}

/// Document `users/{uid}/devices/{token}` : la forme que les règles Firestore
/// acceptent (`token`, `platform`, `updated_at`, rien d'autre).
Map<String, dynamic> deviceDocument(String token) => {
  'token': token,
  'platform': 'android',
  'updated_at': FieldValue.serverTimestamp(),
};

/// Enregistre l'appareil Android d'un administrateur pour la notification de
/// nouvelle version.
///
/// Le serveur décide du destinataire : il relit le rôle de chaque compte à
/// l'envoi. Ce service ne fait que déposer le jeton, et seulement pour un
/// administrateur sur Android. Ailleurs (web, iOS, Windows) il ne fait rien.
class PushRegistrationService {
  final FirebaseFirestore _firestore;
  final ErrorReportService _errorReportService;
  FirebaseMessaging? _messaging;

  StreamSubscription<String>? _refreshSub;
  StreamSubscription<RemoteMessage>? _openedSub;
  String? _token;

  PushRegistrationService({
    FirebaseFirestore? firestore,
    ErrorReportService? errorReportService,
    FirebaseMessaging? messaging,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _errorReportService = errorReportService ?? ErrorReportService(),
       _messaging = messaging;

  FirebaseMessaging get _fcm => _messaging ??= FirebaseMessaging.instance;

  DocumentReference<Map<String, dynamic>> _deviceRef(
    String uid,
    String token,
  ) => _firestore.collection('users').doc(uid).collection('devices').doc(token);

  /// Demande l'autorisation d'afficher des notifications (boîte du système
  /// sous Android 13 et plus, une seule fois) puis dépose le jeton.
  /// Permission refusée : rien n'est enregistré et rien ne s'affiche.
  Future<void> register(String uid) async {
    if (!PlatformUtils.isAndroidApp) return;
    try {
      final settings = await _fcm.requestPermission();
      if (settings.authorizationStatus != AuthorizationStatus.authorized) {
        return;
      }
      final token = await _fcm.getToken();
      if (token == null || token.isEmpty) return;
      _token = token;
      await _deviceRef(uid, token).set(deviceDocument(token));
      await _refreshSub?.cancel();
      _refreshSub = _fcm.onTokenRefresh.listen((fresh) async {
        try {
          final old = _token;
          _token = fresh;
          await _deviceRef(uid, fresh).set(deviceDocument(fresh));
          if (old != null && old != fresh) {
            await _deviceRef(uid, old).delete();
          }
        } catch (e, st) {
          await _errorReportService.reportError(
            feature: 'push.refresh_token',
            error: e,
            stackTrace: st,
          );
        }
      });
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'push.register',
        error: e,
        stackTrace: st,
        context: {'uid': uid},
      );
    }
  }

  /// Retire l'appareil, quand le compte reste connecté mais n'est plus
  /// administrateur. Le serveur ne lit de toute façon que les jetons des
  /// administrateurs : c'est un nettoyage, pas la protection.
  Future<void> unregister(String uid) async {
    await _refreshSub?.cancel();
    _refreshSub = null;
    final token = _token;
    _token = null;
    if (token == null) return;
    try {
      await _deviceRef(uid, token).delete();
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'push.unregister',
        error: e,
        stackTrace: st,
        context: {'uid': uid},
      );
    }
  }

  /// Retire de `users/{uid}/devices` le jeton de cet appareil, avant une
  /// déconnexion : sur un appareil partagé, un autre compte ne doit pas lire
  /// les notifications d'un administrateur. Un échec est signalé et n'empêche
  /// pas la déconnexion.
  Future<void> unregisterThisDevice(String uid) async {
    if (!PlatformUtils.isAndroidApp) return;
    try {
      final token = _token ?? await _fcm.getToken();
      if (token == null || token.isEmpty) return;
      await _deviceRef(uid, token).delete();
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'push.unregister_sign_out',
        error: e,
        stackTrace: st,
        context: {'uid': uid},
      );
    }
  }

  /// Appelle [onRelease] quand l'utilisateur touche la notification de
  /// nouvelle version, [onTicket] avec l'identifiant du ticket quand il touche
  /// une notification de ticket, alors que l'application tourne en arrière-plan.
  /// Un lancement à froid : [initialTicketId] pour un ticket, la vérification
  /// faite au démarrage pour une version.
  void listenForTaps({
    required void Function() onRelease,
    required void Function(String ticketId) onTicket,
  }) {
    if (!PlatformUtils.isAndroidApp) return;
    _openedSub?.cancel();
    _openedSub = FirebaseMessaging.onMessageOpenedApp.listen((message) {
      if (isApkReleaseMessage(message.data)) {
        onRelease();
        return;
      }
      final ticketId = ticketIdFromMessage(message.data);
      if (ticketId != null) onTicket(ticketId);
    });
  }

  /// Ticket de la notification qui a lancé l'application à froid, ou `null`.
  Future<String?> initialTicketId() async {
    if (!PlatformUtils.isAndroidApp) return null;
    try {
      final message = await _fcm.getInitialMessage();
      return message == null ? null : ticketIdFromMessage(message.data);
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: 'push.initial_message',
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  Future<void> dispose() async {
    await _refreshSub?.cancel();
    await _openedSub?.cancel();
  }
}
