import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import '../../../core/services/error_report_service.dart';
import '../../auth/domain/app_user.dart';
import '../domain/email_invitation.dart';

/// Invitations par e-mail : la liste se lit dans Firestore (lecture réservée
/// à l'administrateur et, pour son groupe, à son propriétaire), les gestes passent par la callable
/// `manageInvitationFn`, seule à écrire et à envoyer l'e-mail.
class InvitationsRepository {
  final FirebaseFirestore _firestore;
  final FirebaseFunctions _functions;
  final ErrorReportService _errorReportService;

  static const _feature = 'admin.invitations';

  InvitationsRepository({
    FirebaseFirestore? firestore,
    FirebaseFunctions? functions,
    ErrorReportService? errorReportService,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _functions =
           functions ?? FirebaseFunctions.instanceFor(region: 'europe-west1'),
       _errorReportService = errorReportService ?? ErrorReportService();

  /// Toutes les invitations, les plus récentes d'abord.
  Stream<List<EmailInvitation>> watchInvitations() {
    return _firestore
        .collection('invitations')
        .orderBy('created_at', descending: true)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => EmailInvitation.fromFirestore(d.id, d.data()))
              .toList(),
        )
        .transform(
          StreamTransformer<
            List<EmailInvitation>,
            List<EmailInvitation>
          >.fromHandlers(
            handleError: (error, stackTrace, sink) {
              unawaited(
                _errorReportService.reportError(
                  feature: _feature,
                  error: error,
                  stackTrace: stackTrace,
                  context: {'step': 'watch'},
                ),
              );
              // L'écran affiche l'erreur et propose de réessayer.
              sink.addError(error, stackTrace);
            },
          ),
        );
  }

  /// Les invitations d'un groupe, pour son propriétaire [ownerUid] (le compte
  /// connecté). La requête filtre sur `group_owner_id` : la règle Firestore
  /// n'ouvre une invitation à un non-administrateur que si ce champ vaut son
  /// uid, et une requête doit être conforme à la règle pour être servie. Le
  /// filtre sur `group_id` limite la liste au groupe affiché. Deux égalités se
  /// servent sans index composite ; pas de tri serveur (il en demanderait
  /// un) : l'écran trie.
  Stream<List<EmailInvitation>> watchGroupInvitations({
    required String groupId,
    required String ownerUid,
  }) {
    return _firestore
        .collection('invitations')
        .where('group_id', isEqualTo: groupId)
        .where('group_owner_id', isEqualTo: ownerUid)
        .snapshots()
        .map(
          (snap) => snap.docs
              .map((d) => EmailInvitation.fromFirestore(d.id, d.data()))
              .toList(),
        )
        .transform(
          StreamTransformer<
            List<EmailInvitation>,
            List<EmailInvitation>
          >.fromHandlers(
            handleError: (error, stackTrace, sink) {
              unawaited(
                _errorReportService.reportError(
                  feature: _feature,
                  error: error,
                  stackTrace: stackTrace,
                  context: {'step': 'watch_group', 'group_id': groupId},
                ),
              );
              sink.addError(error, stackTrace);
            },
          ),
        );
  }

  /// Crée l'invitation et envoie l'e-mail.
  Future<InvitationOutcome> create({
    required String email,
    required UserRole role,
    required String groupId,
    required String message,
  }) => _call('create', {
    'email': email.trim(),
    'role': role.name,
    'groupId': groupId,
    'message': message,
  });

  /// Renvoie l'e-mail et repousse l'expiration de trente jours.
  Future<InvitationOutcome> resend(String invitationId) =>
      _call('resend', {'invitationId': invitationId});

  /// Annule l'invitation : elle ne donnera plus de rôle.
  Future<InvitationOutcome> cancel(String invitationId) =>
      _call('cancel', {'invitationId': invitationId});

  Future<InvitationOutcome> _call(
    String action,
    Map<String, Object?> payload,
  ) async {
    try {
      final raw = await _functions
          .httpsCallable('manageInvitationFn')
          .call<Map<String, dynamic>>({'action': action, ...payload});
      final outcome = InvitationOutcome.fromMap(
        Map<String, dynamic>.from(raw.data),
      );
      if (outcome.kind == InvitationOutcomeKind.sendFailed) {
        // L'invitation est enregistrée, l'e-mail n'est pas parti : le serveur
        // a déjà journalisé l'erreur SMTP, on garde la trace côté client.
        await _errorReportService.reportError(
          feature: _feature,
          error: StateError(outcome.error ?? 'Envoi échoué'),
          context: {
            'step': action,
            'invitation_id': outcome.invitationId,
            'outcome': 'send_failed',
          },
        );
      }
      return outcome;
    } catch (e, st) {
      await _errorReportService.reportError(
        feature: _feature,
        error: e,
        stackTrace: st,
        context: {
          'step': action,
          if (payload['invitationId'] != null)
            'invitation_id': payload['invitationId'],
        },
      );
      rethrow;
    }
  }
}
