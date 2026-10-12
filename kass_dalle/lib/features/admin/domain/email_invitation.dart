import 'package:cloud_firestore/cloud_firestore.dart';

import '../../auth/domain/app_user.dart';

/// Statut d'une invitation par e-mail, tel que l'écran l'affiche.
///
/// `expired` n'est jamais écrit dans Firestore : une invitation envoyée (ou en
/// échec d'envoi) dont la date d'expiration est passée est expirée à la
/// lecture. Même règle que `effectiveStatus` côté serveur
/// (`functions/src/invitations/rules.ts`), qui seul décide du rôle donné.
/// Logique dupliquée : les deux rejouent
/// `test-fixtures/email_invitation_status.json`.
enum EmailInvitationStatus {
  sent,
  sendFailed,
  accepted,
  cancelled,
  expired;

  String get label => switch (this) {
    EmailInvitationStatus.sent => 'En attente',
    EmailInvitationStatus.sendFailed => 'Envoi échoué',
    EmailInvitationStatus.accepted => 'Acceptée',
    EmailInvitationStatus.cancelled => 'Annulée',
    EmailInvitationStatus.expired => 'Expirée',
  };

  /// Encore capable de donner un rôle à la première connexion.
  bool get isPending =>
      this == EmailInvitationStatus.sent ||
      this == EmailInvitationStatus.sendFailed;

  bool get canResend =>
      this == EmailInvitationStatus.sent ||
      this == EmailInvitationStatus.sendFailed ||
      this == EmailInvitationStatus.expired;

  bool get canCancel => isPending;

  /// « Copier le lien » n'a de sens que pour une invitation qu'on peut encore
  /// renvoyer : acceptée ou annulée, le lien ne donne plus de rôle.
  bool get canCopyLink => canResend;
}

/// Invitation par e-mail — `invitations/{id}`, écrite par le serveur seul.
class EmailInvitation {
  final String id;
  final String email;
  final UserRole role;
  final String groupId;
  final String groupName;
  final String message;
  final String invitedBy;
  final String invitedByName;

  /// Statut stocké : `sent`, `send_failed`, `accepted` ou `cancelled`.
  final String storedStatus;
  final DateTime? createdAt;
  final DateTime? lastSentAt;
  final DateTime? expiresAt;
  final int sendCount;
  final String? lastError;
  final String? acceptedUid;
  final DateTime? acceptedAt;
  final bool groupMissing;

  /// Qui a annulé : l'uid d'un administrateur, ou `system` quand le serveur
  /// SMTP a refusé définitivement l'adresse.
  final String? cancelledBy;

  const EmailInvitation({
    required this.id,
    required this.email,
    required this.role,
    required this.groupId,
    required this.groupName,
    required this.message,
    required this.invitedBy,
    required this.invitedByName,
    required this.storedStatus,
    this.createdAt,
    this.lastSentAt,
    this.expiresAt,
    this.sendCount = 0,
    this.lastError,
    this.acceptedUid,
    this.acceptedAt,
    this.groupMissing = false,
    this.cancelledBy,
  });

  /// Annulée par le serveur parce que Gmail a refusé l'adresse.
  bool get cancelledBySystem => cancelledBy == 'system';

  /// Lecture tolérante : un champ absent ou d'un autre type donne une valeur
  /// neutre, jamais une exception qui viderait toute la liste.
  factory EmailInvitation.fromFirestore(String id, Map<String, dynamic> data) {
    String str(String key) {
      final v = data[key];
      return v is String ? v : '';
    }

    String? optStr(String key) {
      final v = data[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    final count = data['send_count'];
    return EmailInvitation(
      id: id,
      email: str('email'),
      role: str('role') == 'editor' ? UserRole.editor : UserRole.reader,
      groupId: str('group_id'),
      groupName: str('group_name'),
      message: str('message'),
      invitedBy: str('invited_by'),
      invitedByName: str('invited_by_name'),
      storedStatus: str('status'),
      createdAt: readDate(data['created_at']),
      lastSentAt: readDate(data['last_sent_at']),
      expiresAt: readDate(data['expires_at']),
      sendCount: count is num ? count.toInt() : 0,
      lastError: optStr('last_error'),
      acceptedUid: optStr('accepted_uid'),
      acceptedAt: readDate(data['accepted_at']),
      groupMissing: data['group_missing'] == true,
      cancelledBy: optStr('cancelled_by'),
    );
  }

  /// Une date Firestore (`Timestamp`), `DateTime`, ou `null`.
  static DateTime? readDate(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return null;
  }

  /// Le statut à afficher à l'instant [now].
  EmailInvitationStatus statusAt(DateTime now) {
    switch (storedStatus) {
      case 'accepted':
        return EmailInvitationStatus.accepted;
      case 'cancelled':
        return EmailInvitationStatus.cancelled;
    }
    final expires = expiresAt;
    if (expires == null || !expires.isAfter(now)) {
      return EmailInvitationStatus.expired;
    }
    return storedStatus == 'sent'
        ? EmailInvitationStatus.sent
        : EmailInvitationStatus.sendFailed;
  }
}

/// Le message prérempli du formulaire. Il n'existe que côté client : un
/// message vidé par l'administrateur part tel quel, et l'e-mail n'a alors
/// pas de paragraphe personnel.
String defaultInvitationMessage(String groupName) =>
    'Je t\'invite dans mon groupe familial « $groupName » sur Kass\'Dalle, '
    'pour suivre et noter tes repas préférés. Tu auras aussi accès aux '
    'recettes que le groupe partage.';

/// Longueur maximale du message libre (borne du serveur).
const kInvitationMessageMax = 500;

/// Contrôle de forme d'une adresse avant l'envoi. Le serveur refait le
/// contrôle et normalise l'adresse ; celui-ci évite un aller-retour pour une
/// faute de frappe.
bool looksLikeEmail(String value) => RegExp(
  r'^[^\s@<>(),;:"\\]+@[^\s@<>(),;:"\\]+\.[^\s@<>(),;:"\\]+$',
).hasMatch(value.trim());

/// Ce que le serveur répond à une création ou à un renvoi.
enum InvitationOutcomeKind { sent, sendFailed, refused, cancelled }

class InvitationOutcome {
  final InvitationOutcomeKind kind;
  final String? invitationId;

  /// Raison du refus (`account_active`, `account_pending`, `duplicate`…).
  final String? reason;

  /// Message à afficher, écrit par le serveur.
  final String? message;

  /// Le champ concerné par un refus : `email`, `group` ou `null`.
  final String? field;

  /// Compte existant qui porte déjà l'adresse (refus `account_pending`).
  final String? existingUid;

  /// Erreur SMTP lisible, pour un envoi échoué (adresses masquées).
  final String? error;

  const InvitationOutcome({
    required this.kind,
    this.invitationId,
    this.reason,
    this.message,
    this.field,
    this.existingUid,
    this.error,
  });

  factory InvitationOutcome.fromMap(Map<String, dynamic> data) {
    String? s(String key) {
      final v = data[key];
      return v is String && v.isNotEmpty ? v : null;
    }

    final kind = switch (data['status']) {
      'sent' => InvitationOutcomeKind.sent,
      'send_failed' => InvitationOutcomeKind.sendFailed,
      'cancelled' => InvitationOutcomeKind.cancelled,
      _ => InvitationOutcomeKind.refused,
    };
    return InvitationOutcome(
      kind: kind,
      invitationId: s('invitationId'),
      reason: s('reason'),
      message: s('message'),
      field: s('field'),
      existingUid: s('existingUid'),
      error: s('error'),
    );
  }
}
